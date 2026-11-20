# Feature parity — Tilde vs Tern, iTerm2, Warp, Ghostty

✅ Tilde has it · 🆕 added in the parity pass · ➖ deliberately not done (why)

| Feature | Tern | iTerm2 / Warp / Ghostty | Tilde |
|---|---|---|---|
| Folders of tabs in a sidebar | ✅ | — | ✅ |
| Rename tabs, notes, colours | rename | rename | ✅ (+ notes, colours) |
| Smart tab names (agent title, running / last long command) | ✅ | partial | 🆕 last long command sticks |
| Splits, close, drag to resize | ✅ | ✅ | ✅ |
| Pane focus keys (⌘[ ⌘], ⌥⌘ arrows), zoom pane, equalize | ✅ | ✅ | 🆕 |
| Dim unfocused panes | ✅ | ✅ | 🆕 |
| Move tab earlier / later, reopen closed tab | ✅ | ✅ | 🆕 |
| Sessions survive quitting | ✅ daemon | tmux only | ✅ daemon |
| Detach tab / reattach detached sessions | ✅ | — | 🆕 |
| Multiple windows | ✅ | ✅ | ➖ single window for now (big refactor; next) |
| Global hotkey | show/hide app | quick terminal | ✅ drop-down quick terminal |
| Command palette | ✅ | Warp | ✅ |
| Shell integration zsh / bash / fish | ✅ all | ✅ | 🆕 bash + fish added |
| Prompt jumping | ✅ | ✅ | ✅ |
| Copy last command's output | ✅ | ✅ | 🆕 ⇧⌘C |
| Search output across all sessions | ✅ | — | 🆕 ⇧⌘F |
| Last-command status in header | ✅ | Warp blocks | ✅ |
| Long-command / bell / OSC 9, 777 notifications, ⌘J, Dock badge | ✅ | partial | ✅ |
| Agent status (Claude Code needs you / working / done) | ✅ hooks | — | 🆕 opt-in Claude Code hooks + title detection |
| Agent usage limits | ✅ | — | ➖ reads Claude's Keychain token; out of scope (no AI in v1) |
| ⌘-click URLs | ✅ | ✅ | ✅ |
| ⌘-click `path:line:col` → editor, open selected file | ✅ | iTerm2 | 🆕 |
| Drop files → quoted paths | ✅ | ✅ | ✅ |
| Paste Finder-copied files as paths, paste image as file | ✅ | — | 🆕 |
| Export scrollback | ✅ | ✅ | ✅ Markdown with command table |
| Hosts registry with live status + cached facts | devices | — | ✅ (unique) |
| Shared SSH connection, quick commands, multi-host run | — | — | ✅ (unique) |
| SSH → reattach named tmux session | ✅ | iTerm2 tmux | 🆕 per-host tmux session |
| Remote daemon on devices (survives Mac sleep) | ✅ | — | ➖ needs agent binaries on servers; tmux covers most of it |
| Drop files on SSH pane → upload | — | iTerm2 (scp) | ✅ |
| Broadcast input | — | iTerm2 | ✅ |
| Snippets with fill-in fields | — | Warp workflows | ✅ |
| Templates / launch presets | ✅ | iTerm2 arrangements | ✅ |
| Git worktree tab | ✅ | — | 🆕 ⌥⌘T |
| Folder picker with recent folders / git repos / zoxide | ✅ | — | 🆕 in ⌘K |
| Themes: built-ins + import | 6 built-in + Ghostty | huge | 🆕 built-ins + iTerm2 import |
| Font, cursor style, Option-as-Meta settings | ✅ | ✅ | 🆕 |
| Terminal right-click menu | ✅ | ✅ | 🆕 |
| Secure Keyboard Entry | ✅ | ✅ | 🆕 |
| Keyboard shortcuts cheat sheet | ⌘/ | — | 🆕 ⌘/ |
| Auto-update | ✅ | ✅ | ➖ needs a public release feed (repo is private) |
| Inline images (sixel / iTerm2) | ✅ | ✅ | ✅ via SwiftTerm |
