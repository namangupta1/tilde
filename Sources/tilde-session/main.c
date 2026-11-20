// tilde-session — keeps a shell alive outside the Tilde app (in the spirit of dtach).
//
//   tilde-session attach SOCK CWD EXE ARGV0 [ARGS...]
//       Attach to the session listening on SOCK. If none exists, start one first:
//       a detached daemon that owns a PTY running EXE (argv[0] = ARGV0) in CWD.
//       The attaching process relays bytes between its own terminal and the daemon.
//   tilde-session kill SOCK
//       Hang up the session's shell and remove it.
//
// The daemon keeps the last REPLAY_MAX bytes of output and replays them on attach,
// wrapped in OSC 6973 replay markers so the app can ignore stale events.
// Frames on the socket: 1 byte type, 4 byte big-endian length, payload.

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#include <util.h>

#define F_DATA 'D'    // bytes (both directions)
#define F_RESIZE 'R'  // client→daemon: rows, cols, xpix, ypix (uint16 BE each)
#define F_EXIT 'X'    // daemon→client: int32 BE exit status
#define F_KILL 'K'    // client→daemon: hang up the shell
#define F_KICK 'Q'    // daemon→client: another client attached
#define F_REPLAYED 'E' // daemon→client: replay finished

#define REPLAY_MAX (1024 * 1024)
#define EXIT_KICKED 197

extern char **environ;

// ---------- framing ----------

static int write_all(int fd, const void *buf, size_t len) {
    const char *p = buf;
    while (len > 0) {
        ssize_t n = write(fd, p, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN) { fd_set w; FD_ZERO(&w); FD_SET(fd, &w); select(fd + 1, NULL, &w, NULL, NULL); continue; }
            return -1;
        }
        p += n; len -= (size_t)n;
    }
    return 0;
}

static int send_frame(int fd, char type, const void *payload, uint32_t len) {
    unsigned char hdr[5] = { (unsigned char)type, len >> 24, len >> 16, len >> 8, len };
    if (write_all(fd, hdr, 5) < 0) return -1;
    if (len && write_all(fd, payload, len) < 0) return -1;
    return 0;
}

typedef struct { unsigned char *buf; size_t len, cap; } Reader;

// Appends what's readable; returns <=0 on EOF/error.
static ssize_t reader_fill(Reader *r, int fd) {
    if (r->cap - r->len < 65536) {
        r->cap = r->cap ? r->cap * 2 : 131072;
        r->buf = realloc(r->buf, r->cap);
    }
    ssize_t n;
    do { n = read(fd, r->buf + r->len, r->cap - r->len); } while (n < 0 && errno == EINTR);
    if (n > 0) r->len += (size_t)n;
    return n;
}

// Pops one complete frame; returns 1 if found.
static int reader_next(Reader *r, char *type, unsigned char **payload, uint32_t *len, size_t *consumed) {
    if (r->len < 5) return 0;
    uint32_t l = ((uint32_t)r->buf[1] << 24) | ((uint32_t)r->buf[2] << 16) | ((uint32_t)r->buf[3] << 8) | r->buf[4];
    if (r->len < 5 + (size_t)l) return 0;
    *type = (char)r->buf[0];
    *payload = r->buf + 5;
    *len = l;
    *consumed = 5 + l;
    return 1;
}

static void reader_consume(Reader *r, size_t n) {
    memmove(r->buf, r->buf + n, r->len - n);
    r->len -= n;
}

static int connect_sock(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un a; memset(&a, 0, sizeof a);
    a.sun_family = AF_UNIX;
    strncpy(a.sun_path, path, sizeof a.sun_path - 1);
    if (connect(fd, (struct sockaddr *)&a, sizeof a) < 0) { close(fd); return -1; }
    return fd;
}

// ---------- daemon ----------

static unsigned char *ring;
static size_t ring_len, ring_start;   // circular buffer
static volatile sig_atomic_t child_done;

static void on_chld(int s) { (void)s; child_done = 1; }

static void ring_add(const unsigned char *p, size_t n) {
    if (n >= REPLAY_MAX) { p += n - REPLAY_MAX; n = REPLAY_MAX; ring_start = 0; ring_len = 0; }
    for (size_t i = 0; i < n; i++) {
        size_t pos = (ring_start + ring_len) % REPLAY_MAX;
        ring[pos] = p[i];
        if (ring_len < REPLAY_MAX) ring_len++; else ring_start = (ring_start + 1) % REPLAY_MAX;
    }
}

