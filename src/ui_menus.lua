-- Dynamic right-click context menus across channels, DMs, categories, voice channels, servers, and messages.
-- Uses ui.contextMenu.set_state (zero-IPC cached checkmarks) + resolve(ctx) (live dynamic labels/visibility).

local util = require("src.util")
local config = require("src.config")
local whitelist = require("src.whitelist")
local persistence = require("src.persistence")
local capture = require("src.capture")
local ui_panel = require("src.ui_panel")

local M = {}

local registered_ids = {}

local function safe_label(s)
  return util.truncate(tostring(s or ""), 60)
end

local function add_item(spec)
  if not (ui and ui.contextMenu and ui.contextMenu.add) then return end
  local ok, err = pcall(ui.contextMenu.add, spec)
  if ok then
    registered_ids[#registered_ids + 1] = spec.id
  else
    util.safe_log("warn", "Failed adding context menu '" .. tostring(spec.id) .. "': " .. tostring(err))
  end
end

function M.sync_states()
  if not (ui and ui.contextMenu and ui.contextMenu.set_state and ui.contextMenu.clear_state) then return end
  local wl = whitelist.get_all()

  -- Clear stale per-target caches before repopulating current whitelist state
  pcall(ui.contextMenu.clear_state, "ml-ch-toggle")
  pcall(ui.contextMenu.clear_state, "ml-ch-exclude")
  pcall(ui.contextMenu.clear_state, "ml-vc-toggle")
  pcall(ui.contextMenu.clear_state, "ml-guild-toggle")

  for cid, item in pairs(wl.channels) do
    local lbl = item.is_dm and "Monitor DM" or "Monitor Channel"
    pcall(ui.contextMenu.set_state, "ml-ch-toggle", cid, { label = safe_label(lbl), checked = true })
    pcall(ui.contextMenu.set_state, "ml-vc-toggle", cid, { label = "Monitor Voice Chat", checked = true })
  end

  for cat_id in pairs(wl.categories) do
    pcall(ui.contextMenu.set_state, "ml-ch-toggle", cat_id, { label = "Monitor Category", checked = true })
  end

  for cid in pairs(wl.excluded_channels) do
    pcall(ui.contextMenu.set_state, "ml-ch-exclude", cid, { label = "Excluded from Logging", checked = true })
  end

  for gid in pairs(wl.guilds) do
    pcall(ui.contextMenu.set_state, "ml-guild-toggle", gid, { label = "Monitor Server", checked = true })
  end
end

local function clear_menus()
  if not (ui and ui.contextMenu and ui.contextMenu.remove) then return end
  for i = 1, #registered_ids do
    pcall(ui.contextMenu.remove, registered_ids[i])
  end
  registered_ids = {}
end

local function resolve_channel_toggle(ctx, default_kind_label)
  local cid = ctx and ctx.channel_id
  if not util.is_nonempty_id(cid) then return nil end
  local meta = whitelist.resolve_channel_meta(cid, ctx and ctx.guild_id)
  local is_direct = whitelist.is_channel_whitelisted(cid)
  local noun = (meta.kind == "category") and "Category"
    or (meta.is_dm and "DM" or (default_kind_label or "Channel"))
  return {
    label = safe_label(is_direct and ("Monitoring " .. noun) or ("Monitor " .. noun)),
    checked = is_direct,
  }
end

local function resolve_channel_exclude(ctx)
  local cid = ctx and ctx.channel_id
  if not util.is_nonempty_id(cid) then return { hidden = true } end
  local meta = whitelist.resolve_channel_meta(cid, ctx and ctx.guild_id)
  if meta.kind == "category" then return { hidden = true } end
  local is_ex = whitelist.is_channel_excluded(cid)
  local active_cid = whitelist.get_active_channel()
  local mon_by_other = (config.get("monitor_mode") == "all")
    or (config.get("monitor_active_channel") and active_cid == cid)
    or (util.is_nonempty_id(meta.guild_id) and whitelist.is_guild_whitelisted(meta.guild_id))
    or (util.is_nonempty_id(meta.parent_id) and whitelist.is_channel_whitelisted(meta.parent_id))
  if not is_ex and not mon_by_other then
    return { hidden = true }
  end
  return {
    label = is_ex and "Excluded from Logging" or "Exclude Channel",
    checked = is_ex,
    hidden = false,
  }
end

local function count_for_guild(guild_id)
  if not util.is_nonempty_id(guild_id) then return 0 end
  local all = persistence.all_records()
  local n = 0
  for i = 1, #all do
    if all[i].guild_id == guild_id then n = n + 1 end
  end
  return n
end

function M.init()
  clear_menus()

  -- 1. Channel / DM / Category right-click menu
  add_item({
    id = "ml-ch-toggle",
    label = "Monitor Channel / DM",
    target = "channel",
    submenu = "Message Logger",
    icon = "inbox",
    divider_before = true,
    resolve = function(ctx)
      return resolve_channel_toggle(ctx, "Channel")
    end,
    action = function(ctx)
      local cid = ctx and ctx.channel_id
      local gid = ctx and ctx.guild_id
      if not util.is_nonempty_id(cid) then return end
      local added, msg = whitelist.toggle_channel(cid, gid)
      if added then
        local meta = whitelist.resolve_channel_meta(cid, gid)
        if meta.kind == "category" then
          capture.seed_category(cid, meta.guild_id)
        else
          capture.seed_channel(cid, meta.guild_id)
        end
      end
      M.sync_states()
      if ui and ui.toast then pcall(ui.toast.show, msg, "info") end
      ui_panel.schedule_redraw(50)
    end,
  })

  add_item({
    id = "ml-ch-exclude",
    label = "Exclude Channel",
    target = "channel",
    submenu = "Message Logger",
    icon = "close",
    resolve = resolve_channel_exclude,
    action = function(ctx)
      local cid = ctx and ctx.channel_id
      local gid = ctx and ctx.guild_id
      if not util.is_nonempty_id(cid) then return end
      local _, msg = whitelist.toggle_exclude_channel(cid, gid)
      M.sync_states()
      if ui and ui.toast then pcall(ui.toast.show, msg, "info") end
      ui_panel.schedule_redraw(50)
    end,
  })

  add_item({
    id = "ml-ch-view",
    label = "View Channel Logs",
    target = "channel",
    submenu = "Message Logger",
    icon = "search",
    resolve = function(ctx)
      local cid = ctx and ctx.channel_id
      if not util.is_nonempty_id(cid) then return nil end
      local cnt = persistence.count_for_channel(cid)
      return {
        label = safe_label(cnt > 0 and string.format("View Channel Logs (%d)", cnt) or "View Channel Logs"),
      }
    end,
    action = function(ctx)
      ui_panel.open_drawer({
        tab = "logs",
        scope = "channel",
        filter = "all",
        channel_id = ctx and ctx.channel_id or nil,
        guild_id = ctx and ctx.guild_id or nil,
      })
    end,
  })

  add_item({
    id = "ml-ch-clear",
    label = "Clear Channel Logs",
    target = "channel",
    submenu = "Message Logger",
    danger = true,
    resolve = function(ctx)
      local cid = ctx and ctx.channel_id
      local cnt = util.is_nonempty_id(cid) and persistence.count_for_channel(cid) or 0
      return { hidden = (cnt == 0), danger = true }
    end,
    action = function(ctx)
      local cid = ctx and ctx.channel_id
      if not util.is_nonempty_id(cid) then return end
      local meta = whitelist.resolve_channel_meta(cid, ctx and ctx.guild_id)
      local lbl = meta.is_dm and ("DM " .. meta.name) or ("#" .. meta.name)
      async.spawn(function()
        local res = ui.dialog.confirm({
          title = "Clear Channel Logs",
          message = "Delete all logged messages & archived media for " .. lbl .. "?",
          confirm_label = "Clear",
        })
        if res and res.accepted then
          local n = persistence.clear_channel(cid)
          capture.clear_inline_deleted_channel(cid)
          ui.toast.show("Cleared " .. n .. " log(s) for " .. lbl, "info")
          ui_panel.schedule_redraw(50)
        end
      end)
    end,
  })

  -- 2. Voice Channel right-click menu
  add_item({
    id = "ml-vc-toggle",
    label = "Monitor Voice Chat",
    target = "voice_channel",
    submenu = "Message Logger",
    icon = "inbox",
    divider_before = true,
    resolve = function(ctx)
      return resolve_channel_toggle(ctx, "Voice Chat")
    end,
    action = function(ctx)
      local cid = ctx and ctx.channel_id
      local gid = ctx and ctx.guild_id
      if not util.is_nonempty_id(cid) then return end
      local added, msg = whitelist.toggle_channel(cid, gid)
      if added then capture.seed_channel(cid, gid) end
      M.sync_states()
      if ui and ui.toast then pcall(ui.toast.show, msg, "info") end
      ui_panel.schedule_redraw(50)
    end,
  })

  add_item({
    id = "ml-vc-view",
    label = "View Voice Chat Logs",
    target = "voice_channel",
    submenu = "Message Logger",
    icon = "search",
    resolve = function(ctx)
      local cid = ctx and ctx.channel_id
      local cnt = util.is_nonempty_id(cid) and persistence.count_for_channel(cid) or 0
      return {
        label = safe_label(cnt > 0 and string.format("View Voice Chat Logs (%d)", cnt) or "View Voice Chat Logs"),
      }
    end,
    action = function(ctx)
      ui_panel.open_drawer({
        tab = "logs",
        scope = "channel",
        filter = "all",
        channel_id = ctx and ctx.channel_id or nil,
        guild_id = ctx and ctx.guild_id or nil,
      })
    end,
  })

  -- 3. Server (Guild) right-click menu
  add_item({
    id = "ml-guild-toggle",
    label = "Monitor Server",
    target = "guild",
    submenu = "Message Logger",
    icon = "inbox",
    divider_before = true,
    resolve = function(ctx)
      local gid = ctx and ctx.guild_id
      if not util.is_nonempty_id(gid) or gid == "dm" then return { hidden = true } end
      local on = whitelist.is_guild_whitelisted(gid)
      return {
        label = on and "Monitoring Server" or "Monitor Server",
        checked = on,
      }
    end,
    action = function(ctx)
      local gid = ctx and ctx.guild_id
      if not util.is_nonempty_id(gid) then return end
      local added, msg = whitelist.toggle_guild(gid)
      if added then capture.seed_guild(gid) end
      M.sync_states()
      if ui and ui.toast then pcall(ui.toast.show, msg, "info") end
      ui_panel.schedule_redraw(50)
    end,
  })

  add_item({
    id = "ml-guild-view",
    label = "View Server Logs",
    target = "guild",
    submenu = "Message Logger",
    icon = "search",
    resolve = function(ctx)
      local gid = ctx and ctx.guild_id
      local cnt = util.is_nonempty_id(gid) and count_for_guild(gid) or 0
      return {
        label = safe_label(cnt > 0 and string.format("View Server Logs (%d)", cnt) or "View Server Logs"),
      }
    end,
    action = function(ctx)
      ui_panel.open_drawer({
        tab = "logs",
        scope = "guild",
        filter = "all",
        guild_id = ctx and ctx.guild_id or nil,
        channel_id = nil,
      })
    end,
  })

  add_item({
    id = "ml-guild-clear",
    label = "Clear Server Logs",
    target = "guild",
    submenu = "Message Logger",
    danger = true,
    resolve = function(ctx)
      local gid = ctx and ctx.guild_id
      local cnt = util.is_nonempty_id(gid) and count_for_guild(gid) or 0
      return { hidden = (cnt == 0), danger = true }
    end,
    action = function(ctx)
      local gid = ctx and ctx.guild_id
      if not util.is_nonempty_id(gid) then return end
      local gname = whitelist.resolve_guild_name(gid)
      async.spawn(function()
        local res = ui.dialog.confirm({
          title = "Clear Server Logs",
          message = "Delete all logged messages & archived media for " .. gname .. "?",
          confirm_label = "Clear",
        })
        if res and res.accepted then
          local n = persistence.clear_guild(gid)
          capture.refresh_all_inline_deleted()
          capture.refresh_all_inline_edits()
          ui.toast.show("Cleared " .. n .. " log(s) for " .. gname, "info")
          ui_panel.schedule_redraw(50)
        end
      end)
    end,
  })

  -- 4. Message right-click menu
  add_item({
    id = "ml-msg-watch",
    label = "Whitelist Channel (Idle)",
    target = "message",
    submenu = "Message Logger",
    icon = "inbox",
    divider_before = true,
    resolve = function(ctx)
      local cid = ctx and ctx.channel_id
      local gid = ctx and ctx.guild_id
      if not util.is_nonempty_id(cid) then return nil end
      local wl_on = whitelist.is_explicitly_whitelisted(gid, cid)
      return {
        label = wl_on and "Whitelisted (Background)" or "Whitelist Channel (Background)",
        checked = wl_on,
      }
    end,
    action = function(ctx)
      local cid = ctx and ctx.channel_id
      local gid = ctx and ctx.guild_id
      if not util.is_nonempty_id(cid) then return end
      local added, msg = whitelist.toggle_channel(cid, gid)
      if added then capture.seed_channel(cid, gid) end
      M.sync_states()
      if ui and ui.toast then pcall(ui.toast.show, msg, "info") end
      ui_panel.schedule_redraw(50)
    end,
  })

  add_item({
    id = "ml-msg-open",
    label = "Open Channel Logs",
    target = "message",
    submenu = "Message Logger",
    icon = "search",
    resolve = function(ctx)
      local cid = ctx and ctx.channel_id
      local cnt = util.is_nonempty_id(cid) and persistence.count_for_channel(cid) or 0
      return {
        label = safe_label(cnt > 0 and string.format("Open Channel Logs (%d)", cnt) or "Open Channel Logs"),
      }
    end,
    action = function(ctx)
      ui_panel.open_drawer({
        tab = "logs",
        scope = "channel",
        filter = "all",
        channel_id = ctx and ctx.channel_id or nil,
        guild_id = ctx and ctx.guild_id or nil,
      })
    end,
  })

  add_item({
    id = "ml-msg-archive-media",
    label = "Archive Message Media Now",
    target = "message",
    submenu = "Message Logger",
    icon = "attachment",
    when = { has_attachments = true },
    action = function(ctx)
      if not ctx then return end
      local ok, msg = capture.archive_existing_message(ctx.guild_id, ctx.channel_id, ctx.message_id)
      if ui and ui.toast then
        pcall(ui.toast.show, msg, ok and "info" or "warn")
      end
      if ok then ui_panel.schedule_redraw(150) end
    end,
  })

  M.sync_states()
end

return M
