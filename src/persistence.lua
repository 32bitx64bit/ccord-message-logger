-- Dual-mode message log persistence (v1.0.0):
-- Disk (default, sandboxed Class 2 storage.files JSONL) or Memory-Only (RAM until restart).

local util = require("src.util")
local config = require("src.config")

local M = {}

local MAX_MEM_MEDIA_BYTES = 24 * 1024 * 1024 -- 24 MiB safe ceiling inside 64 MiB Lua heap
local EVENTS_REL = "events.jsonl"
local MEDIA_DIR_REL = "media"
local PRECACHE_DIR_REL = "precache"

-- Chronological list of active logged records (oldest -> newest)
local records = {}
local by_uid = {}
local by_msg_key = {} -- "<channel_id>:<message_id>" -> record

-- Ephemeral RAM media storage used in memory-only mode (key -> raw binary bytes)
local mem_media = {}
local mem_media_order = {}
local mem_media_bytes = 0

local disk_lines_written = 0
local compact_timer_id = nil
local disk_error_reported = false
local change_listeners = {}

local function sfiles()
  return storage and storage.files or nil
end

local function file_exists(rel)
  local sf = sfiles()
  if not (sf and sf.stat) then return false end
  local ok, st = pcall(sf.stat, rel)
  return ok and type(st) == "table"
end

local function emit_change(reason, rec)
  for i = 1, #change_listeners do
    local ok, err = pcall(change_listeners[i], reason, rec)
    if not ok then
      util.safe_log("error", "persistence listener error: " .. tostring(err))
    end
  end
end

local function msg_key(channel_id, message_id)
  return tostring(channel_id or "") .. ":" .. tostring(message_id or "")
end