static void send_replay(int c) {
    static const char begin[] = "\033]6973;replay;1\007", end[] = "\033]6973;replay;0\007";
    send_frame(c, F_DATA, begin, sizeof begin - 1);
    if (ring_len) {
        unsigned char *flat = malloc(ring_len);
        for (size_t i = 0; i < ring_len; i++) flat[i] = ring[(ring_start + i) % REPLAY_MAX];
        size_t off = 0;
        // When the buffer has wrapped, start at a line boundary so we don't begin mid-sequence.
        if (ring_len == REPLAY_MAX) {
            unsigned char *nl = memchr(flat, '\n', ring_len);
            if (nl) off = (size_t)(nl - flat) + 1;
        }
        for (size_t i = off; i < ring_len; i += 65536) {
            size_t n = ring_len - i < 65536 ? ring_len - i : 65536;
            if (send_frame(c, F_DATA, flat + i, (uint32_t)n) < 0) break;
        }
        free(flat);
    }
    send_frame(c, F_DATA, end, sizeof end - 1);
    send_frame(c, F_REPLAYED, NULL, 0);
}

static void daemon_main(const char *sock, const char *cwd, const char *exe, char **argv, struct winsize ws) {
    int devnull = open("/dev/null", O_RDWR);
    dup2(devnull, 0); dup2(devnull, 1); dup2(devnull, 2);
    if (devnull > 2) close(devnull);
    for (int fd = 3; fd < 256; fd++) close(fd);
    signal(SIGHUP, SIG_IGN);
    signal(SIGPIPE, SIG_IGN);
    signal(SIGINT, SIG_IGN);
    signal(SIGTERM, SIG_DFL);

    ring = malloc(REPLAY_MAX);

    int lfd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un a; memset(&a, 0, sizeof a);
    a.sun_family = AF_UNIX;
    strncpy(a.sun_path, sock, sizeof a.sun_path - 1);
    unlink(sock);
    mode_t old = umask(077);
    if (bind(lfd, (struct sockaddr *)&a, sizeof a) < 0 || listen(lfd, 4) < 0) _exit(1);
    umask(old);
    fcntl(lfd, F_SETFD, FD_CLOEXEC);

    struct sigaction sa; memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_chld;
    sigaction(SIGCHLD, &sa, NULL);

    int master;
    pid_t child = forkpty(&master, NULL, NULL, &ws);
    if (child < 0) { unlink(sock); _exit(1); }
    if (child == 0) {
        signal(SIGHUP, SIG_DFL); signal(SIGPIPE, SIG_DFL); signal(SIGINT, SIG_DFL); signal(SIGCHLD, SIG_DFL);
        if (chdir(cwd) < 0) chdir(getenv("HOME") ? getenv("HOME") : "/");
        execve(exe, argv, environ);
        fprintf(stderr, "tilde-session: cannot run %s: %s\r\n", exe, strerror(errno));
        _exit(127);
    }
    fcntl(master, F_SETFD, FD_CLOEXEC);
    chdir("/");

    char pidpath[1100];
    snprintf(pidpath, sizeof pidpath, "%s.pid", sock);
    FILE *pf = fopen(pidpath, "w");
    if (pf) { fprintf(pf, "%d\n", (int)child); fclose(pf); }

    int client = -1;
    Reader cr = {0};
    unsigned char buf[65536];
    int master_open = 1;
    time_t kill_deadline = 0;

    int status = 0, reaped = 0;
    for (;;) {
        if (!master_open) break;
        // Shell gone even though something else still holds the tty: finish anyway.
        if (child_done && !reaped && waitpid(child, &status, WNOHANG) == child) { reaped = 1; break; }
        fd_set r; FD_ZERO(&r);
        FD_SET(lfd, &r);
        FD_SET(master, &r);
        int maxfd = lfd > master ? lfd : master;
        if (client >= 0) { FD_SET(client, &r); if (client > maxfd) maxfd = client; }
        struct timeval tv = { 1, 0 };
        int n = select(maxfd + 1, &r, NULL, NULL, &tv);
        if (kill_deadline && time(NULL) >= kill_deadline) { kill(-child, SIGKILL); kill(child, SIGKILL); }
        if (n < 0) { if (errno == EINTR) continue; break; }

        if (FD_ISSET(master, &r)) {
            ssize_t k = read(master, buf, sizeof buf);
            if (k > 0) {
                ring_add(buf, (size_t)k);
                if (client >= 0 && send_frame(client, F_DATA, buf, (uint32_t)k) < 0) { close(client); client = -1; cr.len = 0; }
            } else if (k == 0 || (errno != EINTR && errno != EAGAIN)) {
                master_open = 0;   // shell (and everything on the tty) is gone
            }
        }
        if (FD_ISSET(lfd, &r)) {
            int c = accept(lfd, NULL, NULL);
            if (c >= 0) {
                fcntl(c, F_SETFD, FD_CLOEXEC);
                if (client >= 0) { send_frame(client, F_KICK, NULL, 0); close(client); }
                client = c;
                cr.len = 0;
                send_replay(client);
            }
        }
        if (client >= 0 && FD_ISSET(client, &r)) {
            if (reader_fill(&cr, client) <= 0) { close(client); client = -1; cr.len = 0; continue; }
            char type; unsigned char *p; uint32_t len; size_t used;
            while (client >= 0 && reader_next(&cr, &type, &p, &len, &used)) {
                if (type == F_DATA) {
                    write_all(master, p, len);
                } else if (type == F_RESIZE && len >= 8) {
                    struct winsize w = {
                        (unsigned short)((p[0] << 8) | p[1]), (unsigned short)((p[2] << 8) | p[3]),
                        (unsigned short)((p[4] << 8) | p[5]), (unsigned short)((p[6] << 8) | p[7]) };
                    ioctl(master, TIOCSWINSZ, &w);
                    // Always nudge the foreground program so it redraws for a freshly attached screen.
                    pid_t fg = tcgetpgrp(master);
                    if (fg > 0) kill(-fg, SIGWINCH);
                } else if (type == F_KILL) {
                    kill(-child, SIGHUP); kill(child, SIGHUP);
                    kill_deadline = time(NULL) + 3;
                }
                reader_consume(&cr, used);
            }
        }
    }

    int code = 1;
    if (reaped) code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
    else for (int i = 0; i < 50; i++) {
        pid_t w = waitpid(child, &status, WNOHANG);
        if (w == child) { code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status); break; }
        if (i == 30) kill(child, SIGKILL);
        usleep(20000);
    }
    unlink(sock);
    unlink(pidpath);
    if (client >= 0) {
        unsigned char c4[4] = { (unsigned char)(code >> 24), (unsigned char)(code >> 16), (unsigned char)(code >> 8), (unsigned char)code };
        send_frame(client, F_EXIT, c4, 4);
        close(client);
    }
    _exit(0);
}

