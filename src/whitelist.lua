-- Hierarchical channel / DM / category / server whitelist manager.

local util = require("src.util")
local config = require("src.config")

local M = {}

local STORAGE_KEY = "whitelist_v1"

local state = {
  guilds = {},
  categories = {},
  channels = {},
  excluded_channels = {},
}

local badge_ids = {}
local change_listeners = {}
local active_channel_id = ""
local active_guild_id = ""

function M.set_active_channel(channel_id, guild_id)
  active_channel_id = tostring(channel_id or "")
  if guild_id ~= nil then
    active_guild_id = tostring(guild_id or "")
  end
end

function M.get_active_channel()
  if util.is_nonempty_id(active_channel_id) then
    return active_channel_id, active_guild_id
  end
  if store and store.selected then
    local ok, sel = pcall(store.selected)
    if ok and type(sel) == "table" and util.is_nonempty_id(sel.channel_id) then
      active_channel_id = sel.channel_id
      active_guild_id = tostring(sel.guild_id or "")
      return active_channel_id, active_guild_id
    end
  end
  return "", ""
end

local function emit_change(kind, id, added)
  for i = 1, #change_listeners do
    local ok, err = pcall(change_listeners[i], kind, id, added)
    if not ok then
      util.safe_log("error", "whitelist listener error: " .. tostring(err))
    end
  end
end

local function ensure_tables()
  if type(state.guilds) ~= "table" then state.guilds = {} end
  if type(state.categories) ~= "table" then state.categories = {} end
  if type(state.channels) ~= "table" then state.channels = {} end
  if type(state.excluded_channels) ~= "table" then state.excluded_channels = {} end
end

local function save()
  ensure_tables()
  if storage and storage.set then
    local ok, err = pcall(storage.set, STORAGE_KEY, state)
    if not ok then
      util.safe_log("error", "failed to persist whitelist: " .. tostring(err))
    end
  end
end

function M.init()
  local loaded = nil
  if storage and storage.get then
    local ok, val = pcall(storage.get, STORAGE_KEY)
    if ok and type(val) == "table" then
      loaded = val
    end
  end
  if loaded then
    state.guilds = type(loaded.guilds) == "table" and loaded.guilds or {}
    state.categories = type(loaded.categories) == "table" and loaded.categories or {}
    state.channels = type(loaded.channels) == "table" and loaded.channels or {}
    state.excluded_channels = type(loaded.excluded_channels) == "table" and loaded.excluded_channels or {}
  end
  ensure_tables()
end

