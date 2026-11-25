-- Local /msglog slash command and in-app keyboard shortcut.

local util = require("src.util")
local config = require("src.config")
local whitelist = require("src.whitelist")
local persistence = require("src.persistence")
local media = require("src.media")
local capture = require("src.capture")
local ui_panel = require("src.ui_panel")

local M = {}

local SUBCOMMANDS = {
  { label = "toggle", detail = "Open or close the Message Logger drawer", insert_text = "toggle" },
  { label = "watch", detail = "Toggle monitoring for the active channel or DM", insert_text = "watch" },
  { label = "watch-server", detail = "Toggle monitoring for the active server", insert_text = "watch-server" },
  { label = "status", detail = "Show persistence mode, whitelist counts, and disk stats", insert_text = "status" },
  { label = "mode disk", detail = "Switch to persistent on-disk storage", insert_text = "mode disk" },
  { label = "mode memory", detail = "Switch to in-memory storage (cleared on restart)", insert_text = "mode memory" },
  { label = "export", detail = "Save all logged messages to a JSON file", insert_text = "export" },
  { label = "clear", detail = "Clear all logged messages and archived media", insert_text = "clear" },
}

local function build_status_notice(ctx)
  local st = persistence.stats()
  local wc = whitelist.counts()
  local cid = ctx and ctx.channel_id or ""
  local gid = ctx and ctx.guild_id or ""
  local cur_mon, cur_reason = whitelist.is_monitored(gid, cid)
  local media_str = (st.mode == "disk")
    and string.format("%s (%d files in plugin storage)", util.format_bytes(st.jail_used_bytes or st.disk_media_bytes), st.jail_file_count or 0)
    or (util.format_bytes(st.mem_media_bytes) .. " in RAM")

  local lines = {
    "**Message Logger Status**",
    string.format("- **Persistence Mode:** `%s`%s", st.mode, st.mode == "disk" and " (sandboxed `plugin_data://`)" or " (clears on restart)"),
    string.format("- **Monitoring Scope:** `%s` | Current channel: %s",
      config.get("monitor_mode"), cur_mon and ("**Monitored** (" .. cur_reason .. ")") or "Not monitored"),
    string.format("- **Whitelist:** %d server(s), %d category(s), %d channel(s)/DM(s), %d excluded",
      wc.guilds, wc.categories, wc.channels, wc.excluded),
    string.format("- **Logged Messages:** %d total (%d deleted, %d edited)", st.total, st.deleted, st.edited),
    string.format("- **Archived Media:** %d file(s) (%s) | Images: %s | Videos: %s | Strategy: `%s`",
      st.saved_media,
      media_str,
      config.get("save_images") and "ON" or "OFF",
      config.get("save_videos") and "ON" or "OFF",
      config.get("media_capture_mode")),
    string.format("- **Live Cache:** %d message(s) cached in memory", capture.cached_count()),
  }

  return {
    local_notice = true,
    text = table.concat(lines, "\n"),
  }
end

function M.init()
  if commands and commands.register then
    commands.register({
      name = "msglog",
      description = "Control Message Logger (toggle, watch, status, mode, export, clear)",
      autocomplete = function(args)
        local q = string.lower(util.trim(args or ""))
        local out = {}
        for i = 1, #SUBCOMMANDS do
          local item = SUBCOMMANDS[i]
          if q == "" or string.lower(item.label):find(q, 1, true) then
            out[#out + 1] = item
          end
        end
        return out
      end,
      run = function(args, ctx)
        local raw = util.trim(args or "")
        local cmd, rest = raw:match("^(%S+)%s*(.*)$")
        cmd = string.lower(cmd or "")
        rest = string.lower(util.trim(rest or ""))

        if cmd == "" or cmd == "toggle" or cmd == "open" then
          ui_panel.toggle_drawer()
          return nil
        elseif cmd == "watch" then
          local cid = ctx and ctx.channel_id
          local gid = ctx and ctx.guild_id
          if not util.is_nonempty_id(cid) then
            return { local_notice = true, text = "No active channel or DM selected." }
          end
          local added, msg = whitelist.toggle_channel(cid, gid)
          if added then capture.seed_channel(cid, gid) end
          ui_panel.schedule_redraw(50)
          return { local_notice = true, text = msg }
        elseif cmd == "watch-server" then
          local gid = ctx and ctx.guild_id
          if not util.is_nonempty_id(gid) or gid == "dm" then
            return { local_notice = true, text = "No server selected (use `/msglog watch` for DMs)." }
          end
          local added, msg = whitelist.toggle_guild(gid)
          if added then capture.seed_guild(gid) end
          ui_panel.schedule_redraw(50)
          return { local_notice = true, text = msg }
        elseif cmd == "status" then
          return build_status_notice(ctx)
        elseif cmd == "mode" then
          if rest == "disk" or rest == "memory" then
            config.set("storage_mode", rest)
            return {
              local_notice = true,
              text = rest == "disk"
                and "Switched to **persistent disk** storage (sandboxed `plugin_data://`)."
                or "Switched to **in-memory only** storage (logs clear on restart).",
            }
          end
          return { local_notice = true, text = "Usage: `/msglog mode disk` or `/msglog mode memory`" }
        elseif cmd == "export" then
          local payload = persistence.export_json()
          async.spawn(function()
            local saved = ui.file.save({ suggested_name = "ccord-message-logs.json", data = payload })
            if saved and saved.path then
              ui.toast.show("Exported logs to " .. saved.path, "info")
            end
          end)
          return nil
        elseif cmd == "clear" then
          async.spawn(function()
            local res = ui.dialog.confirm({
              title = "Clear All Message Logs",
              message = "Permanently delete all logged messages and archived media?",
              confirm_label = "Clear All",
            })
            if res and res.accepted then
              local n = persistence.clear_all()
              capture.clear_all_inline_deleted()
              media.clear_preview_textures()
              ui.toast.show("Cleared " .. n .. " logged message(s)", "info")
              ui_panel.redraw_now()
            end
          end)
          return nil
        end

        return {
          local_notice = true,
          text = "Unknown subcommand. Try `/msglog toggle`, `watch`, `watch-server`, `status`, `mode disk|memory`, `export`, or `clear`.",
        }
      end,
    })
  end

  if keybinds and keybinds.register and (not platform or platform.is_desktop) then
    pcall(keybinds.register, {
      id = "msglog-toggle-drawer",
      label = "Toggle Message Logger Panel",
      default = "CTRL+SHIFT+L",
      action = function()
        ui_panel.toggle_drawer()
      end,
    })
  end
end

return M