function M.on_change(fn)
  if type(fn) == "function" then
    change_listeners[#change_listeners + 1] = fn
  end
end

function M.paths()
  return {
    base = "plugin_data://",
    events = EVENTS_REL,
    media = MEDIA_DIR_REL,
    precache = PRECACHE_DIR_REL,
  }
end

function M.ensure_disk_dirs()
  if not config.is_disk_mode() then return true end
  local sf = sfiles()
  if not (sf and sf.mkdir) then return false, "storage.files unavailable" end
  local ok1, err1 = sf.mkdir(MEDIA_DIR_REL)
  if not ok1 then
    if not disk_error_reported then
      disk_error_reported = true
      util.safe_log("error", "Cannot create plugin_data media directory: " .. tostring(err1))
      if ui and ui.toast and ui.toast.show then
        pcall(ui.toast.show, "Message Logger: cannot write to plugin storage (" .. tostring(err1) .. ")", "error")
      end
    end
    return false, err1
  end
  sf.mkdir(PRECACHE_DIR_REL)
  disk_error_reported = false
  return true
end

local function resolve_att_rel(att)
  if type(att) ~= "table" then return nil end
  if type(att.rel_path) == "string" and att.rel_path ~= "" then
    return util.strip_plugin_data_uri(att.rel_path)
  end
  if type(att.local_path) == "string" and att.local_path:sub(1, 14) == "plugin_data://" then
    return util.strip_plugin_data_uri(att.local_path)
  end
  return nil
end

local function remove_record_media(rec)
  if type(rec) ~= "table" or type(rec.attachments) ~= "table" then return end
  local sf = sfiles()
  for i = 1, #rec.attachments do
    local att = rec.attachments[i]
    if type(att) == "table" then
      if type(att.mem_key) == "string" and mem_media[att.mem_key] ~= nil then
        mem_media_bytes = math.max(0, mem_media_bytes - #mem_media[att.mem_key])
        mem_media[att.mem_key] = nil
      end
      local rel = resolve_att_rel(att)
      if rel and sf and sf.remove then
        pcall(sf.remove, rel)
      end
    end
  end
end

local function rebuild_indices()
  by_uid = {}
  by_msg_key = {}
  for i = 1, #records do
    local rec = records[i]
    if rec and rec.uid then
      by_uid[rec.uid] = rec
    end
    if rec and util.is_nonempty_id(rec.channel_id) and util.is_nonempty_id(rec.message_id) then
      by_msg_key[msg_key(rec.channel_id, rec.message_id)] = rec
    end
  end
end

local function prune_to_limit()
  local max_entries = math.max(50, math.floor(tonumber(config.get("max_log_entries")) or 1000))
  if #records <= max_entries then return false end
  local drop = #records - max_entries
  local kept = {}
  for i = 1, drop do
    remove_record_media(records[i])
  end
  for i = drop + 1, #records do
    kept[#kept + 1] = records[i]
  end
  records = kept
  rebuild_indices()
  return true
end

local function serialize_record(rec)
  local ok, encoded = pcall(json.encode, rec)
  if ok and type(encoded) == "string" then
    return encoded
  end
  return nil
end

function M.compact_now()
  if compact_timer_id and time and time.cancel then
    pcall(time.cancel, compact_timer_id)
    compact_timer_id = nil
  end
  if not config.is_disk_mode() then return true end
  local sf = sfiles()
  if not sf then return false, "storage.files unavailable" end
  local ok_dir, dir_err = M.ensure_disk_dirs()
  if not ok_dir then return false, dir_err end

  prune_to_limit()
  local lines = {}
  for i = 1, #records do
    local line = serialize_record(records[i])
    if line then
      lines[#lines + 1] = line
    end
  end

  if #lines == 0 then
    -- Empty log: remove events.jsonl so deleted history can never reappear across reloads/restarts
    if file_exists(EVENTS_REL) then
      local rok = sf.remove and sf.remove(EVENTS_REL)
      if not rok then
        local wok, werr = sf.write(EVENTS_REL, "")
        if not wok then
          util.safe_log("error", "compact empty failed: " .. tostring(werr))
          return false, werr
        end
      end
    end
    disk_lines_written = 0
    return true
  end

  local payload = table.concat(lines, "\n") .. "\n"
  local wok, werr = sf.write(EVENTS_REL, payload)
  if not wok then
    util.safe_log("error", "compact failed: " .. tostring(werr))
    return false, werr
  end
  disk_lines_written = #lines
  return true
end

function M.schedule_compact(delay_ms)
  if not config.is_disk_mode() then return end
  if compact_timer_id and time and time.cancel then
    pcall(time.cancel, compact_timer_id)
    compact_timer_id = nil
  end
  if time and time.after then
    compact_timer_id = time.after(delay_ms or 1500, function()
      compact_timer_id = nil
      M.compact_now()
    end)
  else
    M.compact_now()
  end
end

local function append_record_disk(rec)
  if not config.is_disk_mode() then return true end
  local sf = sfiles()
  if not sf then return false, "storage.files unavailable" end
  local ok_dir, dir_err = M.ensure_disk_dirs()
  if not ok_dir then return false, dir_err end

  local line = serialize_record(rec)
  if not line then return false, "encode failed" end
  local aok, aerr = sf.append(EVENTS_REL, line .. "\n")
  if not aok then
    util.safe_log("error", "append failed: " .. tostring(aerr))
    return false, aerr
  end
  disk_lines_written = disk_lines_written + 1
  local max_entries = math.max(50, math.floor(tonumber(config.get("max_log_entries")) or 1000))
  if #records > max_entries or disk_lines_written > math.max(200, #records * 2) then
    M.schedule_compact(2000)
  end
  return true
end

local function read_events_file()
  local sf = sfiles()
  if not sf then return nil, "storage.files unavailable" end
  local raw, rerr = sf.read(EVENTS_REL)
  if raw ~= nil then return raw, nil end
  -- Fallback to chunked streaming if events.jsonl exceeds the 16 MiB convenience read cap
  if sf.read_chunk then
    local parts = {}
    local offset = 0
    while true do
      local chunk, eof_or_err = sf.read_chunk(EVENTS_REL, offset, 524288)
      if not chunk then
        return nil, tostring(eof_or_err or rerr or "read failed")
      end
      if #chunk > 0 then
        parts[#parts + 1] = chunk
        offset = offset + #chunk
      end
      if eof_or_err == true or #chunk == 0 then break end
    end
    return table.concat(parts), nil
  end
  return nil, rerr
end

function M.load()
  records = {}
  by_uid = {}
  by_msg_key = {}
  disk_lines_written = 0

  if not config.is_disk_mode() then
    util.safe_log("info", "Started in memory-only mode (logs will not persist across restart).")
    emit_change("load", nil)
    return true
  end

  local ok_dir = M.ensure_disk_dirs()
  if not ok_dir then
    emit_change("load", nil)
    return false
  end

  if not file_exists(EVENTS_REL) then
    emit_change("load", nil)
    return true
  end

  local raw, rerr = read_events_file()
  if not raw then
    util.safe_log("warn", "Failed reading events.jsonl: " .. tostring(rerr))
    emit_change("load", nil)
    return false
  end

  local order = {}
  local map = {}
  local total_lines = 0

  for line in raw:gmatch("[^\r\n]+") do
    if line ~= "" then
      total_lines = total_lines + 1
      local ok, obj = pcall(json.decode, line)
      if ok and type(obj) == "table" and type(obj.uid) == "string" and obj.uid ~= "" then
        if map[obj.uid] == nil then
          order[#order + 1] = obj.uid
        end
        map[obj.uid] = obj
      end
    end
  end

  for i = 1, #order do
    local rec = map[order[i]]
    if rec then
      -- Verify sandboxed disk media existence on load
      if type(rec.attachments) == "table" then
        for j = 1, #rec.attachments do
          local att = rec.attachments[j]
          if type(att) == "table" and att.storage == "disk" then
            local rel = resolve_att_rel(att)
            if rel and file_exists(rel) then
              att.rel_path = rel
              att.local_path = util.plugin_data_uri(rel)
              att.saved = true
            else
              att.saved = false
            end
          elseif type(att) == "table" and att.storage == "memory" then
            att.saved = false
            att.storage = "none"
          end
        end
      end
      records[#records + 1] = rec
    end
  end

  disk_lines_written = total_lines
  local pruned = prune_to_limit()
  rebuild_indices()
  if pruned or total_lines > #records + 100 then
    M.schedule_compact(3000)
  end

  util.safe_log("info", string.format("Loaded %d logged message(s) from plugin_data://%s", #records, EVENTS_REL))
  emit_change("load", nil)
  return true
end

function M.on_storage_mode_changed(new_mode)
  disk_error_reported = false
  if new_mode == "disk" then
    local session_records = records
    M.load()
    local merged_count = 0
    for i = 1, #session_records do
      local rec = session_records[i]
      if rec and rec.uid and not by_uid[rec.uid] then
        records[#records + 1] = rec
        merged_count = merged_count + 1
      end
    end
    if merged_count > 0 then
      rebuild_indices()
      M.compact_now()
    end
    emit_change("mode", nil)
  else
    if compact_timer_id and time and time.cancel then
      pcall(time.cancel, compact_timer_id)
      compact_timer_id = nil
    end
    emit_change("mode", nil)
  end
end

function M.find_by_message(channel_id, message_id)
  if not util.is_nonempty_id(channel_id) or not util.is_nonempty_id(message_id) then return nil end
  return by_msg_key[msg_key(channel_id, message_id)]
end

function M.find_by_uid(uid)
  return by_uid[uid]
end

function M.upsert_record(rec)
  if type(rec) ~= "table" then return nil end
  if type(rec.uid) ~= "string" or rec.uid == "" then
    rec.uid = (crypto and crypto.uuid and crypto.uuid()) or (tostring(time and time.now_ms() or 0) .. "-" .. tostring(#records + 1))
  end

  local existing = by_uid[rec.uid]
  if not existing then
    records[#records + 1] = rec
    by_uid[rec.uid] = rec
    if util.is_nonempty_id(rec.channel_id) and util.is_nonempty_id(rec.message_id) then
      by_msg_key[msg_key(rec.channel_id, rec.message_id)] = rec
    end
    local max_entries = math.max(50, math.floor(tonumber(config.get("max_log_entries")) or 1000))
    if #records > max_entries + math.max(25, max_entries // 10) then
      prune_to_limit()
    end
  else
    if existing ~= rec then
      for k, v in pairs(rec) do
        existing[k] = v
      end
      rec = existing
    end
    if util.is_nonempty_id(rec.channel_id) and util.is_nonempty_id(rec.message_id) then
      by_msg_key[msg_key(rec.channel_id, rec.message_id)] = rec
    end
  end

  append_record_disk(rec)
  emit_change("upsert", rec)
  return rec
end

function M.mark_updated(rec)
  if type(rec) ~= "table" or not rec.uid then return end
  -- Never resurrect a record that was already deleted/cleared while an async job was in flight
  if not by_uid[rec.uid] then return end
  append_record_disk(rec)
  emit_change("update", rec)
end

-- Memory-only binary media cache helpers
function M.put_mem_media(key, bytes)
  if type(key) ~= "string" or key == "" or type(bytes) ~= "string" or #bytes == 0 then
    return false, "invalid memory media payload"
  end
  if #bytes > MAX_MEM_MEDIA_BYTES then
    return false, "exceeds 24 MiB in-memory media cap"
  end

  if mem_media[key] ~= nil then
    mem_media_bytes = math.max(0, mem_media_bytes - #mem_media[key])
    mem_media[key] = nil
  end

  while mem_media_bytes + #bytes > MAX_MEM_MEDIA_BYTES and #mem_media_order > 0 do
    local old_k = table.remove(mem_media_order, 1)
    local old_b = mem_media[old_k]
    if old_b then
      mem_media_bytes = math.max(0, mem_media_bytes - #old_b)
      mem_media[old_k] = nil
    end
  end

  mem_media[key] = bytes
  mem_media_order[#mem_media_order + 1] = key
  mem_media_bytes = mem_media_bytes + #bytes
  return true
end

function M.get_mem_media(key)
  return mem_media[key]
end

function M.delete_record(uid)
  local rec = by_uid[uid]
  if not rec then return false end
  remove_record_media(rec)
  local next_list = {}
  for i = 1, #records do
    if records[i].uid ~= uid then
      next_list[#next_list + 1] = records[i]
    end
  end
  records = next_list
  rebuild_indices()
  -- Compact synchronously so reloads/restarts/reinstalls can NEVER resurrect removed history
  M.compact_now()
  emit_change("delete", rec)
  return true
end

function M.clear_channel(channel_id)
  if not util.is_nonempty_id(channel_id) then return 0 end
  local next_list = {}
  local removed = 0
  for i = 1, #records do
    if records[i].channel_id == channel_id then
      remove_record_media(records[i])
      removed = removed + 1
    else
      next_list[#next_list + 1] = records[i]
    end
  end
  if removed > 0 then
    records = next_list
    rebuild_indices()
    M.compact_now()
    emit_change("clear", nil)
  end
  return removed
end

function M.clear_guild(guild_id)
  if not util.is_nonempty_id(guild_id) then return 0 end
  local next_list = {}
  local removed = 0
  for i = 1, #records do
    if records[i].guild_id == guild_id then
      remove_record_media(records[i])
      removed = removed + 1
    else
      next_list[#next_list + 1] = records[i]
    end
  end
  if removed > 0 then
    records = next_list
    rebuild_indices()
    M.compact_now()
    emit_change("clear", nil)
  end
  return removed
end

function M.clear_all()
  local n = #records
  for i = 1, #records do
    remove_record_media(records[i])
  end
  records = {}
  by_uid = {}
  by_msg_key = {}
  mem_media = {}
  mem_media_order = {}
  mem_media_bytes = 0
  M.compact_now()
  emit_change("clear", nil)
  return n
end

-- Query records newest-first with optional filters:
-- opts = { scope = "channel"|"guild"|"all", channel_id?, guild_id?, kind = "all"|"deleted"|"edited"|"media", query = "" }
function M.query(opts)
  opts = opts or {}
  local scope = opts.scope or "all"
  local target_cid = opts.channel_id
  local target_gid = opts.guild_id
  local kind = opts.kind or "all"
  local q = string.lower(util.trim(opts.query or ""))

  local out = {}
  for i = #records, 1, -1 do
    local rec = records[i]
    local match = true

    if scope == "channel" and util.is_nonempty_id(target_cid) then
      if rec.channel_id ~= target_cid then match = false end
    elseif scope == "guild" and util.is_nonempty_id(target_gid) then
      if rec.guild_id ~= target_gid then match = false end
    end

    if match and kind ~= "all" then
      if kind == "deleted" and rec.kind ~= "deleted" then
        match = false
      elseif kind == "edited" and rec.kind ~= "edited" then
        match = false
      elseif kind == "media" then
        local has_media = false
        if type(rec.attachments) == "table" then
          for j = 1, #rec.attachments do
            local att = rec.attachments[j]
            if att and (att.media_kind == "image" or att.media_kind == "video" or att.saved) then
              has_media = true
              break
            end
          end
        end
        if not has_media then match = false end
      end
    end

    if match and q ~= "" then
      local hay = string.lower(
        tostring(rec.author_name or "") .. " " ..
        tostring(rec.content or "") .. " " ..
        tostring(rec.previous_content or "") .. " " ..
        tostring(rec.channel_name or "") .. " " ..
        tostring(rec.guild_name or "")
      )
      local found = hay:find(q, 1, true) ~= nil
      if not found and type(rec.attachments) == "table" then
        for j = 1, #rec.attachments do
          local fn = string.lower(tostring(rec.attachments[j].filename or ""))
          if fn:find(q, 1, true) then
            found = true
            break
          end
        end
      end
      if not found and type(rec.edit_history) == "table" then
        for j = 1, #rec.edit_history do
          local ec = string.lower(tostring(rec.edit_history[j].content or ""))
          if ec:find(q, 1, true) then
            found = true
            break
          end
        end
      end
      if not found then match = false end
    end

    if match then
      out[#out + 1] = rec
    end
  end
  return out
end

function M.count_for_channel(channel_id)
  if not util.is_nonempty_id(channel_id) then return 0 end
  local n = 0
  for i = 1, #records do
    if records[i].channel_id == channel_id then n = n + 1 end
  end
  return n
end

function M.all_records()
  return records
end

function M.stats()
  local deleted_n, edited_n, saved_media_n, disk_media_bytes = 0, 0, 0, 0
  for i = 1, #records do
    local r = records[i]
    if r.kind == "deleted" then deleted_n = deleted_n + 1
    elseif r.kind == "edited" then edited_n = edited_n + 1 end
    if type(r.attachments) == "table" then
      for j = 1, #r.attachments do
        local a = r.attachments[j]
        if a and a.saved then
          saved_media_n = saved_media_n + 1
          if a.storage == "disk" then
            disk_media_bytes = disk_media_bytes + (tonumber(a.saved_bytes) or tonumber(a.size) or 0)
          end
        end
      end
    end
  end

  local jail_used, jail_files = nil, nil
  local sf = sfiles()
  if config.is_disk_mode() and sf and sf.usage then
    local ok, u = pcall(sf.usage)
    if ok and type(u) == "table" then
      jail_used = tonumber(u.used_bytes) or 0
      jail_files = tonumber(u.file_count) or 0
    end
  end

  return {
    total = #records,
    deleted = deleted_n,
    edited = edited_n,
    saved_media = saved_media_n,
    disk_media_bytes = disk_media_bytes,
    jail_used_bytes = jail_used or disk_media_bytes,
    jail_file_count = jail_files or 0,
    mem_media_bytes = mem_media_bytes,
    mode = config.get("storage_mode"),
  }
end

function M.export_json(subset)
  local list = subset or M.query({ scope = "all" })
  local ok, out = pcall(json.encode, {
    exported_at = time and time.now_iso() or "",
    plugin = plugin and plugin.id or "io.github.32bitx64bit.message-logger",
    version = plugin and plugin.version or "1.0.0",
    storage_mode = config.get("storage_mode"),
    count = #list,
    records = list,
  })
  return ok and out or "[]"
end

function M.export_markdown(subset)
  local list = subset or M.query({ scope = "all" })
  local lines = {
    "# C-Cord Message Logger Export",
    "",
    string.format("- Exported: %s", util.format_timestamp_full(time and time.now_ms() or 0)),
    string.format("- Records: %d", #list),
    "",
  }
  for i = 1, #list do
    local r = list[i]
    local tag = (r.kind == "deleted") and "DELETED" or "EDITED"
    local loc = r.is_dm and ("DM " .. tostring(r.channel_name)) or (tostring(r.guild_name) .. " / #" .. tostring(r.channel_name))
    lines[#lines + 1] = string.format("## [%s] %s — %s (%s)",
      tag, tostring(r.author_name or "Unknown"), loc, util.format_timestamp_full(r.logged_at_ms or r.created_at_ms))
    if r.content and r.content ~= "" then
      lines[#lines + 1] = ""
      lines[#lines + 1] = r.content
    end
    if type(r.edit_history) == "table" and #r.edit_history > 0 then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "**Edit History:**"
      for j = 1, #r.edit_history do
        local h = r.edit_history[j]
        lines[#lines + 1] = string.format("- (%s) %s",
          util.format_timestamp_full(h.timestamp_ms), tostring(h.content or ""))
      end
    end
    if type(r.attachments) == "table" and #r.attachments > 0 then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "**Attachments:**"
      for j = 1, #r.attachments do
        local a = r.attachments[j]
        local status = a.saved and (a.local_path or "Saved in memory") or (a.save_error or "Not archived")
        lines[#lines + 1] = string.format("- `%s` (%s, %s) — %s",
          tostring(a.filename or "file"), tostring(a.media_kind or "other"), util.format_bytes(a.saved_bytes or a.size or 0), tostring(status))
      end
    end
    lines[#lines + 1] = ""
  end
  return table.concat(lines, "\n")
end

return M