function M.on_change(fn)
  if type(fn) == "function" then
    change_listeners[#change_listeners + 1] = fn
  end
end

function M.resolve_channel_meta(channel_id, fallback_guild_id)
  local meta = {
    channel_id = tostring(channel_id or ""),
    guild_id = tostring(fallback_guild_id or ""),
    parent_id = nil,
    name = "",
    guild_name = "",
    kind = "text",
    is_dm = false,
  }

  if store and store.channel and util.is_nonempty_id(meta.channel_id) then
    local ok, ch = pcall(store.channel, meta.channel_id)
    if ok and type(ch) == "table" then
      if util.is_nonempty_id(ch.guild_id) then meta.guild_id = ch.guild_id end
      if util.is_nonempty_id(ch.parent_id) then meta.parent_id = ch.parent_id end
      meta.kind = tostring(ch.kind or meta.kind)
      meta.is_dm = (ch.is_dm == true) or (meta.kind == "dm") or (meta.kind == "group_dm") or (meta.guild_id == "dm")
      local disp = ch.display_name
      if type(disp) ~= "string" or disp == "" then disp = ch.name end
      if type(disp) == "string" and disp ~= "" then
        meta.name = disp
      end
    end
  end

  if meta.guild_id == "dm" or meta.guild_id == "" or meta.guild_id == "0" then
    if meta.is_dm or meta.guild_id == "dm" then
      meta.is_dm = true
      meta.guild_id = "dm"
      meta.guild_name = "Direct Messages"
    end
  end

  if not meta.is_dm and store and store.guild and util.is_nonempty_id(meta.guild_id) then
    local ok, g = pcall(store.guild, meta.guild_id)
    if ok and type(g) == "table" then
      if g.is_dm then
        meta.is_dm = true
        meta.guild_name = "Direct Messages"
      elseif type(g.name) == "string" and g.name ~= "" then
        meta.guild_name = g.name
      end
    end
  end

  if meta.name == "" then
    meta.name = meta.is_dm and ("DM " .. meta.channel_id) or ("channel-" .. meta.channel_id)
  end
  if meta.guild_name == "" then
    meta.guild_name = meta.is_dm and "Direct Messages" or (util.is_nonempty_id(meta.guild_id) and ("Server " .. meta.guild_id) or "Unknown")
  end

  return meta
end

function M.resolve_guild_name(guild_id)
  local gid = tostring(guild_id or "")
  if gid == "dm" then return "Direct Messages" end
  if store and store.guild and util.is_nonempty_id(gid) then
    local ok, g = pcall(store.guild, gid)
    if ok and type(g) == "table" and type(g.name) == "string" and g.name ~= "" then
      return g.name
    end
  end
  return "Server " .. gid
end

-- Returns (is_monitored: boolean, reason: string)
function M.is_monitored(guild_id, channel_id, parent_id)
  local cid = tostring(channel_id or "")
  local gid = tostring(guild_id or "")
  local pid = parent_id

  if cid ~= "" and state.excluded_channels[cid] then
    return false, "excluded"
  end

  if config.get("monitor_mode") == "all" then
    return true, "all"
  end

  if cid ~= "" and state.channels[cid] then
    local entry = state.channels[cid]
    return true, entry.is_dm and "dm" or "channel"
  end

  if (not util.is_nonempty_id(pid) or not util.is_nonempty_id(gid)) and cid ~= "" and store and store.channel then
    local ok, ch = pcall(store.channel, cid)
    if ok and type(ch) == "table" then
      if not util.is_nonempty_id(pid) and util.is_nonempty_id(ch.parent_id) then
        pid = ch.parent_id
      end
      if not util.is_nonempty_id(gid) and util.is_nonempty_id(ch.guild_id) then
        gid = ch.guild_id
      end
    end
  end

  if util.is_nonempty_id(pid) and state.categories[pid] then
    return true, "category"
  end

  if util.is_nonempty_id(gid) and gid ~= "dm" and state.guilds[gid] then
    return true, "server"
  end

  -- Active channel monitoring: log whichever channel/DM the user is currently viewing
  if cid ~= "" and config.get("monitor_active_channel") then
    local cur_cid = active_channel_id
    if store and store.selected then
      local ok, sel = pcall(store.selected)
      if ok and type(sel) == "table" and util.is_nonempty_id(sel.channel_id) then
        cur_cid = sel.channel_id
        active_channel_id = cur_cid
        active_guild_id = tostring(sel.guild_id or "")
      end
    end
    if cur_cid ~= "" and cur_cid == cid then
      return true, "active"
    end
  end

  return false, "none"
end

function M.is_explicitly_whitelisted(guild_id, channel_id, parent_id)
  local cid = tostring(channel_id or "")
  local gid = tostring(guild_id or "")
  local pid = parent_id
  if cid ~= "" and state.excluded_channels[cid] then return false end
  if cid ~= "" and state.channels[cid] then return true end
  if (not util.is_nonempty_id(pid) or not util.is_nonempty_id(gid)) and cid ~= "" and store and store.channel then
    local ok, ch = pcall(store.channel, cid)
    if ok and type(ch) == "table" then
      if not util.is_nonempty_id(pid) and util.is_nonempty_id(ch.parent_id) then pid = ch.parent_id end
      if not util.is_nonempty_id(gid) and util.is_nonempty_id(ch.guild_id) then gid = ch.guild_id end
    end
  end
  if util.is_nonempty_id(pid) and state.categories[pid] then return true end
  if util.is_nonempty_id(gid) and gid ~= "dm" and state.guilds[gid] then return true end
  return false
end

function M.is_guild_whitelisted(guild_id)
  return util.is_nonempty_id(guild_id) and state.guilds[guild_id] ~= nil
end

function M.is_channel_whitelisted(channel_id)
  return util.is_nonempty_id(channel_id) and (state.channels[channel_id] ~= nil or state.categories[channel_id] ~= nil)
end

function M.is_channel_excluded(channel_id)
  return util.is_nonempty_id(channel_id) and state.excluded_channels[channel_id] ~= nil
end

function M.toggle_channel(channel_id, fallback_guild_id)
  if not util.is_nonempty_id(channel_id) then return false, "Invalid channel" end
  local meta = M.resolve_channel_meta(channel_id, fallback_guild_id)

  if meta.kind == "category" then
    if state.categories[channel_id] then
      state.categories[channel_id] = nil
      save()
      M.refresh_badges()
      emit_change("category", channel_id, false)
      return false, "Stopped monitoring category " .. meta.name
    else
      state.categories[channel_id] = {
        name = meta.name,
        guild_id = meta.guild_id,
        guild_name = meta.guild_name,
        added_at_ms = time and time.now_ms() or 0,
      }
      save()
      M.refresh_badges()
      emit_change("category", channel_id, true)
      return true, "Now monitoring category " .. meta.name
    end
  end

  if state.channels[channel_id] then
    state.channels[channel_id] = nil
    save()
    M.refresh_badges()
    emit_change("channel", channel_id, false)
    local label = meta.is_dm and ("DM " .. meta.name) or ("#" .. meta.name)
    return false, "Stopped monitoring " .. label
  else
    state.excluded_channels[channel_id] = nil
    state.channels[channel_id] = {
      name = meta.name,
      guild_id = meta.guild_id,
      guild_name = meta.guild_name,
      is_dm = meta.is_dm,
      kind = meta.kind,
      added_at_ms = time and time.now_ms() or 0,
    }
    save()
    M.refresh_badges()
    emit_change("channel", channel_id, true)
    local label = meta.is_dm and ("DM " .. meta.name) or ("#" .. meta.name)
    return true, "Now monitoring " .. label
  end
end

function M.toggle_exclude_channel(channel_id, fallback_guild_id)
  if not util.is_nonempty_id(channel_id) then return false, "Invalid channel" end
  local meta = M.resolve_channel_meta(channel_id, fallback_guild_id)
  local label = meta.is_dm and ("DM " .. meta.name) or ("#" .. meta.name)

  if state.excluded_channels[channel_id] then
    state.excluded_channels[channel_id] = nil
    save()
    M.refresh_badges()
    emit_change("exclude", channel_id, false)
    return false, "Removed exclusion for " .. label
  else
    state.channels[channel_id] = nil
    state.excluded_channels[channel_id] = {
      name = meta.name,
      guild_id = meta.guild_id,
      guild_name = meta.guild_name,
      is_dm = meta.is_dm,
      added_at_ms = time and time.now_ms() or 0,
    }
    save()
    M.refresh_badges()
    emit_change("exclude", channel_id, true)
    return true, "Excluded " .. label .. " from message logging"
  end
end

function M.toggle_guild(guild_id)
  if not util.is_nonempty_id(guild_id) or guild_id == "dm" then
    return false, "Right-click individual DMs to monitor them"
  end
  local gname = M.resolve_guild_name(guild_id)
  if state.guilds[guild_id] then
    state.guilds[guild_id] = nil
    save()
    M.refresh_badges()
    emit_change("guild", guild_id, false)
    return false, "Stopped monitoring server " .. gname
  else
    state.guilds[guild_id] = {
      name = gname,
      added_at_ms = time and time.now_ms() or 0,
    }
    save()
    M.refresh_badges()
    emit_change("guild", guild_id, true)
    return true, "Now monitoring server " .. gname
  end
end

function M.remove_entry(scope, id)
  if not util.is_nonempty_id(id) then return false end
  local bucket = state[scope]
  if type(bucket) ~= "table" or bucket[id] == nil then return false end
  bucket[id] = nil
  save()
  M.refresh_badges()
  emit_change(scope, id, false)
  return true
end

function M.clear_all()
  state.guilds = {}
  state.categories = {}
  state.channels = {}
  state.excluded_channels = {}
  save()
  M.refresh_badges()
  emit_change("clear", "", false)
end

function M.get_all()
  ensure_tables()
  return state
end

function M.counts()
  return {
    guilds = util.table_count(state.guilds),
    categories = util.table_count(state.categories),
    channels = util.table_count(state.channels),
    excluded = util.table_count(state.excluded_channels),
  }
end

function M.refresh_names()
  local changed = false
  for gid, entry in pairs(state.guilds) do
    local name = M.resolve_guild_name(gid)
    if name ~= ("Server " .. gid) and name ~= entry.name then
      entry.name = name
      changed = true
    end
  end
  for cid, entry in pairs(state.channels) do
    local meta = M.resolve_channel_meta(cid, entry.guild_id)
    if meta.name ~= "" and not meta.name:match("^channel%-") and meta.name ~= entry.name then
      entry.name = meta.name
      entry.guild_name = meta.guild_name
      changed = true
    end
  end
  for cid, entry in pairs(state.categories) do
    local meta = M.resolve_channel_meta(cid, entry.guild_id)
    if meta.name ~= "" and not meta.name:match("^channel%-") and meta.name ~= entry.name then
      entry.name = meta.name
      entry.guild_name = meta.guild_name
      changed = true
    end
  end
  if changed then save() end
end

local function clear_badges()
  if not (ui and ui.decorate and ui.decorate.remove) then return end
  for id in pairs(badge_ids) do
    pcall(ui.decorate.remove, id)
  end
  badge_ids = {}
end

function M.refresh_badges()
  clear_badges()
  if not config.get("show_whitelist_badges") then return end
  if not (ui and ui.decorate) then return end

  local accent = util.safe_hex(config.get("deleted_color"), "#e5484d")
  local tint = util.hex_tint(accent, 0.24)

  for gid in pairs(state.guilds) do
    local did = "ml-wl-g-" .. gid
    if #did <= 64 then
      local ok = pcall(ui.decorate.guild_badge, {
        id = did,
        guild_id = gid,
        root = {
          type = "badge",
          label = "LOG",
          bg = accent,
          text_color = "#ffffff",
        },
      })
      if ok then badge_ids[did] = true end
    end
  end

  for cid in pairs(state.channels) do
    local did = "ml-wl-c-" .. cid
    if #did <= 64 then
      local ok = pcall(ui.decorate.channel_badge, {
        id = did,
        channel_id = cid,
        root = {
          type = "badge",
          label = "LOG",
          bg = tint,
          text_color = accent,
        },
      })
      if ok then badge_ids[did] = true end
    end
  end

  for cid in pairs(state.categories) do
    local did = "ml-wl-cat-" .. cid
    if #did <= 64 then
      local ok = pcall(ui.decorate.channel_badge, {
        id = did,
        channel_id = cid,
        root = {
          type = "badge",
          label = "LOG",
          bg = tint,
          text_color = accent,
        },
      })
      if ok then badge_ids[did] = true end
    end
  end

  for cid in pairs(state.excluded_channels) do
    local did = "ml-wl-x-" .. cid
    if #did <= 64 then
      local ok = pcall(ui.decorate.channel_badge, {
        id = did,
        channel_id = cid,
        root = {
          type = "badge",
          label = "OFF",
          bg = "bg_tertiary",
          text_color = "text_muted",
        },
      })
      if ok then badge_ids[did] = true end
    end
  end
end

return M
