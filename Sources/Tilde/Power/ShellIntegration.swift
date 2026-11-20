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
        ]
        for (name, body) in files {
            let path = (dir as NSString).appendingPathComponent(name)
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

    static func apply(to env: inout [String: String], shellName: String) {
        // Never point ZDOTDIR at a directory without our .zshenv — the user's config would be skipped.
        guard enabled, shellName == "zsh", installOnce else { return }
        if let orig = env["ZDOTDIR"] { env["TILDE_ORIG_ZDOTDIR"] = orig }
        env["ZDOTDIR"] = dir
        env["TILDE_INTEGRATION_DIR"] = dir
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
}
