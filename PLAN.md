# Tilde — a workspace-first terminal for macOS

Working name: **Tilde** (`~`). Native Swift (SwiftUI + AppKit), terminal engine: [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), kept behind a thin wrapper so it can be swapped for libghostty later.
Distribution: ad-hoc signed `.app` packaged into a `.dmg` (`scripts/package.sh`). Font: macOS system monospaced font (SF Mono).

## Decisions
| Topic | Decision |
|---|---|
| Stack | Swift 6 toolchain, SwiftPM package (no .xcodeproj needed), macOS 14+ |
| Terminal engine | SwiftTerm `LocalProcessTerminalView` |
| VM access | Hosts registry + SSH ControlMaster multiplexing (one persistent connection per host) |
| AI features | Out of scope for v1 |
| Packaging | `swift build -c release` → `.app` bundle → `hdiutil` `.dmg` |

## Phase 1 — MVP workspace ✅ (built 2026-11-20)
- [x] App shell: window, sidebar + detail split, Settings window
- [x] Folders (name + optional working directory), collapsible, reorder, rename, delete
- [x] Tabs inside folders; new tab opens shell in folder's directory
- [x] Rename tab (double-click / ⌘R), per-tab notes, per-tab colour label
- [x] Splits inside a tab (⌘D right, ⇧⌘D down), close pane (⌘W)
- [x] Shells stay alive when switching tabs
- [x] Auto tab title from running program / cwd when not renamed
- [x] Light / Dark / System appearance, terminal palettes for each, SF Mono font, font size
- [x] Persist & restore layout (folders, tabs, names, notes, splits, last cwd)
- [x] Keyboard: ⌘T new tab, ⇧⌘N new folder, ⌘1–9 jump, ⇧⌘[ / ⇧⌘] prev/next, ⌘+/⌘- font size
- [x] `.dmg` packaging script + app icon

## Phase 2 — Environments / Hosts ✅ (built 2026-11-20)
- [x] Hosts sidebar section: name, address, user, port, key, jump host, extra ssh options, tags, notes
- [x] Import hosts from `~/.ssh/config` (aliases kept, so all ssh options still apply)
- [x] Shared SSH connection per host (ControlMaster, ControlPersist 15m, sockets in ~/Library/Caches/Tilde/cm)
- [x] Background monitor every 30s: TCP reachability (via `ssh -G` resolution), shared-connection check
- [x] Cached system facts (OS, uptime, load, CPUs, memory, disk, IP) — refreshed every 5 min, persisted
- [x] Quick commands with inline output panel (exit status, duration, copy)
- [x] SSH tabs; splits of an SSH pane reconnect instantly; failed sessions stay open; ⇧⌘R reconnect
- [x] Per-host env vars: exported in SSH tabs and in "local shell with environment"
- [x] `prod` tag → red tab, PROD badge, production banner
- [ ] Later: password/OTP hosts can't be queried in background until one interactive login

## Phase 3 — Power features ✅ (built 2026-11-20)
- [x] Command palette (⌘K): fuzzy search over tabs, hosts, host commands, snippets, recent commands, actions
- [x] zsh shell integration (ZDOTDIR shim, user dotfiles still load): OSC 133 prompt marks, OSC 7 cwd, command start/end + exit code
- [x] Prompt navigation ⌘↑ / ⌘↓; last-command badge in tab header (✓/✗, duration)
- [x] Per-pane command history in the palette: re-insert, or save as snippet
- [x] Scrollback search ⌘F / ⌘G / ⇧⌘G (SwiftTerm find bar: case, regex, whole word)
- [x] Snippets with `{{name}}` / `{{name:default}}` fields, run-immediately, folder/host scoping, manager (⌥⌘S)
- [x] Notifications for long commands (threshold in Settings) when you're not looking; bell + OSC 9/777 too
- [x] Attention ring on tabs, Dock badge count, ⌘J jump to next tab needing attention; click notification → tab
- [x] ⌘-click URLs (SwiftTerm link detection)
- [ ] Later: bash/fish integration; Esc closes find bar; copy-last-output via OSC 133 regions

## Phase 4 — Polish ✅ (built 2026-11-20)
- [x] Shells survive quitting: each pane runs in a `tilde-session` daemon (C helper bundled in the app, dtach-style); reopening reattaches and replays the last 1 MB of output; ⌥⌘Q "Quit and End All Shells"; Settings toggle
- [x] Quick terminal: drop-down panel on a global hotkey (⌃` default; ⌥`, ⌥Space, F12), its shell persists too
- [x] Workspace templates: save a folder (tabs, splits, dirs, hosts; running commands become startup commands), open from File / sidebar / ⌘K, template manager
- [x] Broadcast input to all panes of a tab (⌥⌘I, orange borders + header badge); run one command on many hosts (⌥⌘H, tag selection, prod confirmation)
- [x] Drop files on an SSH pane → scp upload over the shared connection into the remote cwd (when the remote shell reports it, else ~); on local panes drops paste quoted paths
- [x] Transcript export to Markdown (⇧⌘E): scrollback per pane + command table
- [x] iTerm2 `.itermcolors` import (auto-assigned to dark/light by background), reset in Settings
- [x] `package.sh`: Developer ID signing (hardened runtime) + notarization via `DEVELOPER_ID` / `NOTARY_PROFILE`
- [x] Verified (2026-11-20): background sessions + replay, broadcast, templates, quick terminal (menu), transcript export, multi-host run, SSH upload command, iTerm import parser, bash integration
- [ ] Not yet verified by hand: pressing the global hotkey itself, real drag-and-drop / paste gestures, right-click menu, fish (not installed)
- [ ] Later: commands run before a reattach aren't in ⌘K history (replayed output is ignored on purpose)

## Subfolders ✅ (2026-11-21)
- [x] Folders nest to any depth (`Folder.parentID`, folders still stored flat so tab lookups are unchanged; old workspace files load as top level)
- [x] New Subfolder: folder right-click menu, File menu / ⌥⇧⌘N and ⌘K (in the current folder); inherits the parent's default directory
- [x] Subfolders show below the folder's tabs as collapsible rows; ⌘1–9 / next-prev follow sidebar order
- [x] Move Folder To ▸ (another folder or Top Level, subtree moves with it, no cycles); drag to reorder among siblings
- [x] Delete removes the subtree and closes its tabs; Move to Folder / ⌘K / snippet scope show "Parent › Child" paths
- [x] Unit tests for the tree logic (`swift test`); verified in the app: create two levels, collapse, persist across relaunch
- [ ] Not verified by hand: right-click menu items (Move Folder To, Delete) and inline rename on a subfolder — same code path as top-level folders

## Parity pass ✅ (2026-11-20) — see PARITY.md
- [x] Verified in the app: zoom / equalize / pane cycling + directional focus, dimmed inactive panes, smart tab names,
      search all sessions (now searches as you type), reopen closed tab, detach + reattach (running job survives),
      shortcuts sheet, theme switch from ⌘K, Claude Code status (Working badge, Needs-you flag on a background tab), git worktree tab
- [x] Fixed while testing: replay drawn before layout settled (only fragments showed after reattach); dimmed panes kept the old theme colour
- [x] Universal build (Apple silicon + Intel) via per-arch builds + lipo
- [ ] Note: each ad-hoc rebuild is a "new app" to macOS privacy, so shells starting in ~/Documents wait for the Files & Folders prompt
- [ ] Later: multiple windows; auto-update (needs a public feed); Developer ID signing + notarization
