import Foundation

/// Installs a tiny zsh integration (same ZDOTDIR technique Ghostty/VS Code use) that emits:
///   OSC 133;A / 133;C / 133;D;<exit>  — standard prompt marks (prompt navigation)
///   OSC 7                            — current directory
///   OSC 6973;start;<base64 cmd>      — private: command started
///   OSC 6973;end;<exit>              — private: command finished
/// The user's own dotfiles are still loaded normally.
enum ShellIntegration {
    static let oscCode = 6973

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "shellIntegration") as? Bool ?? true
    }

    static let dir: String = {
        let d = WorkspaceStore.fileURL.deletingLastPathComponent().appendingPathComponent("shell-integration").path
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }()

    static func install() {
        let files: [String: String] = [
            ".zshenv": zshenv,
            "tilde.zsh": tildeZsh,
            "tilde.bash": tildeBash,
            "xdg/fish/vendor_conf.d/tilde.fish": tildeFish,
        ]
        for (name, body) in files {
            let path = (dir as NSString).appendingPathComponent(name)
            try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true)
            if (try? String(contentsOfFile: path, encoding: .utf8)) != body {
                try? body.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Adjusts the environment of a local shell so the integration loads.
    /// Written once per launch, before the first shell starts (avoids a startup race).
    private static let installOnce: Bool = {
        install()
        return FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(".zshenv"))
    }()

    /// Sets up the environment (and for bash, the arguments) so the integration loads.
    static func apply(to env: inout [String: String], shellName: String, argv0: inout String, args: inout [String]) {
        guard enabled, installOnce else { return }
        env["TILDE_INTEGRATION_DIR"] = dir
        switch shellName {
        case "zsh":
            // Never point ZDOTDIR at a directory without our .zshenv — the user's config would be skipped.
            if let orig = env["ZDOTDIR"] { env["TILDE_ORIG_ZDOTDIR"] = orig }
            env["ZDOTDIR"] = dir
        case "bash":
            // Login shells ignore --init-file, so tilde.bash loads the login files itself.
            argv0 = "bash"
            args = ["--init-file", (dir as NSString).appendingPathComponent("tilde.bash")]
        case "fish":
            // fish reads vendor_conf.d from every XDG data dir.
            if let orig = env["XDG_DATA_DIRS"] { env["TILDE_ORIG_XDG_DATA_DIRS"] = orig }
            env["XDG_DATA_DIRS"] = (dir as NSString).appendingPathComponent("xdg") + ":" + (env["XDG_DATA_DIRS"] ?? "/usr/local/share:/usr/share")
        default: break
        }
    }

    private static let zshenv = #"""
    # Tilde shell integration bootstrap: restore the user's ZDOTDIR, load their .zshenv,
    # then load Tilde hooks for interactive shells. zsh reads the remaining startup
    # files (.zprofile, .zshrc, .zlogin) from the restored ZDOTDIR.
    if [[ -n "${TILDE_ORIG_ZDOTDIR+x}" ]]; then
      ZDOTDIR="$TILDE_ORIG_ZDOTDIR"; unset TILDE_ORIG_ZDOTDIR
    else
      unset ZDOTDIR
    fi
    [[ -f "${ZDOTDIR:-$HOME}/.zshenv" ]] && source "${ZDOTDIR:-$HOME}/.zshenv"
    if [[ -o interactive && -r "$TILDE_INTEGRATION_DIR/tilde.zsh" ]]; then
      source "$TILDE_INTEGRATION_DIR/tilde.zsh"
    fi
    """#

    private static let tildeZsh = #"""
    # Tilde zsh hooks — prompt marks, cwd, command start/finish with exit status.
    [[ -n "$_TILDE_HOOKED" ]] && return
    typeset -g _TILDE_HOOKED=1
    typeset -g _tilde_running=0
    autoload -Uz add-zsh-hook

    _tilde_precmd() {
      local ret=$?
      if (( _tilde_running )); then
        builtin printf '\e]133;D;%s\a\e]6973;end;%s\a' "$ret" "$ret"
        _tilde_running=0
      fi
      builtin printf '\e]7;file://%s%s\a' "${HOST}" "${PWD// /%20}"
      builtin printf '\e]133;A\a'
    }

    _tilde_preexec() {
      _tilde_running=1
      builtin printf '\e]133;C\a\e]6973;start;%s\a' "$(builtin printf '%s' "$1" | /usr/bin/base64 | /usr/bin/tr -d '\n')"
    }

    add-zsh-hook precmd _tilde_precmd
    add-zsh-hook preexec _tilde_preexec
    """#

    private static let tildeBash = #"""
    # Tilde bash integration. Started as `bash --init-file tilde.bash`, so behave like a login shell first.
    [ -r /etc/profile ] && . /etc/profile
    if [ -r "$HOME/.bash_profile" ]; then . "$HOME/.bash_profile"
    elif [ -r "$HOME/.bash_login" ]; then . "$HOME/.bash_login"
    elif [ -r "$HOME/.profile" ]; then . "$HOME/.profile"
    fi

    if [ -z "$_TILDE_HOOKED" ]; then
      _TILDE_HOOKED=1
      _tilde_running=0
      _tilde_ready=0
      _tilde_ret=0
      _tilde_start() {
        local ret=$?
        _tilde_ret=$ret
        _tilde_ready=0
        return $ret
      }
      _tilde_prompt() {
        if [ "$_tilde_running" = 1 ]; then
          builtin printf '\e]133;D;%s\a\e]6973;end;%s\a' "$_tilde_ret" "$_tilde_ret"
          _tilde_running=0
        fi
        builtin printf '\e]7;file://%s%s\a' "$HOSTNAME" "${PWD// /%20}"
        builtin printf '\e]133;A\a'
        _tilde_ready=1
        return $_tilde_ret
      }
      _tilde_debug() {
        [ -n "$COMP_LINE" ] && return
        [ "$_tilde_ready" = 1 ] || return
        case "$BASH_COMMAND" in _tilde_*) return ;; esac
        _tilde_ready=0
        _tilde_running=1
        local cmd
        cmd=$(HISTTIMEFORMAT= builtin history 1 | /usr/bin/sed 's/^ *[0-9]* *//')
        builtin printf '\e]133;C\a\e]6973;start;%s\a' "$(builtin printf '%s' "$cmd" | /usr/bin/base64 | /usr/bin/tr -d '\n')"
      }
      trap '_tilde_debug' DEBUG
      PROMPT_COMMAND="_tilde_start${PROMPT_COMMAND:+; $PROMPT_COMMAND}; _tilde_prompt"
    fi
    """#

    private static let tildeFish = #"""
    # Tilde fish integration (loaded from vendor_conf.d via XDG_DATA_DIRS).
    if set -q TILDE_ORIG_XDG_DATA_DIRS
        set -gx XDG_DATA_DIRS $TILDE_ORIG_XDG_DATA_DIRS
        set -e TILDE_ORIG_XDG_DATA_DIRS
    else
        set -e XDG_DATA_DIRS
    end
    status is-interactive; or exit
    set -q _TILDE_HOOKED; and exit
    set -g _TILDE_HOOKED 1

    function _tilde_preexec --on-event fish_preexec
        set -g _tilde_running 1
        printf '\e]133;C\a\e]6973;start;%s\a' (printf '%s' "$argv" | /usr/bin/base64 | /usr/bin/tr -d '\n')
    end

    function _tilde_postexec --on-event fish_postexec
        set -l ret $status
        printf '\e]133;D;%s\a\e]6973;end;%s\a' $ret $ret
        set -g _tilde_running 0
    end

    function _tilde_prompt --on-event fish_prompt
        printf '\e]7;file://%s%s\a' (hostname) (string replace -a ' ' '%20' -- $PWD)
        printf '\e]133;A\a'
    end
    """#
}