// ---------- client ----------

static struct termios saved_tio;
static int tio_saved;
static volatile sig_atomic_t winch = 1;

static void restore_tty(void) { if (tio_saved) tcsetattr(0, TCSADRAIN, &saved_tio); }
static void on_winch(int s) { (void)s; winch = 1; }

static double now_s(void) { struct timeval t; gettimeofday(&t, NULL); return t.tv_sec + t.tv_usec / 1e6; }

static int spawn_daemon(const char *sock, const char *cwd, const char *exe, char **argv) {
    // The terminal view is often still being laid out; start the shell at its settled size
    // (zsh draws its prompt for the width it starts with).
    struct winsize ws = { 24, 80, 0, 0 }, prev = { 0, 0, 0, 0 };
    usleep(40000);
    for (int i = 0; i < 8; i++) {
        ioctl(0, TIOCGWINSZ, &ws);
        if (i > 0 && ws.ws_row == prev.ws_row && ws.ws_col == prev.ws_col) break;
        prev = ws;
        usleep(30000);
    }
    if (ws.ws_row == 0 || ws.ws_col == 0) { ws.ws_row = 24; ws.ws_col = 80; }
    pid_t p = fork();
    if (p < 0) return -1;
    if (p == 0) {
        setsid();
        pid_t q = fork();
        if (q == 0) daemon_main(sock, cwd, exe, argv, ws);
        _exit(q < 0 ? 1 : 0);
    }
    int st; waitpid(p, &st, 0);
    for (int i = 0; i < 150; i++) {   // up to ~3s for the socket to appear
        int fd = connect_sock(sock);
        if (fd >= 0) return fd;
        usleep(20000);
    }
    return -1;
}

