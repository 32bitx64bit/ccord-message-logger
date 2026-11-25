-- Live message snapshot cache, delete/edit event capture via upgraded events.messages,
-- native timeline deleted rows (messages.inject_local position="timeline"), and
-- in-message former-version edit accessories (ui.decorate.message_accessory position="above_body").

local util = require("src.util")
local config = require("src.config")
local whitelist = require("src.whitelist")
local persistence = require("src.persistence")
local media = require("src.media")

local M = {}

local MAX_EDIT_DECORATORS = 120
local MAX_INLINE_EDIT_VERSIONS = 12
local MAX_PROCESSED_DELETES = 600
local MAX_SEED_PRECACHE = 8
local MAX_LOCAL_ATTACHMENTS = 8

-- Per-channel live snapshot cache:
-- channel_cache[cid] = { map = { [mid] = snap }, order = { mid1, mid2, ... } }
local channel_cache = {}
local precached_msgs = {}

-- Deduplication set for delete events
local processed_deletes = {}
local processed_deletes_order = {}

-- Active in-message above_body edit accessories (FIFO eviction per edited message)
local edit_decor_order = {}
local active_edit_acc = {} -- message_id -> { id, uid, channel_id, message_id }

-- Active native timeline local messages (deleted rows): stable_id -> { uid, channel_id, local_id }
local active_timeline_msgs = {}
local inline_hidden_uids = {} -- in-memory cache mirrored with persisted rec.dismissed_inline

local on_open_log_cb = nil

function M.set_open_log_handler(fn)
  on_open_log_cb = fn
end

local function is_inline_dismissed(rec)
  if type(rec) ~= "table" then return true end
  return inline_hidden_uids[rec.uid] == true or rec.dismissed_inline == true
end

local function make_stable_id(rec)
  local mid = util.sanitize_filename(tostring(rec.message_id or rec.uid or "0"), "0")
  local sid = "ml-del-" .. mid
  if #sid > 64 then sid = sid:sub(1, 64) end
  return sid
end

local function make_deleted_history_id(rec)
  local prefix = "ml-del-"
  local suffix = "-ed"
  local max_mid = 64 - #prefix - #suffix
  local mid = util.sanitize_filename(tostring(rec.message_id or rec.uid or "0"), "0")
  if #mid > max_mid then mid = mid:sub(1, max_mid) end
  return prefix .. mid .. suffix
end

local function make_edit_decor_id(message_id)
  local mid = util.sanitize_filename(tostring(message_id or "0"), "0")
  local did = "ml-ed-" .. mid
  if #did > 64 then did = did:sub(1, 64) end
  return did
end

local function get_self_id()
  if store and store.self then
    local ok, me = pcall(store.self)
    if ok and type(me) == "table" and util.is_nonempty_id(me.id) then
      return me.id
    end
  end
  return nil
end

