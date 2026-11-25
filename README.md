# Message Logger for C-Cord

A customizable deleted & edited message logger plugin for **C-Cord** (Plugin API v1, Lua 5.5) built for Linux, macOS, Windows, and Android.

## Features

- **Native In-Place Deleted Messages in Chat**
  - Uses C-Cord's positioned timeline local messages (`messages.inject_local` with `position = "timeline"`, `sort_id`, `compact = "auto"`, and `clip_to_history = true`) so deleted messages stay in their **exact chronological slot** inside the native chat stream:
    - Message text renders in **red** (customizable color).
    - Header messages render with a **red username**, `DELETED` badge, and a **Rec.709 grayscale / dimmed profile picture**.
    - Compact continuation messages merge naturally beneath the previous message in red text without duplicating the username/avatar.
    - Archived image thumbnails render inline via host-side decoding (`attachments[].local_path = "plugin_data://..."` / `texture_key`) and update in place via `messages.update_local`.
    - Deleted messages persist across restarts (in Disk mode), and dismissing (`×`) persists cleanly until restored via **Show** in the Logs drawer.
- **Native In-Message Edited Former Versions**
  - Uses `ui.decorate.message_accessory` with `position = "above_body"` to attach ordered former versions (`v1`, `v2`, …) **inside** the live message directly above the current text, separated by clean horizontal divider lines in native muted typography — leaving C-Cord's native `(edited)` indicator untouched, with hover timestamp tooltips and persistent dismiss.
  - When an edited message is later deleted, former versions stay **above** the final deleted text in muted gray while the header and final text turn red.
  - Switchable between **Native Inline Text** (default) and **Subtle Left Hairline** in Settings.
- **Active-Channel + Right-Click Whitelist Monitoring**
  - **Active Channel Auto-Logging (Default ON):** Automatically logs deleted & edited messages in whichever channel or DM you are currently viewing.
  - **Background / Idle Whitelist:** Idle channels only log if whitelisted. Right-click any **Channel**, **DM / Group DM**, **Category**, **Voice Channel**, **Server**, or **Message** → **Message Logger** to whitelist, exclude, view logs (with live counts), or clear logs.
  - Event-driven history caching via `events.on("messages.loaded")` — zero polling timers and zero `gateway.raw`.
- **Sandboxed Persistent Storage (`storage.files`) or In-Memory Mode**
  - **Disk Mode (Default):** Stores logs (`events.jsonl`) and archived media (`media/`, `precache/`) strictly inside C-Cord's sandboxed per-plugin data folder (`plugin_data://`) via Class 2 `storage.files` — **no host-wide filesystem permissions required**, and works identically on Desktop and Android.
  - **In-Memory Mode:** Keeps logs and binary media strictly in RAM until restart.
  - **Clean Teardown (`plugin.on_unload`):** Synchronously compacts logs and cleans temporary pre-cache files on disable, reload, uninstall, or quit.
- **Cross-Platform Deleted Image & Video Archiving + Native Lightbox**
  - Independent toggles for **Images**, **Videos**, and **Other Attachments**.
  - Streams media via `net.http.download` (up to 256 MiB in Disk mode, strictly pinned to Discord CDN hosts in `allowed_hosts`) with atomic `storage.files.rename` pre-cache → permanent archive promotion, or pure-RAM `net.http.get({ binary = true })` in Memory mode.
  - Click any archived image thumbnail or **View** button (images & videos) to open C-Cord's native lightbox (`ui.media.open`) with multi-attachment gallery support.
- **Log & Media Viewer, Jump-to-Message, Profile Popouts & Commands**
  - Docked right-sidebar drawer (`Ctrl+Shift+L` or header **Logs** button) + optional full-workspace server-rail tab with live incremental search (`ui.panel.patch`), native local timestamps (`time.format_discord`), clickable author profiles (`ui.open_user_profile`), **Jump** (`navigation.jump_to_message`), right-click card menus (`ui.menu.popup`), actionable delete toasts, `Save As`, `Export JSON`, and `Export Markdown`.
  - Conditional Settings UI (`visible_when`) with Maintenance action buttons (*Export JSON*, *Clear Pre-cache*, *Clear All Logs*).
  - Local `/msglog` slash command with autocomplete (`toggle`, `watch`, `watch-server`, `status`, `mode disk|memory`, `export`, `clear`).

## Installation

### Option 1 — Import `.cce` Package
Download `io.github.32bitx64bit.message-logger-1.0.0.cce` from [Releases](https://github.com/32bitx64bit/ccord-message-logger/releases), import it in C-Cord under **Settings → Plugins → Install from File**, review the permissions, and enable the plugin.

### Option 2 — Local Development (`--plugin-dir`)
```bash
ccord --plugin-dir "/path/to/parent-folder-containing-plugin" --plugin-dev
```

## Testing

```bash
luac5.5 -p main.lua src/*.lua
lua5.5 tests/test_message_logger.lua
```

## Declared Permissions

- **Class 1:** `events.navigation`, `ui.contextMenu`, `clipboard.write`, `storage`, `commands`
- **Class 2:** `events.messages`, `events.channels`, `store.read`, `navigation.write`, `ui.panel`, `ui.decorate`, `storage.files`
- **Class 3:** `network.http` (strictly pinned via `allowed_hosts` to Discord CDN domains for archiving deleted images & videos)

## License

MIT — see [LICENSE](LICENSE).