static int cmd_attach(int argc, char **argv) {
    if (argc < 6) { fprintf(stderr, "usage: tilde-session attach SOCK CWD EXE ARGV0 [ARGS...]\n"); return 2; }
    const char *sock = argv[2], *cwd = argv[3], *exe = argv[4];
    char **child_argv = &argv[5];

    int fd = connect_sock(sock);
    if (fd < 0) {
        unlink(sock);
        fd = spawn_daemon(sock, cwd, exe, child_argv);
        if (fd < 0) { fprintf(stderr, "tilde-session: could not start session\r\n"); return 1; }
    }

    signal(SIGPIPE, SIG_IGN);
    struct sigaction sa; memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_winch;
    sigaction(SIGWINCH, &sa, NULL);

    if (tcgetattr(0, &saved_tio) == 0) {
        tio_saved = 1;
        atexit(restore_tty);
        struct termios raw = saved_tio;
        cfmakeraw(&raw);
        tcsetattr(0, TCSADRAIN, &raw);
    }

    Reader rd = {0};
    unsigned char buf[65536];
    double replay_end = 0;   // terminal answers to replayed queries arrive just after; drop them
    double winch_at = 0;     // resizes are coalesced: the window settles before the shell redraws

    for (;;) {
        if (winch) { winch = 0; if (winch_at == 0) winch_at = now_s() + 0.08; }
        if (winch_at > 0 && now_s() >= winch_at) {
            winch_at = 0;
            struct winsize ws;
            if (ioctl(0, TIOCGWINSZ, &ws) == 0) {
                unsigned char p[8] = { ws.ws_row >> 8, ws.ws_row, ws.ws_col >> 8, ws.ws_col,
                                       ws.ws_xpixel >> 8, ws.ws_xpixel, ws.ws_ypixel >> 8, ws.ws_ypixel };
                send_frame(fd, F_RESIZE, p, 8);
            }
        }
        fd_set r; FD_ZERO(&r); FD_SET(0, &r); FD_SET(fd, &r);
        struct timeval tv = { 0, 20000 };
        int n = select(fd + 1, &r, NULL, NULL, winch_at > 0 ? &tv : NULL);
        if (n < 0) { if (errno == EINTR) continue; return 1; }
        if (FD_ISSET(0, &r)) {
            ssize_t k = read(0, buf, sizeof buf);
            if (k <= 0) { if (k < 0 && errno == EINTR) continue; return 0; }   // app went away: detach, shell lives on
            int drop = replay_end > 0 && now_s() - replay_end < 0.4 && buf[0] == 0x1b;
            if (!drop && send_frame(fd, F_DATA, buf, (uint32_t)k) < 0) return 1;
        }
        if (FD_ISSET(fd, &r)) {
            if (reader_fill(&rd, fd) <= 0) return 1;
            char type; unsigned char *p; uint32_t len; size_t used;
            while (reader_next(&rd, &type, &p, &len, &used)) {
                if (type == F_DATA) {
                    if (write_all(1, p, len) < 0) return 0;
                } else if (type == F_REPLAYED) {
                    replay_end = now_s();
                    winch = 1;   // resend size: makes the program redraw
                } else if (type == F_EXIT && len >= 4) {
                    int code = (p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3];
                    return code;
                } else if (type == F_KICK) {
                    return EXIT_KICKED;
                }
                reader_consume(&rd, used);
            }
        }
    }
}

static int cmd_kill(const char *sock) {
    int fd = connect_sock(sock);
    if (fd >= 0) {
        send_frame(fd, F_KILL, NULL, 0);
        // Wait briefly for the daemon to finish so the caller sees it gone.
        char b[256];
        struct timeval tv = { 3, 0 };
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        while (read(fd, b, sizeof b) > 0) {}
        close(fd);
        return 0;
    }
    char pidpath[1100];
    snprintf(pidpath, sizeof pidpath, "%s.pid", sock);
    FILE *pf = fopen(pidpath, "r");
    if (pf) { int pid = 0; if (fscanf(pf, "%d", &pid) == 1 && pid > 1) { kill(-pid, SIGHUP); kill(pid, SIGHUP); } fclose(pf); }
    unlink(sock); unlink(pidpath);
    return 0;
}

int main(int argc, char **argv) {
    if (argc >= 2 && strcmp(argv[1], "attach") == 0) return cmd_attach(argc, argv);
    if (argc >= 3 && strcmp(argv[1], "kill") == 0) return cmd_kill(argv[2]);
    fprintf(stderr, "usage: tilde-session attach SOCK CWD EXE ARGV0 [ARGS...] | kill SOCK\n");
    return 2;
}
