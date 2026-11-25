-- C-Cord Message Logger Plugin v1.0.0
-- Native in-place deleted messages, in-message above_body edit history,
-- sandboxed Class 2 storage.files persistence or RAM-only mode,
-- cross-platform image & video archiving with native lightbox, and right-click whitelisting.

local util = require("src.util")
local config = require("src.config")
local whitelist = require("src.whitelist")
local persistence = require("src.persistence")
local media = require("src.media")
local capture = require("src.capture")
local ui_panel = require("src.ui_panel")
local ui_menus = require("src.ui_menus")
local commands_mod = require("src.commands")

-- 1. Initialize settings, whitelist, and persistence
config.init()
whitelist.init()
persistence.load()
media.cleanup_precache(true)

-- 2. Wire internal cross-module reactive hooks
capture.set_open_log_handler(function(channel_id, filter)
  ui_panel.open_drawer({
    tab = "logs",
    scope = "channel",
    filter = filter or "all",
    channel_id = channel_id,
  })
end)

persistence.on_change(function()
  ui_panel.schedule_redraw(120)
end)

whitelist.on_change(function()
  ui_menus.sync_states()
  ui_panel.schedule_redraw(80)
end)

local function seed_active_channel()
  if store and store.selected then
    local ok, sel = pcall(store.selected)
    if ok and type(sel) == "table" and util.is_nonempty_id(sel.channel_id) then
      whitelist.set_active_channel(sel.channel_id, sel.guild_id)
      capture.seed_channel(sel.channel_id, sel.guild_id)
    end
  end
end

config.on_change(function(key, val)
  if key == "storage_mode" then
    persistence.on_storage_mode_changed(val)
    media.cleanup_precache(false)
    ui_panel.schedule_redraw(50)
  elseif key == "max_log_entries" then
    persistence.schedule_compact(400)
  elseif key == "max_media_total_mb" then
    media.enforce_disk_quota()
  elseif key == "show_whitelist_badges" or key == "deleted_color" then
    whitelist.refresh_badges()
    capture.refresh_all_inline_deleted()
    ui_panel.schedule_redraw(80)
  elseif key == "deleted_avatar_opacity" or key == "show_deleted_tint" or key == "show_deleted_accent_bar" then
    capture.refresh_all_inline_deleted()
    ui_panel.schedule_redraw(80)
  elseif key == "edited_color" or key == "edited_style" then
    capture.refresh_all_inline_edits()
    ui_panel.schedule_redraw(80)
  elseif key == "decorate_edited" then
    if not val then
      capture.clear_all_edit_decorators()
    else
      if store and store.selected then
        local ok, sel = pcall(store.selected)
        if ok and type(sel) == "table" and util.is_nonempty_id(sel.channel_id) then
          capture.restore_inline_deleted_for_channel(sel.channel_id)
        end
      end
    end
    capture.refresh_all_inline_deleted()
  elseif key == "show_inline_deleted" then
    if not val then
      capture.refresh_all_inline_deleted()
    else
      if store and store.selected then
        local ok, sel = pcall(store.selected)
        if ok and type(sel) == "table" and util.is_nonempty_id(sel.channel_id) then
          capture.restore_inline_deleted_for_channel(sel.channel_id)
        end
      end
    end
  elseif key == "show_header_button" then
    ui_panel.refresh_header_button()
  elseif key == "show_rail_tab" then
    ui_panel.sync_rail_tab()
  elseif key == "monitor_mode" or key == "monitor_active_channel" then
    seed_active_channel()
    ui_panel.schedule_redraw(80)
  end
end)

-- Wire native Settings Maintenance action buttons (each runs in a 2,000 ms user-gesture window)
config.on_action(function(key)
  if key == "export_logs_btn" then
    local payload = persistence.export_json()
    async.spawn(function()
      local saved = ui.file.save({ suggested_name = "ccord-message-logs.json", data = payload })
      if saved and saved.path then
        ui.toast.show("Exported logs to " .. saved.path, "info")
      end
    end)
  elseif key == "clear_precache_btn" then
    media.cleanup_precache(false)
    if ui and ui.toast then pcall(ui.toast.show, "Cleared temporary media pre-cache", "info") end
    ui_panel.schedule_redraw(50)
  elseif key == "clear_all_logs_btn" then
    async.spawn(function()
      local res = ui.dialog.confirm({
        title = "Clear All Message Logs",
        message = "Permanently delete every logged message and archived media file?",
        confirm_label = "Clear All",
      })
      if res and res.accepted then
        local n = persistence.clear_all()
        capture.clear_all_inline_deleted()
        media.cleanup_precache(true)
        media.clear_preview_textures()
        ui.toast.show("Cleared " .. n .. " logged message(s)", "info")
        ui_panel.redraw_now()
      end
    end)
  end
end)

-- 3. Initialize native UI surfaces, right-click menus, slash commands, and keybind
ui_menus.init()
ui_panel.init()
commands_mod.init()

-- 4. Subscribe to navigation, lifecycle, and upgraded events.messages (zero polling, zero gateway.raw!)
events.on("app.ready", function()
  whitelist.refresh_names()
  whitelist.refresh_badges()
  seed_active_channel()
  ui_panel.schedule_redraw(100)
end)

events.on("guilds.loaded", function()
  whitelist.refresh_names()
  whitelist.refresh_badges()
  seed_active_channel()
  ui_panel.schedule_redraw(100)
end)

events.on("channel.select", function(ev)
  if type(ev) == "table" and util.is_nonempty_id(ev.channel_id) then
    whitelist.set_active_channel(ev.channel_id, ev.guild_id)
    capture.seed_channel(ev.channel_id, ev.guild_id)
  end
  ui_panel.on_navigation_changed()
end)

events.on("guild.select", function()
  ui_panel.on_navigation_changed()
end)

events.on("channel.upsert", function()
  whitelist.refresh_names()
end)

events.on("theme.change", function()
  whitelist.refresh_badges()
  ui_panel.schedule_redraw(100)
end)

-- Upgraded Class 2 events.messages (includes attachments, embeds, author_bot, bulk deletes, and messages.loaded)
events.on("message.create", capture.handle_message_create)
events.on("message.update", capture.handle_message_update)
events.on("message.delete", capture.handle_message_delete)
events.on("message.delete_bulk", capture.handle_message_delete_bulk)
events.on("messages.loaded", capture.handle_messages_loaded)

-- Clean teardown on disable, reload, uninstall, or C-Cord quit (synchronous within 350 ms budget)
if plugin and plugin.on_unload then
  plugin.on_unload(function(reason)
    persistence.compact_now()
    if reason == "uninstall" or reason == "quit" then
      media.cleanup_precache(false)
    end
  end)
end

-- Expose lightweight stats RPC
if plugin and plugin.expose then
  pcall(plugin.expose, "stats", function()
    return {
      stats = persistence.stats(),
      whitelist = whitelist.counts(),
      cached_messages = capture.cached_count(),
    }
  end, { allow_lower_class = true })
end

-- Initial refresh in case plugin was hot-reloaded after app.ready
whitelist.refresh_badges()
seed_active_channel()

local st = persistence.stats()
util.safe_log("info", string.format(
  "Ready v%s (mode=%s, logs=%d, storage=%s)",
  tostring(plugin and plugin.version or "1.0.0"),
  tostring(st.mode),
  st.total,
  st.mode == "disk" and "plugin_data://" or "RAM"
))