local function normalize_attachments(raw_atts)
  if type(raw_atts) ~= "table" or #raw_atts == 0 then return {} end
  local out = {}
  for i = 1, #raw_atts do
    local a = raw_atts[i]
    if type(a) == "table" then
      local item = {
        id = tostring(a.id or i),
        filename = tostring(a.filename or ("attachment_" .. i)),
        content_type = tostring(a.content_type or ""),
        url = tostring(a.url or ""),
        size = tonumber(a.size) or 0,
        width = tonumber(a.width) or 0,
        height = tonumber(a.height) or 0,
        saved = false,
        storage = "none",
        status = "none",
      }
      item.media_kind = util.classify_attachment(item)
      out[#out + 1] = item
    end
  end
  return out
end

local function normalize_embeds(raw_embeds)
  if type(raw_embeds) ~= "table" or #raw_embeds == 0 then return {} end
  local out = {}
  for i = 1, #raw_embeds do
    local e = raw_embeds[i]
    if type(e) == "table" then
      out[#out + 1] = {
        title = tostring(e.title or ""),
        description = tostring(e.description or ""),
        url = tostring(e.url or ""),
        color = tonumber(e.color),
      }
    end
  end
  return out
end

local function ensure_channel_bucket(channel_id)
  local b = channel_cache[channel_id]
  if not b then
    b = { map = {}, order = {} }
    channel_cache[channel_id] = b
  end
  return b
end

local function cache_snapshot(snap, allow_precache)
  if type(snap) ~= "table" or not util.is_nonempty_id(snap.channel_id) or not util.is_valid_snowflake(snap.id) then
    return nil
  end
  local b = ensure_channel_bucket(snap.channel_id)
  local existing = b.map[snap.id]

  if existing then
    if snap.guild_id and snap.guild_id ~= "" and snap.guild_id ~= "0" then
      existing.guild_id = snap.guild_id
    end
    if snap.author_id and snap.author_id ~= "" and snap.author_id ~= "0" then
      existing.author_id = snap.author_id
    end
    if snap.author_name and snap.author_name ~= "" then
      existing.author_name = snap.author_name
    end
    if snap.author_bot ~= nil then
      existing.author_bot = snap.author_bot
    end
    if util.is_nonempty_id(snap.reply_to_id) then
      existing.reply_to_id = snap.reply_to_id
    end
    if type(snap.content) == "string" and (snap.content ~= "" or existing.content == nil) then
      existing.content = snap.content
    end
    if snap.timestamp_ms and snap.timestamp_ms > 0 and (not existing.timestamp_ms or existing.timestamp_ms <= 0) then
      existing.timestamp_ms = snap.timestamp_ms
    end
    if type(snap.attachments) == "table" and #snap.attachments > 0 then
      if type(existing.attachments) ~= "table" or #existing.attachments == 0 then
        existing.attachments = snap.attachments
      else
        for i = 1, math.min(#existing.attachments, #snap.attachments) do
          local ea, na = existing.attachments[i], snap.attachments[i]
          if ea.url == "" and na.url ~= "" then ea.url = na.url end
          if ea.content_type == "" and na.content_type ~= "" then
            ea.content_type = na.content_type
            ea.media_kind = util.classify_attachment(ea)
          end
        end
      end
    end
    if type(snap.embeds) == "table" and #snap.embeds > 0 and (#(existing.embeds or {}) == 0) then
      existing.embeds = snap.embeds
    end
    snap = existing
  else
    b.map[snap.id] = snap
    b.order[#b.order + 1] = snap.id
    local cap = math.max(50, math.floor(tonumber(config.get("cache_per_channel")) or 200))
    while #b.order > cap do
      local old_id = table.remove(b.order, 1)
      b.map[old_id] = nil
      precached_msgs[snap.channel_id .. ":" .. old_id] = nil
    end
  end

  if allow_precache and type(snap.attachments) == "table" and #snap.attachments > 0 then
    local pk = snap.channel_id .. ":" .. snap.id
    if not precached_msgs[pk] then
      precached_msgs[pk] = true
      media.precache_message(snap)
    end
  end

  return snap
end

local function snapshot_from_msg(msg, fallback_guild_id)
  if type(msg) ~= "table" or not util.is_valid_snowflake(msg.id) then return nil end
  local gid = util.is_nonempty_id(msg.guild_id) and msg.guild_id or tostring(fallback_guild_id or "")
  return {
    id = msg.id,
    channel_id = tostring(msg.channel_id or ""),
    guild_id = gid,
    author_id = tostring(msg.author_id or ""),
    author_name = tostring(msg.author_name or "Unknown"),
    author_bot = (msg.author_bot ~= nil) and (msg.author_bot == true) or nil,
    reply_to_id = util.is_nonempty_id(msg.reply_to_id) and msg.reply_to_id or nil,
    content = tostring(msg.content or ""),
    timestamp_ms = tonumber(msg.timestamp_ms) or (time and time.now_ms() or 0),
    attachments = normalize_attachments(msg.attachments),
    embeds = normalize_embeds(msg.embeds),
  }
end

local function passes_author_filters(author_id, author_bot)
  if config.get("ignore_bots") and author_bot == true then
    return false
  end
  if config.get("ignore_self") then
    local me_id = get_self_id()
    if me_id and author_id == me_id then
      return false
    end
  end
  return true
end

-- ---- Formatting Helpers ----

local function build_former_versions_text(rec)
  local hist = rec.edit_history
  if type(hist) ~= "table" or #hist == 0 then return nil end
  local start_i = math.max(1, #hist - MAX_INLINE_EDIT_VERSIONS + 1)
  local lines = {}
  for i = start_i, #hist do
    local txt = tostring(hist[i].content or "")
    if txt == "" then txt = "_(empty)_" end
    txt = util.truncate(txt, 900)
    local tag = string.format("*v%d*", i)
    if txt:find("\n", 1, true) then
      lines[#lines + 1] = tag .. "\n" .. txt
    else
      lines[#lines + 1] = tag .. "  " .. txt
    end
    lines[#lines + 1] = "────────────────────────"
  end
  local out = table.concat(lines, "\n")
  if #out > 7600 then
    out = util.truncate(out, 7500)
  end
  return out
end

-- ---- Native Timeline Deleted Messages (messages.inject_local position="timeline") ----

local function build_local_attachments(rec)
  if type(rec.attachments) ~= "table" or #rec.attachments == 0 then return nil end
  local out = {}
  local n = math.min(#rec.attachments, MAX_LOCAL_ATTACHMENTS)
  for i = 1, n do
    local a = rec.attachments[i]
    if type(a) == "table" then
      local spec = {
        filename = tostring(a.filename or ("attachment_" .. i)),
        content_type = (type(a.content_type) == "string" and a.content_type ~= "") and a.content_type or nil,
        size = tonumber(a.saved_bytes) or tonumber(a.size) or nil,
        width = (tonumber(a.width) and a.width > 0) and a.width or nil,
        height = (tonumber(a.height) and a.height > 0) and a.height or nil,
      }
      if a.saved and a.media_kind == "image" then
        local uri = a.local_path or util.plugin_data_uri(a.rel_path)
        if a.storage == "disk" and uri and util.is_previewable_image(a, true) then
          spec.local_path = uri
        elseif a.storage == "memory" then
          local tex = media.ensure_preview_texture(a)
          if tex then spec.texture_key = tex end
        end
      end
      out[#out + 1] = spec
    end
  end
  return (#out > 0) and out or nil
end

local function build_deleted_body(rec)
  local body = tostring(rec.content or "")
  if body == "" and (type(rec.attachments) ~= "table" or #rec.attachments == 0) then
    body = "_(empty message)_"
  end
  if #body > 7600 then
    body = util.truncate(body, 7500)
  end
  return body
end

function M.render_timeline_deleted(rec)
  if not config.get("show_inline_deleted") then return false end
  if not (messages and messages.inject_local) then return false end
  if type(rec) ~= "table" or rec.kind ~= "deleted" or not util.is_nonempty_id(rec.channel_id) then return false end
  if is_inline_dismissed(rec) then return false end

  local del_col = util.safe_hex(config.get("deleted_color"), "#e5484d")
  local av_pct = math.max(20, math.min(100, tonumber(config.get("deleted_avatar_opacity")) or 55))
  local av_opacity = av_pct / 100.0
  local stable_id = make_stable_id(rec)
  local hist_id = make_deleted_history_id(rec)
  local author = util.truncate(tostring(rec.author_name or "Unknown"), 120)
  if author == "" then author = "Unknown" end
  local sort_id = util.is_valid_snowflake(rec.message_id) and rec.message_id or nil
  local base_ts = tonumber(rec.created_at_ms) or tonumber(rec.logged_at_ms) or (time and time.now_ms() or 0)
  local author_id = util.is_nonempty_id(rec.author_id) and rec.author_id or nil
  local accent_col = config.get("show_deleted_accent_bar") and del_col or nil
  local tint_col = config.get("show_deleted_tint") and util.hex_tint(del_col, 0.08) or nil
  local badge = rec.bulk_deleted and "BULK DELETED" or "DELETED"

  local former_text = config.get("decorate_edited") and build_former_versions_text(rec) or nil

  local function make_event_handler(sibling_id)
    return function(ev)
      if type(ev) ~= "table" then return end
      if ev.type == "dismiss" then
        inline_hidden_uids[rec.uid] = true
        active_timeline_msgs[stable_id] = nil
        if sibling_id and messages and messages.dismiss_local then
          pcall(messages.dismiss_local, sibling_id)
        end
        rec.dismissed_inline = true
        persistence.mark_updated(rec)
      elseif ev.type == "right_click" and on_open_log_cb then
        pcall(on_open_log_cb, rec.channel_id, "deleted", rec.uid)
      end
    end
  end

  if former_text then
    -- Two seamlessly joined native rows under the same sort_id so former versions stay ABOVE
    -- the final deleted text in muted gray (matching live edited messages), while the header
    -- and final deleted body render in red with greyscale avatar!
    local ok_h, lid_h, err_h = pcall(messages.inject_local, rec.channel_id, {
      id = hist_id,
      position = "timeline",
      sort_id = sort_id,
      timestamp_ms = base_ts,
      clip_to_history = true,
      author_id = author_id,
      author = author,
      author_color = del_col,
      avatar_grayscale = true,
      avatar_opacity = av_opacity,
      badge = badge,
      badge_color = del_col,
      content = former_text,
      text_color = "text_muted",
      accent_color = accent_col,
      tint_color = tint_col,
      compact = "auto",
      break_group = false,
      dismissible = true,
      on_event = make_event_handler(stable_id),
    })

    local ok_b, lid_b, err_b = pcall(messages.inject_local, rec.channel_id, {
      id = stable_id,
      position = "timeline",
      sort_id = sort_id,
      timestamp_ms = base_ts + 1,
      clip_to_history = true,
      author_id = author_id,
      author = author,
      author_color = del_col,
      avatar_grayscale = true,
      avatar_opacity = av_opacity,
      badge = badge,
      badge_color = del_col,
      content = build_deleted_body(rec),
      text_color = del_col,
      accent_color = accent_col,
      tint_color = tint_col,
      compact = "always",
      break_group = false,
      attachments = build_local_attachments(rec),
      dismissible = true,
      on_event = make_event_handler(hist_id),
    })

    if ok_b and lid_b then
      active_timeline_msgs[stable_id] = {
        uid = rec.uid,
        channel_id = rec.channel_id,
        local_id = lid_b,
        history_id = (ok_h and lid_h) and hist_id or nil,
      }
      return true
    end
    util.safe_log("warn", "messages.inject_local failed for edited-deleted msg " .. tostring(rec.message_id) .. ": " .. tostring(not ok_b and lid_b or err_b or err_h))
    return false
  end

  -- Non-edited deleted message (or decorate_edited off): remove any stale history sibling row
  local prev = active_timeline_msgs[stable_id]
  if prev and prev.history_id and messages.dismiss_local then
    pcall(messages.dismiss_local, prev.history_id)
  end

  local ok, lid, ierr = pcall(messages.inject_local, rec.channel_id, {
    id = stable_id,
    position = "timeline",
    sort_id = sort_id,
    timestamp_ms = base_ts,
    clip_to_history = true,
    author_id = author_id,
    author = author,
    author_color = del_col,
    avatar_grayscale = true,
    avatar_opacity = av_opacity,
    badge = badge,
    badge_color = del_col,
    content = build_deleted_body(rec),
    text_color = del_col,
    accent_color = accent_col,
    tint_color = tint_col,
    compact = "auto",
    break_group = false,
    attachments = build_local_attachments(rec),
    dismissible = true,
    on_event = make_event_handler(nil),
  })
  if ok and lid then
    active_timeline_msgs[stable_id] = {
      uid = rec.uid,
      channel_id = rec.channel_id,
      local_id = lid,
      history_id = nil,
    }
    return true
  end
  util.safe_log("warn", "messages.inject_local failed for msg " .. tostring(rec.message_id) .. ": " .. tostring(not ok and lid or ierr))
  return false
end

function M.update_timeline_deleted_attachments(rec)
  if not config.get("show_inline_deleted") then return end
  if not (messages and messages.update_local) then return end
  if type(rec) ~= "table" or rec.kind ~= "deleted" then return end
  local sid = make_stable_id(rec)
  if not active_timeline_msgs[sid] then return end
  local atts = build_local_attachments(rec)
  if atts then
    pcall(messages.update_local, sid, { attachments = atts })
  end
end

-- ---- In-Message Former-Version Accessories (ui.decorate.message_accessory position="above_body") ----

local function clear_edit_decor_for(message_id)
  if not util.is_nonempty_id(message_id) then return end
  local info = active_edit_acc[message_id]
  if info and info.id and ui and ui.decorate and ui.decorate.remove then
    pcall(ui.decorate.remove, info.id)
  end
  active_edit_acc[message_id] = nil
end

function M.clear_all_edit_decorators()
  if ui and ui.decorate and ui.decorate.remove then
    for _, info in pairs(active_edit_acc) do
      if info and info.id then
        pcall(ui.decorate.remove, info.id)
      end
    end
  end
  edit_decor_order = {}
  active_edit_acc = {}
end

local function apply_edit_decorators(rec)
  if not config.get("decorate_edited") then return end
  if not (ui and ui.decorate and ui.decorate.message_accessory) then return end
  if not rec or not util.is_nonempty_id(rec.message_id) or not util.is_nonempty_id(rec.channel_id) then return end
  if is_inline_dismissed(rec) then return end
  local mid = rec.message_id

  local hist = {}
  if type(rec.edit_history) == "table" and #rec.edit_history > 0 then
    hist = rec.edit_history
  elseif type(rec.previous_content) == "string" then
    hist = { { content = rec.previous_content, timestamp_ms = rec.created_at_ms or rec.logged_at_ms or 0 } }
  end
  if #hist == 0 then return end

  if not active_edit_acc[mid] then
    while #edit_decor_order >= MAX_EDIT_DECORATORS do
      local oldest = table.remove(edit_decor_order, 1)
      clear_edit_decor_for(oldest)
    end
    edit_decor_order[#edit_decor_order + 1] = mid
  end

  local style = config.get("edited_style")
  local accent = util.safe_hex(config.get("edited_color"), "#d99b26")
  local start_i = math.max(1, #hist - MAX_INLINE_EDIT_VERSIONS + 1)

  local rows = {}
  for i = start_i, #hist do
    local entry = hist[i]
    local txt = tostring(entry.content or "")
    if txt == "" then txt = "_(empty)_" end
    txt = util.truncate(txt, 1200)
    local v_label = "v" .. tostring(i)
    local tip = (i == 1 and "Original (v1)" or ("Version " .. tostring(i)))
      .. " · " .. util.format_timestamp_full(entry.timestamp_ms or rec.created_at_ms or rec.logged_at_ms)

    local row_children = {
      {
        type = "box",
        pad_top = 3,
        children = {
          {
            type = "text",
            text = v_label,
            size = 11,
            color = "text_muted",
            hover_color = "text_secondary",
            opacity = 0.70,
            ellipsis = false,
            tooltip = tip,
          },
        },
      },
      {
        type = "markdown",
        text = txt,
        size = "base",
        color = "text_muted",
        hover_color = "text_muted",
        opacity = 0.82,
        max_lines = 4,
        flex = 1,
      },
    }

    if i == start_i then
      row_children[#row_children + 1] = {
        id = "dismiss",
        type = "button",
        icon = "close",
        variant = "ghost",
        size = "xs",
        opacity = 0.38,
        tooltip = "Hide former version(s) for this message",
      }
    end

    rows[#rows + 1] = {
      type = "row",
      gap = 8,
      align = "start",
      children = row_children,
    }

    -- Subtle native separator line underneath each former version
    rows[#rows + 1] = {
      type = "divider",
      orientation = "horizontal",
      thickness = 1,
      color = "divider",
    }
  end

  local root
  if style == "quote" then
    root = {
      id = "edit_box",
      type = "col",
      gap = 4,
      pad_left = 8,
      pad_top = 1,
      pad_bottom = 2,
      border_color = util.hex_tint(accent, 0.45),
      border_w = 2,
      border_sides = "left",
      children = rows,
    }
  else
    -- Default "inline": flush native muted text separated by subtle horizontal lines + small version tag
    root = {
      id = "edit_box",
      type = "col",
      gap = 4,
      pad_bottom = 2,
      children = rows,
    }
  end

  local decor_id = make_edit_decor_id(mid)
  local ok, err = pcall(ui.decorate.message_accessory, {
    id = decor_id,
    message_id = mid,
    position = "above_body",
    priority = 10,
    root = root,
    on_event = function(ev)
      if type(ev) ~= "table" then return end
      if ev.type == "click" and ev.id == "dismiss" then
        inline_hidden_uids[rec.uid] = true
        rec.dismissed_inline = true
        clear_edit_decor_for(mid)
        persistence.mark_updated(rec)
      elseif ev.type == "right_click" and on_open_log_cb then
        pcall(on_open_log_cb, rec.channel_id, "edited", rec.uid)
      end
    end,
  })
  if ok then
    active_edit_acc[mid] = {
      id = decor_id,
      uid = rec.uid,
      channel_id = rec.channel_id,
      message_id = mid,
    }
  else
    util.safe_log("warn", "Failed applying above_body edit accessory for msg " .. tostring(mid) .. ": " .. tostring(err))
  end
end

function M.restore_inline_record(rec)
  if type(rec) ~= "table" or not rec.uid then return false end
  inline_hidden_uids[rec.uid] = nil
  if rec.dismissed_inline then
    rec.dismissed_inline = nil
    persistence.mark_updated(rec)
  end
  if rec.kind == "deleted" then
    return M.render_timeline_deleted(rec)
  elseif rec.kind == "edited" then
    apply_edit_decorators(rec)
    return true
  end
  return false
end

function M.remove_inline_deleted(rec)
  if type(rec) ~= "table" then return end
  local sid = make_stable_id(rec)
  local info = active_timeline_msgs[sid]
  if info then
    if messages and messages.dismiss_local then
      pcall(messages.dismiss_local, sid)
      if info.history_id then
        pcall(messages.dismiss_local, info.history_id)
      end
    end
    active_timeline_msgs[sid] = nil
  end
  if util.is_nonempty_id(rec.message_id) then
    clear_edit_decor_for(rec.message_id)
  end
end

function M.clear_inline_deleted_channel(channel_id)
  if not util.is_nonempty_id(channel_id) then return end
  if messages and messages.clear_local then
    pcall(messages.clear_local, channel_id)
  end
  for sid, info in pairs(active_timeline_msgs) do
    if info.channel_id == channel_id then
      active_timeline_msgs[sid] = nil
    end
  end
  local to_clear = {}
  for mid, info in pairs(active_edit_acc) do
    if info.channel_id == channel_id then
      to_clear[#to_clear + 1] = mid
    end
  end
  for i = 1, #to_clear do
    clear_edit_decor_for(to_clear[i])
  end
end

function M.clear_all_inline_deleted()
  if messages and messages.clear_local then
    pcall(messages.clear_local)
  end
  active_timeline_msgs = {}
  M.clear_all_edit_decorators()
end

function M.restore_inline_deleted_for_channel(channel_id)
  if not util.is_nonempty_id(channel_id) then return end
  local show_del = config.get("show_inline_deleted") == true
  local show_ed = config.get("decorate_edited") == true
  if not show_del and not show_ed then return end
  local all_recs = persistence.all_records()
  for i = 1, #all_recs do
    local r = all_recs[i]
    if r.channel_id == channel_id and not is_inline_dismissed(r) then
      if show_del and r.kind == "deleted" then
        M.render_timeline_deleted(r)
      elseif show_ed and r.kind == "edited" then
        apply_edit_decorators(r)
      end
    end
  end
end

function M.refresh_all_inline_deleted()
  if not config.get("show_inline_deleted") then
    if messages and messages.dismiss_local then
      for sid, info in pairs(active_timeline_msgs) do
        pcall(messages.dismiss_local, sid)
        if info and info.history_id then
          pcall(messages.dismiss_local, info.history_id)
        end
      end
    end
    active_timeline_msgs = {}
    return
  end
  local active_copy = {}
  for sid, info in pairs(active_timeline_msgs) do
    active_copy[sid] = info
  end
  for sid, info in pairs(active_copy) do
    local rec = persistence.find_by_uid(info.uid)
    if rec and rec.kind == "deleted" and not is_inline_dismissed(rec) then
      M.render_timeline_deleted(rec)
    else
      if messages and messages.dismiss_local then
        pcall(messages.dismiss_local, sid)
        if info and info.history_id then
          pcall(messages.dismiss_local, info.history_id)
        end
      end
      active_timeline_msgs[sid] = nil
    end
  end
end

function M.refresh_all_inline_edits()
  if not config.get("decorate_edited") then
    M.clear_all_edit_decorators()
    return
  end
  local active_copy = {}
  for mid, info in pairs(active_edit_acc) do
    active_copy[mid] = info
  end
  for mid, info in pairs(active_copy) do
    local rec = persistence.find_by_uid(info.uid)
    if rec and rec.kind == "edited" and not is_inline_dismissed(rec) then
      apply_edit_decorators(rec)
    else
      clear_edit_decor_for(mid)
    end
  end
end

-- ---- Channel History Seeding (Driven by channel.select & messages.loaded — Zero Polling!) ----

function M.seed_channel(channel_id, fallback_guild_id)
  if not util.is_nonempty_id(channel_id) then return 0 end
  M.restore_inline_deleted_for_channel(channel_id)

  if not (store and store.messages) then return 0 end
  local monitored, reason = whitelist.is_monitored(fallback_guild_id, channel_id)
  if not monitored then return 0 end

  local cap = math.max(50, math.floor(tonumber(config.get("cache_per_channel")) or 200))
  local ok, msgs = pcall(store.messages, channel_id, cap)
  if not ok or type(msgs) ~= "table" then return 0 end

  local meta = whitelist.resolve_channel_meta(channel_id, fallback_guild_id)
  local precache_budget = (reason == "active") and 3 or MAX_SEED_PRECACHE
  local count = 0
  for i = #msgs, 1, -1 do
    local snap = snapshot_from_msg(msgs[i], meta.guild_id)
    if snap then
      local allow_pre = false
      if precache_budget > 0 and #snap.attachments > 0 then
        allow_pre = true
        precache_budget = precache_budget - 1
      end
      cache_snapshot(snap, allow_pre)
      count = count + 1
    end
  end
  return count
end

function M.seed_guild(guild_id)
  if not util.is_nonempty_id(guild_id) or not (store and store.channels) then return 0 end
  local ok, chans = pcall(store.channels, guild_id)
  if not ok or type(chans) ~= "table" then return 0 end
  local total = 0
  for i = 1, #chans do
    local ch = chans[i]
    if type(ch) == "table" and util.is_nonempty_id(ch.id) and ch.kind ~= "category" then
      total = total + M.seed_channel(ch.id, guild_id)
    end
  end
  return total
end

function M.seed_category(category_id, guild_id)
  if not util.is_nonempty_id(category_id) or not util.is_nonempty_id(guild_id) then return 0 end
  if not (store and store.channels) then return 0 end
  local ok, chans = pcall(store.channels, guild_id)
  if not ok or type(chans) ~= "table" then return 0 end
  local total = 0
  for i = 1, #chans do
    local ch = chans[i]
    if type(ch) == "table" and ch.parent_id == category_id and util.is_nonempty_id(ch.id) then
      total = total + M.seed_channel(ch.id, guild_id)
    end
  end
  return total
end

-- ---- Event Handlers (Class 2 events.messages — Zero gateway.raw Required!) ----

local function mark_delete_processed(channel_id, message_id)
  local k = tostring(channel_id) .. ":" .. tostring(message_id)
  if processed_deletes[k] then return false end
  processed_deletes[k] = true
  processed_deletes_order[#processed_deletes_order + 1] = k
  while #processed_deletes_order > MAX_PROCESSED_DELETES do
    local old = table.remove(processed_deletes_order, 1)
    processed_deletes[old] = nil
  end
  return true
end

function M.handle_messages_loaded(ev)
  if type(ev) ~= "table" or not util.is_nonempty_id(ev.channel_id) then return end
  M.seed_channel(ev.channel_id, ev.guild_id)
end

function M.handle_message_create(ev)
  if type(ev) ~= "table" or not util.is_valid_snowflake(ev.id) then return end
  if not util.is_nonempty_id(ev.channel_id) then return end
  if not whitelist.is_monitored(ev.guild_id, ev.channel_id) then return end

  local snap = snapshot_from_msg(ev, ev.guild_id)
  if snap then
    cache_snapshot(snap, true)
  end
end

function M.handle_message_update(ev)
  if type(ev) ~= "table" then return end
  local channel_id = ev.channel_id
  local message_id = ev.id
  local new_content = ev.content
  if not util.is_nonempty_id(channel_id) or not util.is_valid_snowflake(message_id) then return end
  if type(new_content) ~= "string" then return end
  if not whitelist.is_monitored(ev.guild_id, channel_id) then return end

  local b = channel_cache[channel_id]
  local snap = b and b.map[message_id]
  if not snap then
    local fresh = snapshot_from_msg(ev, ev.guild_id)
    if fresh then cache_snapshot(fresh, false) end
    return
  end

  local prev_content = tostring(snap.content or "")
  if ev.author_bot ~= nil then snap.author_bot = (ev.author_bot == true) end
  if util.is_nonempty_id(ev.author_id) then snap.author_id = ev.author_id end
  if type(ev.author_name) == "string" and ev.author_name ~= "" then snap.author_name = ev.author_name end
  if type(ev.attachments) == "table" and #ev.attachments > 0 then
    snap.attachments = normalize_attachments(ev.attachments)
  end

  if prev_content == new_content then return end

  local now_ms = tonumber(ev.edited_ms) or (time and time.now_ms() or 0)
  snap.content = new_content

  if not config.get("log_edited") then return end
  if not passes_author_filters(snap.author_id, snap.author_bot) then return end

  local meta = whitelist.resolve_channel_meta(channel_id, ev.guild_id or snap.guild_id)
  local existing = persistence.find_by_message(channel_id, message_id)
  if existing then
    if type(existing.edit_history) ~= "table" then existing.edit_history = {} end
    local last = existing.edit_history[#existing.edit_history]
    if not last or last.content ~= prev_content then
      existing.edit_history[#existing.edit_history + 1] = {
        content = prev_content,
        timestamp_ms = existing.logged_at_ms or existing.created_at_ms or now_ms,
      }
    end
    existing.previous_content = prev_content
    existing.content = new_content
    existing.logged_at_ms = now_ms
    existing.attachments = snap.attachments
    existing.dismissed_inline = nil
    inline_hidden_uids[existing.uid] = nil
    persistence.upsert_record(existing)
    apply_edit_decorators(existing)
  else
    local rec = {
      kind = "edited",
      message_id = message_id,
      channel_id = channel_id,
      guild_id = meta.guild_id,
      channel_name = meta.name,
      guild_name = meta.guild_name,
      is_dm = meta.is_dm,
      author_id = snap.author_id,
      author_name = snap.author_name,
      content = new_content,
      previous_content = prev_content,
      edit_history = {
        { content = prev_content, timestamp_ms = snap.timestamp_ms or now_ms },
      },
      created_at_ms = snap.timestamp_ms or now_ms,
      logged_at_ms = now_ms,
      bulk_deleted = false,
      attachments = snap.attachments or {},
      embeds = snap.embeds or {},
    }
    persistence.upsert_record(rec)
    apply_edit_decorators(rec)
  end
end

function M.handle_delete(guild_id, channel_id, message_id, is_bulk)
  if not util.is_nonempty_id(channel_id) or not util.is_nonempty_id(message_id) then return end
  if not mark_delete_processed(channel_id, message_id) then return end

  local monitored, mon_reason = whitelist.is_monitored(guild_id, channel_id)
  local b = channel_cache[channel_id]
  local snap = b and b.map[message_id]
  if b and b.map[message_id] then
    b.map[message_id] = nil
  end
  precached_msgs[channel_id .. ":" .. message_id] = nil

  if not monitored or not config.get("log_deleted") then
    util.safe_log("debug", string.format("Skipped delete msg=%s ch=%s (monitored=%s reason=%s)",
      tostring(message_id), tostring(channel_id), tostring(monitored), tostring(mon_reason)))
    return
  end

  -- Last-chance lookup in C-Cord store if not in our rolling cache
  if not snap and store and store.message then
    local ok, sm = pcall(store.message, channel_id, message_id)
    if ok and type(sm) == "table" then
      snap = snapshot_from_msg(sm, guild_id)
    end
  end

  local existing = persistence.find_by_message(channel_id, message_id)
  if not snap and not existing then
    if not config.get("log_uncached_deletes") then
      util.safe_log("debug", string.format("Skipped uncached delete msg=%s ch=%s (reason=%s)",
        tostring(message_id), tostring(channel_id), tostring(mon_reason)))
      return
    end
    snap = {
      id = message_id,
      channel_id = channel_id,
      guild_id = tostring(guild_id or ""),
      author_id = "",
      author_name = "Unknown (uncached)",
      author_bot = false,
      content = "_(Message was deleted before entering cache)_",
      timestamp_ms = time and time.now_ms() or 0,
      attachments = {},
      embeds = {},
    }
  end

  if snap and not passes_author_filters(snap.author_id, snap.author_bot) then
    return
  end

  clear_edit_decor_for(message_id)

  local now_ms = time and time.now_ms() or 0
  local meta = whitelist.resolve_channel_meta(channel_id, guild_id or (snap and snap.guild_id))
  local rec = nil

  if existing then
    existing.kind = "deleted"
    existing.logged_at_ms = now_ms
    existing.bulk_deleted = is_bulk == true
    existing.dismissed_inline = nil
    inline_hidden_uids[existing.uid] = nil
    if snap then
      if (existing.content == nil or existing.content == "") and snap.content and snap.content ~= "" then
        existing.content = snap.content
      end
      if type(snap.attachments) == "table" and #snap.attachments > 0 and (#(existing.attachments or {}) == 0) then
        existing.attachments = snap.attachments
      end
      if type(snap.embeds) == "table" and #snap.embeds > 0 and (#(existing.embeds or {}) == 0) then
        existing.embeds = snap.embeds
      end
    end
    rec = persistence.upsert_record(existing)
  else
    rec = persistence.upsert_record({
      kind = "deleted",
      message_id = message_id,
      channel_id = channel_id,
      guild_id = meta.guild_id,
      channel_name = meta.name,
      guild_name = meta.guild_name,
      is_dm = meta.is_dm,
      author_id = snap.author_id or "",
      author_name = snap.author_name or "Unknown",
      content = snap.content or "",
      edit_history = {},
      created_at_ms = snap.timestamp_ms or now_ms,
      logged_at_ms = now_ms,
      bulk_deleted = is_bulk == true,
      attachments = snap.attachments or {},
      embeds = snap.embeds or {},
    })
  end

  if not rec then return end

  -- Render native positioned timeline message immediately (red text/name + grayscale avatar)
  M.render_timeline_deleted(rec)

  -- Kick off cross-platform media archiving; updates timeline attachments in-place once saved
  if type(rec.attachments) == "table" and #rec.attachments > 0 and config.get("save_media") then
    media.archive_for_record(rec, function(updated_rec)
      M.update_timeline_deleted_attachments(updated_rec)
    end)
  end

  if config.get("toast_on_delete") and ui and ui.toast and ui.toast.show then
    local loc = rec.is_dm and ("DM " .. rec.channel_name) or ("#" .. rec.channel_name)
    local snippet = util.truncate(rec.content ~= "" and rec.content or "[attachment]", 60)
    pcall(ui.toast.show, string.format("Deleted in %s by %s: %s", loc, rec.author_name, snippet), "warn", {
      duration_ms = 6000,
      action_label = "Jump",
      on_action = function()
        if navigation and navigation.jump_to_message and util.is_valid_snowflake(rec.message_id) then
          pcall(navigation.jump_to_message, rec.channel_id, rec.message_id)
        elseif on_open_log_cb then
          pcall(on_open_log_cb, rec.channel_id, "deleted", rec.uid)
        end
      end,
    })
  end
end

function M.handle_message_delete(ev)
  if type(ev) ~= "table" then return end
  M.handle_delete(ev.guild_id, ev.channel_id, ev.message_id, false)
end

function M.handle_message_delete_bulk(ev)
  if type(ev) ~= "table" or type(ev.message_ids) ~= "table" then return end
  for i = 1, #ev.message_ids do
    M.handle_delete(ev.guild_id, ev.channel_id, tostring(ev.message_ids[i]), true)
  end
end

-- Manual right-click action: archive media from an existing live message right now
function M.archive_existing_message(guild_id, channel_id, message_id)
  if not util.is_nonempty_id(channel_id) or not util.is_nonempty_id(message_id) then
    return false, "Invalid message target"
  end
  local b = channel_cache[channel_id]
  local snap = b and b.map[message_id]
  if not snap and store and store.message then
    local ok, sm = pcall(store.message, channel_id, message_id)
    if ok and type(sm) == "table" then
      snap = snapshot_from_msg(sm, guild_id)
    end
  end
  if not snap or type(snap.attachments) ~= "table" or #snap.attachments == 0 then
    return false, "No downloadable attachments found on this message"
  end

  local meta = whitelist.resolve_channel_meta(channel_id, guild_id or snap.guild_id)
  local now_ms = time and time.now_ms() or 0
  local rec = persistence.find_by_message(channel_id, message_id)
  if not rec then
    rec = persistence.upsert_record({
      kind = "archived",
      message_id = message_id,
      channel_id = channel_id,
      guild_id = meta.guild_id,
      channel_name = meta.name,
      guild_name = meta.guild_name,
      is_dm = meta.is_dm,
      author_id = snap.author_id or "",
      author_name = snap.author_name or "Unknown",
      content = snap.content or "",
      edit_history = {},
      created_at_ms = snap.timestamp_ms or now_ms,
      logged_at_ms = now_ms,
      bulk_deleted = false,
      attachments = snap.attachments,
      embeds = snap.embeds or {},
    })
  end
  media.archive_for_record(rec)
  return true, string.format("Archiving %d attachment(s)...", #snap.attachments)
end

function M.cached_count()
  local total = 0
  for _, b in pairs(channel_cache) do
    total = total + #b.order
  end
  return total
end

return M
