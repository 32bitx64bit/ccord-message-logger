-- Native C-Cord Panel Engine UI: right-sidebar drawer, full-view workspace tab, and header button.

local util = require("src.util")
local config = require("src.config")
local whitelist = require("src.whitelist")
local persistence = require("src.persistence")
local media = require("src.media")
local capture = require("src.capture")

local M = {}

local DRAWER_ID = "msglog-drawer"
local FULLVIEW_ID = "msglog-fullview"
local HEADER_BTN_ID = "msglog-header-btn"
local PAGE_SIZE = 15

local ui_state = {
  drawer_open = false,
  drawer_mounted = false,
  fullview_mounted = false,
  header_btn_mounted = false,
  tab = "logs",       -- "logs" | "media" | "whitelist"
  scope = "channel",  -- "channel" | "guild" | "all"
  filter = "all",     -- "all" | "deleted" | "edited" | "media"
  query = "",
  page = 1,
  target_channel_id = nil,
  target_guild_id = nil,
}

local redraw_timer = nil

local function get_selected_context()
  local cid, gid = ui_state.target_channel_id, ui_state.target_guild_id
  if store and store.selected then
    local ok, sel = pcall(store.selected)
    if ok and type(sel) == "table" then
      if not util.is_nonempty_id(cid) and util.is_nonempty_id(sel.channel_id) then
        cid = sel.channel_id
      end
      if not util.is_nonempty_id(gid) and util.is_nonempty_id(sel.guild_id) then
        gid = sel.guild_id
      end
    end
  end
  return cid, gid
end

local function live_selected_context()
  if store and store.selected then
    local ok, sel = pcall(store.selected)
    if ok and type(sel) == "table" then
      return sel.channel_id, sel.guild_id, sel.is_dm == true
    end
  end
  return nil, nil, false
end

local function jump_to_record(rec)
  if type(rec) ~= "table" or not util.is_nonempty_id(rec.channel_id) then return end
  if navigation and navigation.jump_to_message and util.is_valid_snowflake(rec.message_id) then
    pcall(navigation.jump_to_message, rec.channel_id, rec.message_id)
  elseif navigation and navigation.select_channel then
    pcall(navigation.select_channel, rec.channel_id, {
      guild_id = (not rec.is_dm and util.is_nonempty_id(rec.guild_id)) and rec.guild_id or nil,
    })
  end
end

local function open_attachment_lightbox(rec, target_idx)
  if not (ui and ui.media and ui.media.open) then return end
  if type(rec) ~= "table" or type(rec.attachments) ~= "table" then return end

  local items = {}
  local selected_idx = 1
  for i = 1, #rec.attachments do
    if #items >= 10 then break end
    local a = rec.attachments[i]
    local k = a and (a.media_kind or util.classify_attachment(a)) or "other"
    if a and (k == "image" or k == "video") then
      local entry = nil
      if a.saved and a.storage == "disk" then
        local uri = a.local_path or util.plugin_data_uri(a.rel_path)
        if uri then
          entry = { local_path = uri, filename = a.filename, kind = k }
        end
      elseif a.saved and a.storage == "memory" and k == "image" then
        local tex = media.ensure_preview_texture(a)
        if tex then
          entry = { texture_key = tex, filename = a.filename, kind = "image" }
        end
      elseif util.is_safe_https_url(a.url) then
        entry = { url = a.url, filename = a.filename, kind = k }
      end
      if entry then
        items[#items + 1] = entry
        if i == target_idx then
          selected_idx = #items
        end
      end
    end
  end

  if #items == 0 then
    if ui and ui.toast then pcall(ui.toast.show, "Media preview unavailable — try Save As", "warn") end
    return
  end

  if #items == 1 then
    pcall(ui.media.open, items[1])
  else
    pcall(ui.media.open, { items = items, index = selected_idx })
  end
end

local function build_attachment_node(rec, att, idx, compact)
  local kind = att.media_kind or util.classify_attachment(att)
  local kind_label = string.upper(kind)
  local kind_bg = (kind == "video") and "#6e7bf233" or ((kind == "image") and "#12d6c133" or "bg_tertiary")
  local kind_fg = (kind == "video") and "#82aaff" or ((kind == "image") and "#12d6c1" or "text_secondary")

  local status_text
  local status_color = "text_muted"
  if att.saved then
    status_text = (att.storage == "disk") and "Saved on disk" or "Saved in memory"
    status_color = "status_online"
  elseif att.status == "archiving" then
    status_text = "Archiving..."
    status_color = "status_idle"
  elseif att.save_error and att.save_error ~= "" then
    status_text = att.save_error
    status_color = "danger"
  else
    status_text = "Not archived"
  end

  local children = {}

  -- Inline clickable GPU thumbnail preview (Disk: host-side up to 32 MiB PNG/JPG/WebP/GIF; Memory: <= 640 KiB)
  if att.saved and kind == "image" then
    local tex = media.ensure_preview_texture(att)
    if tex then
      children[#children + 1] = {
        id = "view_att:" .. rec.uid .. ":" .. idx,
        type = "image",
        texture = tex,
        w = compact and 260 or 380,
        h = compact and 140 or 210,
        radius = 6,
        fit = "cover",
        cursor = "pointer",
        tooltip = "Click to open in media viewer",
      }
    end
  end

  children[#children + 1] = {
    type = "row",
    gap = 6,
    align = "center",
    children = {
      { type = "icon", name = (kind == "video" and "camera" or (kind == "image" and "attachment" or "file")), size = 14, color = kind_fg },
      { type = "badge", label = kind_label, bg = kind_bg, text_color = kind_fg },
      { type = "text", text = util.truncate(att.filename or "file", compact and 26 or 48), size = "small", bold = true, color = "text_normal", flex = 1 },
      { type = "text", text = util.format_bytes(att.saved_bytes or att.size or 0), size = "small", color = "text_muted" },
    },
  }

  local action_children = {
    { type = "text", text = util.truncate(status_text, compact and 24 or 56), size = "small", color = status_color, flex = 1 },
  }

  local can_lightbox = att.saved and ((kind == "image") or (kind == "video" and att.storage == "disk"))
  if can_lightbox and ui and ui.media and ui.media.open then
    action_children[#action_children + 1] = {
      id = "view_att:" .. rec.uid .. ":" .. idx,
      type = "button",
      label = "View",
      variant = "secondary",
      size = "xs",
      tooltip = "Open in C-Cord media lightbox",
    }
  end

  if att.saved then
    action_children[#action_children + 1] = {
      id = "save_att:" .. rec.uid .. ":" .. idx,
      type = "button",
      label = "Save As",
      variant = "ghost",
      size = "xs",
    }
  elseif util.is_safe_https_url(att.url) then
    action_children[#action_children + 1] = {
      id = "retry_att:" .. rec.uid .. ":" .. idx,
      type = "button",
      label = "Retry",
      variant = "secondary",
      size = "xs",
    }
    action_children[#action_children + 1] = {
      id = "copyurl_att:" .. rec.uid .. ":" .. idx,
      type = "button",
      label = "URL",
      variant = "ghost",
      size = "xs",
    }
  end

  children[#children + 1] = {
    type = "row",
    gap = 4,
    align = "center",
    children = action_children,
  }

  return {
    type = "col",
    gap = 6,
    padding = { 6, 8 },
    bg = "bg_tertiary",
    border_color = "border_subtle",
    border_w = 1,
    radius = 6,
    children = children,
  }
end

local function build_record_card(rec, compact)
  local del_col = util.safe_hex(config.get("deleted_color"), "#e5484d")
  local ed_col = util.safe_hex(config.get("edited_color"), "#d99b26")
  local now_ms = time and time.now_ms() or 0

  local badge_label, badge_color
  if rec.kind == "deleted" then
    badge_label = rec.bulk_deleted and "BULK DELETED" or "DELETED"
    badge_color = del_col
  elseif rec.kind == "edited" then
    badge_label = "EDITED"
    badge_color = ed_col
  else
    badge_label = "ARCHIVED"
    badge_color = "#3b82f6"
  end

  local loc = rec.is_dm and ("DM " .. tostring(rec.channel_name or "")) or
    (tostring(rec.guild_name or "") .. " / #" .. tostring(rec.channel_name or ""))

  local is_deleted = (rec.kind == "deleted")
  local av_opacity = math.max(20, math.min(100, tonumber(config.get("deleted_avatar_opacity")) or 55)) / 100.0
  local has_author = util.is_nonempty_id(rec.author_id)

  local author_children = {}
  if has_author then
    author_children[#author_children + 1] = {
      type = "avatar",
      user_id = rec.author_id,
      size = 24,
      grayscale = is_deleted,
      opacity = is_deleted and av_opacity or 1.0,
    }
  end
  author_children[#author_children + 1] = {
    type = "text",
    text = tostring(rec.author_name or "Unknown"),
    size = "small",
    bold = true,
    color = is_deleted and del_col or "text_header",
    flex = 1,
  }

  local header_children = {
    {
      id = has_author and ("profile_rec:" .. rec.uid) or nil,
      type = "row",
      gap = 6,
      align = "center",
      flex = 1,
      cursor = has_author and "pointer" or nil,
      tooltip = has_author and "Click to view user profile" or nil,
      children = author_children,
    },
    {
      type = "badge",
      label = badge_label,
      bg = util.hex_tint(badge_color, 0.22),
      text_color = badge_color,
    },
  }

  local card_children = {
    {
      type = "row",
      gap = 6,
      align = "center",
      children = header_children,
    },
    {
      type = "row",
      gap = 6,
      align = "center",
      children = {
        { type = "text", text = util.truncate(loc, compact and 28 or 60), size = "small", color = "text_muted", flex = 1 },
        {
          type = "text",
          text = util.format_relative(rec.logged_at_ms or rec.created_at_ms, now_ms),
          size = "small",
          color = "text_muted",
          tooltip = util.format_timestamp_full(rec.logged_at_ms or rec.created_at_ms),
        },
      },
    },
  }

  -- Message content (clamped with max_lines for clean card heights)
  if type(rec.content) == "string" and rec.content ~= "" then
    card_children[#card_children + 1] = {
      type = "markdown",
      text = util.truncate(rec.content, compact and 800 or 1600),
      size = "small",
      color = is_deleted and del_col or "text_normal",
      max_lines = compact and 6 or 12,
    }
  elseif type(rec.attachments) ~= "table" or #rec.attachments == 0 then
    card_children[#card_children + 1] = {
      type = "text",
      text = "(empty message)",
      size = "small",
      color = "text_muted",
    }
  end

  -- Edit history versions
  if type(rec.edit_history) == "table" and #rec.edit_history > 0 then
    local hist_children = {
      { type = "text", text = "Previous version(s):", size = "small", bold = true, color = ed_col },
    }
    local max_show = math.min(#rec.edit_history, 5)
    local start_idx = #rec.edit_history - max_show + 1
    for j = start_idx, #rec.edit_history do
      local h = rec.edit_history[j]
      hist_children[#hist_children + 1] = {
        type = "markdown",
        text = string.format("`v%d` (%s): %s",
          j,
          util.format_timestamp(h.timestamp_ms),
          util.truncate(tostring(h.content or "(empty)"), compact and 240 or 500)),
        size = "small",
        color = "text_secondary",
        max_lines = 4,
      }
    end
    card_children[#card_children + 1] = {
      type = "col",
      gap = 3,
      padding = { 5, 8 },
      bg = "bg_tertiary",
      radius = 5,
      children = hist_children,
    }
  end

  -- Attachments (images, videos, other)
  if type(rec.attachments) == "table" and #rec.attachments > 0 then
    for i = 1, #rec.attachments do
      card_children[#card_children + 1] = build_attachment_node(rec, rec.attachments[i], i, compact)
    end
  end

  -- Card footer row
  local footer_children = {
    {
      type = "text",
      text = util.format_timestamp(rec.created_at_ms or rec.logged_at_ms),
      size = "small",
      color = "text_muted",
      flex = 1,
      tooltip = util.format_timestamp_full(rec.created_at_ms or rec.logged_at_ms),
    },
  }
  if rec.dismissed_inline and (rec.kind == "deleted" or rec.kind == "edited") then
    footer_children[#footer_children + 1] = {
      id = "show_rec:" .. rec.uid,
      type = "button",
      label = "Show",
      variant = "ghost",
      size = "xs",
      tooltip = "Restore this entry inline in chat",
    }
  end
  if util.is_nonempty_id(rec.channel_id) then
    footer_children[#footer_children + 1] = {
      id = "jump_rec:" .. rec.uid,
      type = "button",
      label = "Jump",
      variant = "ghost",
      size = "xs",
      tooltip = "Jump to message in chat",
    }
  end
  footer_children[#footer_children + 1] = { id = "copy_rec:" .. rec.uid, type = "button", label = "Copy", variant = "ghost", size = "xs" }
  footer_children[#footer_children + 1] = { id = "del_rec:" .. rec.uid, type = "button", label = "Remove", variant = "ghost", size = "xs" }

  card_children[#card_children + 1] = {
    type = "row",
    gap = 4,
    align = "center",
    children = footer_children,
  }

  return {
    id = "card:" .. rec.uid,
    type = "col",
    gap = 6,
    padding = { 8, 10 },
    bg = "bg_secondary",
    border_color = util.hex_tint(badge_color, 0.45),
    border_w = 1,
    radius = 8,
    children = card_children,
  }
end

local function build_whitelist_section(title, scope_key, bucket, icon_name)
  local rows = {}
  local ids = {}
  for id in pairs(bucket) do
    ids[#ids + 1] = id
  end
  table.sort(ids, function(a, b)
    return tostring(bucket[a].name or a) < tostring(bucket[b].name or b)
  end)

  if #ids == 0 then
    return {
      type = "col",
      gap = 4,
      padding = { 6, 8 },
      bg = "bg_secondary",
      radius = 6,
      children = {
        { type = "text", text = title .. " (0)", size = "small", bold = true, color = "text_secondary" },
        { type = "text", text = "None — right-click a channel, DM, or server to add.", size = "small", color = "text_muted" },
      },
    }
  end

  rows[#rows + 1] = {
    type = "text",
    text = string.format("%s (%d)", title, #ids),
    size = "small",
    bold = true,
    color = "text_header",
  }

  for i = 1, #ids do
    local id = ids[i]
    local item = bucket[id]
    local label = tostring(item.name or id)
    if scope_key == "channels" and not item.is_dm and label:sub(1, 1) ~= "#" then
      label = "#" .. label
    elseif scope_key == "channels" and item.is_dm then
      label = "DM: " .. label
    end
    local sub = (item.guild_name and item.guild_name ~= "" and not item.is_dm and scope_key ~= "guilds")
      and (" (" .. item.guild_name .. ")") or ""

    rows[#rows + 1] = {
      type = "row",
      gap = 6,
      align = "center",
      padding = { 4, 6 },
      bg = "bg_tertiary",
      radius = 5,
      children = {
        { type = "icon", name = item.is_dm and "at" or icon_name, size = 14, color = "text_muted" },
        { type = "text", text = util.truncate(label .. sub, 38), size = "small", color = "text_normal", flex = 1 },
        { id = "wl_rm:" .. scope_key .. ":" .. id, type = "button", label = "Remove", variant = "danger", size = "xs" },
      },
    }
  end

  return {
    type = "col",
    gap = 5,
    padding = { 8, 8 },
    bg = "bg_secondary",
    border_color = "border_subtle",
    border_w = 1,
    radius = 8,
    children = rows,
  }
end

local function build_whitelist_tab()
  local wl = whitelist.get_all()
  local sel_cid, sel_gid, sel_is_dm = live_selected_context()
  local mode = config.get("monitor_mode")
  local is_mon = util.is_nonempty_id(sel_cid) and whitelist.is_monitored(sel_gid, sel_cid)

  local quick_children = {
    {
      type = "row",
      gap = 6,
      align = "center",
      children = {
        { type = "text", text = "Scope:", size = "small", bold = true, color = "text_secondary" },
        {
          id = "wl_mode_toggle",
          type = "button",
          label = mode == "whitelist" and "Whitelist Only" or "All Channels",
          variant = mode == "whitelist" and "primary" or "secondary",
          size = "xs",
        },
        { type = "spacer" },
        { id = "wl_clear_all", type = "button", label = "Clear List", variant = "danger", size = "xs" },
      },
    },
  }

  if util.is_nonempty_id(sel_cid) then
    local ch_meta = whitelist.resolve_channel_meta(sel_cid, sel_gid)
    local target_lbl = ch_meta.is_dm and ("DM " .. ch_meta.name) or ("#" .. ch_meta.name)
    local row_btns = {
      {
        id = "wl_toggle_cur_ch",
        type = "button",
        label = (whitelist.is_channel_whitelisted(sel_cid) and "Unwatch " or "Watch ") .. util.truncate(target_lbl, 16),
        variant = is_mon and "secondary" or "primary",
        size = "xs",
        flex = 1,
      },
    }
    if util.is_nonempty_id(sel_gid) and sel_gid ~= "dm" and not sel_is_dm then
      row_btns[#row_btns + 1] = {
        id = "wl_toggle_cur_guild",
        type = "button",
        label = whitelist.is_guild_whitelisted(sel_gid) and "Unwatch Server" or "Watch Server",
        variant = "secondary",
        size = "xs",
      }
    end
    quick_children[#quick_children + 1] = {
      type = "row",
      gap = 6,
      children = row_btns,
    }
  end

  return {
    type = "scroll",
    flex = 1,
    gap = 8,
    padding = { 2, 0 },
    children = {
      {
        type = "col",
        gap = 6,
        padding = { 8, 8 },
        bg = "bg_secondary",
        border_color = "border_subtle",
        border_w = 1,
        radius = 8,
        children = quick_children,
      },
      build_whitelist_section("Whitelisted Servers", "guilds", wl.guilds, "forum"),
      build_whitelist_section("Whitelisted Categories", "categories", wl.categories, "folder"),
      build_whitelist_section("Whitelisted Channels & DMs", "channels", wl.channels, "hash"),
      build_whitelist_section("Excluded Channels", "excluded_channels", wl.excluded_channels, "close"),
    },
  }
end

local function build_logs_scroll_section(compact)
  local cid, gid = get_selected_context()
  local eff_kind = (ui_state.tab == "media") and "media" or ui_state.filter
  local items = persistence.query({
    scope = ui_state.scope,
    channel_id = cid,
    guild_id = gid,
    kind = eff_kind,
    query = ui_state.query,
  })

  local total = #items
  local total_pages = math.max(1, math.ceil(total / PAGE_SIZE))
  if ui_state.page > total_pages then ui_state.page = total_pages end
  if ui_state.page < 1 then ui_state.page = 1 end

  local start_i = (ui_state.page - 1) * PAGE_SIZE + 1
  local end_i = math.min(total, start_i + PAGE_SIZE - 1)

  local list_children = {}
  if total == 0 then
    local empty_hint = "No logged messages match this filter yet."
    if ui_state.scope == "channel" and util.is_nonempty_id(cid) and not whitelist.is_monitored(gid, cid) then
      empty_hint = "This channel is not whitelisted. Right-click it (or click 'Watch' above) to start logging deleted & edited messages."
    elseif ui_state.tab == "media" then
      empty_hint = "No logged image/video attachments yet. Enable 'Store Deleted Media' in Settings -> Plugins -> Message Logger."
    end
    list_children[#list_children + 1] = {
      type = "col",
      gap = 6,
      padding = { 24, 14 },
      align = "center",
      children = {
        { type = "icon", name = "inbox", size = 28, color = "text_muted" },
        { type = "markdown", text = empty_hint, size = "small", color = "text_muted", align = "center" },
      },
    }
  else
    for i = start_i, end_i do
      list_children[#list_children + 1] = build_record_card(items[i], compact)
    end
    if total_pages > 1 then
      list_children[#list_children + 1] = {
        type = "row",
        gap = 8,
        align = "center",
        justify = "center",
        padding = { 4, 0 },
        children = {
          { id = "page_prev", type = "button", icon = "chevron_left", label = "Prev", variant = "secondary", size = "xs", disabled = (ui_state.page <= 1) },
          { type = "text", text = string.format("Page %d / %d (%d)", ui_state.page, total_pages, total), size = "small", color = "text_muted" },
          { id = "page_next", type = "button", icon = "chevron_right", label = "Next", variant = "secondary", size = "xs", disabled = (ui_state.page >= total_pages) },
        },
      }
    end
  end

  return {
    id = "logs_scroll_wrap",
    type = "scroll",
    flex = 1,
    gap = 8,
    children = list_children,
  }, total
end

local function build_logs_body(compact)
  local scroll_node, total = build_logs_scroll_section(compact)

  local controls = {
    {
      type = "row",
      gap = 6,
      align = "center",
      children = {
        {
          id = "search_input",
          type = "input",
          value = ui_state.query,
          placeholder = "Search text, author, channel, file...",
          flex = 1,
        },
        {
          id = "scope_select",
          type = "select",
          value = ui_state.scope,
          w = compact and 116 or 148,
          options = {
            { label = "This Channel", value = "channel" },
            { label = "This Server", value = "guild" },
            { label = "All Logged", value = "all" },
          },
        },
      },
    },
  }

  if ui_state.tab == "logs" then
    controls[#controls + 1] = {
      type = "row",
      gap = 4,
      align = "center",
      children = {
        { id = "flt_all", type = "button", label = "All", variant = ui_state.filter == "all" and "primary" or "ghost", size = "xs" },
        { id = "flt_deleted", type = "button", label = "Deleted", variant = ui_state.filter == "deleted" and "primary" or "ghost", size = "xs" },
        { id = "flt_edited", type = "button", label = "Edited", variant = ui_state.filter == "edited" and "primary" or "ghost", size = "xs" },
        { id = "flt_media", type = "button", label = "Media", variant = ui_state.filter == "media" and "primary" or "ghost", size = "xs" },
        { type = "spacer" },
        { id = "shown_count_lbl", type = "text", text = tostring(total) .. " shown", size = "small", color = "text_muted" },
      },
    }
  end

  return {
    type = "col",
    gap = 8,
    flex = 1,
    children = {
      { type = "col", gap = 6, children = controls },
      scroll_node,
    },
  }
end

local function build_root_tree(is_drawer)
  local st = persistence.stats()
  local is_disk = (st.mode == "disk")
  local sel_cid, sel_gid = live_selected_context()
  local cur_mon, cur_reason = false, "none"
  if util.is_nonempty_id(sel_cid) then
    cur_mon, cur_reason = whitelist.is_monitored(sel_gid, sel_cid)
  end
  local cur_wl = util.is_nonempty_id(sel_cid) and whitelist.is_explicitly_whitelisted(sel_gid, sel_cid)

  local top_row_children = {
    { type = "icon", name = "inbox", size = 16, color = "brand" },
    { type = "text", text = "Message Logger", size = "base", bold = true, color = "text_header", flex = 1 },
    {
      id = "mode_toggle",
      type = "button",
      label = is_disk and "DISK" or "RAM",
      variant = is_disk and "secondary" or "danger",
      size = "xs",
      tooltip = is_disk and "Persisting in sandboxed plugin storage (click for Memory-Only)" or "Memory-only mode: clears on restart (click for Disk)",
    },
  }

  if util.is_nonempty_id(sel_cid) then
    local wlabel = cur_wl and "Whitelisted" or (cur_reason == "active" and "Active · Pin" or "Watch")
    local wtip = cur_wl and "Channel is whitelisted for background monitoring (click to un-whitelist)"
      or (cur_reason == "active" and "Logging while actively viewing — click to whitelist for background monitoring"
      or "Click to whitelist this channel/DM")
    top_row_children[#top_row_children + 1] = {
      id = "quick_watch_cur",
      type = "button",
      label = wlabel,
      variant = cur_wl and "primary" or "secondary",
      size = "xs",
      tooltip = wtip,
    }
  end

  if is_drawer then
    top_row_children[#top_row_children + 1] = {
      id = "close_drawer",
      type = "button",
      icon = "close",
      variant = "ghost",
      size = "xs",
      tooltip = "Close Message Logger",
    }
  end

  local media_summary = is_disk
    and util.format_bytes(st.jail_used_bytes or st.disk_media_bytes)
    or (util.format_bytes(st.mem_media_bytes) .. " RAM")

  local footer_text = string.format("%s · %d logs · %d media (%s)",
    is_disk and "Disk" or "RAM", st.total, st.saved_media, media_summary)

  local body = (ui_state.tab == "whitelist") and build_whitelist_tab() or build_logs_body(is_drawer)

  return {
    type = "col",
    gap = 8,
    padding = { 10, 10 },
    bg = "bg_primary",
    flex = 1,
    children = {
      { type = "row", gap = 6, align = "center", children = top_row_children },
      {
        id = "main_tabs",
        type = "tabs",
        active = ui_state.tab,
        items = {
          { label = string.format("Logs (%d)", st.total), value = "logs" },
          { label = string.format("Media (%d)", st.saved_media), value = "media" },
          { label = "Whitelist", value = "whitelist" },
        },
      },
      { type = "divider" },
      body,
      { type = "divider" },
      {
        type = "row",
        gap = 6,
        align = "center",
        children = {
          { type = "text", text = util.truncate(footer_text, is_drawer and 24 or 56), size = "small", color = "text_muted", flex = 1, tooltip = footer_text },
          { id = "export_json", type = "button", label = "JSON", variant = "secondary", size = "xs", tooltip = "Export filtered logs as JSON" },
          { id = "export_md", type = "button", label = "MD", variant = "secondary", size = "xs", tooltip = "Export filtered logs as Markdown" },
          { id = "clear_scope", type = "button", label = "Clear", variant = "danger", size = "xs", tooltip = "Clear logs in current scope" },
        },
      },
    },
  }
end

local function handle_panel_event(ev)
  if type(ev) ~= "table" then return end
  local et = ev.type
  local id = tostring(ev.id or "")

  if et == "close" and ev.panel_id == DRAWER_ID then
    ui_state.drawer_open = false
    M.redraw_now()
    return
  end

  if et == "change" or et == "submit" then
    if id == "main_tabs" and type(ev.value) == "string" then
      ui_state.tab = ev.value
      ui_state.page = 1
      M.redraw_now()
      return
    elseif id == "search_input" and type(ev.value) == "string" then
      ui_state.query = ev.value
      ui_state.page = 1
      -- Use incremental ui.panel.patch so the focused search_input never loses caret/focus!
      if ui and ui.panel and ui.panel.patch and type(ev.panel_id) == "string" and ev.panel_id ~= "" then
        local is_drawer = (ev.panel_id == DRAWER_ID)
        local scroll_node, total = build_logs_scroll_section(is_drawer)
        local ops = {
          { op = "replace", id = "logs_scroll_wrap", node = scroll_node },
        }
        if ui_state.tab == "logs" then
          ops[#ops + 1] = { op = "set_text", id = "shown_count_lbl", value = tostring(total) .. " shown" }
        end
        pcall(ui.panel.patch, ev.panel_id, ops)
      else
        M.schedule_redraw(80)
      end
      return
    elseif id == "scope_select" and type(ev.value) == "string" then
      ui_state.scope = ev.value
      ui_state.target_channel_id = nil
      ui_state.target_guild_id = nil
      ui_state.page = 1
      M.redraw_now()
      return
    end
  end

  if et == "right_click" and id:sub(1, 5) == "card:" then
    local uid = id:sub(6)
    local rec = persistence.find_by_uid(uid)
    if rec and ui and ui.menu and ui.menu.popup then
      local items = {}
      if util.is_nonempty_id(rec.channel_id) then
        items[#items + 1] = { id = "jump", label = "Jump to Message" }
      end
      items[#items + 1] = { id = "copy", label = "Copy Message Text" }
      if util.is_nonempty_id(rec.author_id) and ui.open_user_profile then
        items[#items + 1] = { id = "profile", label = "Open User Profile" }
      end
      if rec.dismissed_inline and (rec.kind == "deleted" or rec.kind == "edited") then
        items[#items + 1] = { id = "show", label = "Restore Inline in Chat" }
      end
      items[#items + 1] = { id = "remove", label = "Remove from History", danger = true, divider_before = true }
      pcall(ui.menu.popup, {
        items = items,
        on_select = function(choice)
          if choice == "jump" then
            jump_to_record(rec)
          elseif choice == "copy" then
            local txt = rec.content or ""
            if txt == "" and type(rec.attachments) == "table" and #rec.attachments > 0 then
              txt = rec.attachments[1].url or rec.attachments[1].filename or ""
            end
            clipboard.write(txt)
            ui.toast.show("Copied logged message text", "info")
          elseif choice == "profile" and util.is_nonempty_id(rec.author_id) and ui.open_user_profile then
            pcall(ui.open_user_profile, rec.author_id, (not rec.is_dm and util.is_nonempty_id(rec.guild_id)) and rec.guild_id or nil)
          elseif choice == "show" then
            capture.restore_inline_record(rec)
            M.redraw_now()
          elseif choice == "remove" then
            if persistence.delete_record(uid) then
              capture.remove_inline_deleted(rec)
              M.redraw_now()
            end
          end
        end,
      })
    end
    return
  end

  if et ~= "click" then return end

  if id == "close_drawer" then
    ui_state.drawer_open = false
    M.redraw_now()
  elseif id == "mode_toggle" then
    local next_mode = config.is_disk_mode() and "memory" or "disk"
    config.set("storage_mode", next_mode)
    if ui and ui.toast and ui.toast.show then
      local msg = next_mode == "disk"
        and "Message Logger: Disk mode (sandboxed plugin storage)"
        or "Message Logger: Memory-only mode (clears on restart)"
      pcall(ui.toast.show, msg, "info")
    end
    M.redraw_now()
  elseif id == "quick_watch_cur" or id == "wl_toggle_cur_ch" then
    local cid, gid = live_selected_context()
    if util.is_nonempty_id(cid) then
      local added, msg = whitelist.toggle_channel(cid, gid)
      if added then capture.seed_channel(cid, gid) end
      if ui and ui.toast then pcall(ui.toast.show, msg, "info") end
      M.redraw_now()
    end
  elseif id == "wl_toggle_cur_guild" then
    local _, gid = live_selected_context()
    if util.is_nonempty_id(gid) then
      local added, msg = whitelist.toggle_guild(gid)
      if added then capture.seed_guild(gid) end
      if ui and ui.toast then pcall(ui.toast.show, msg, "info") end
      M.redraw_now()
    end
  elseif id == "wl_mode_toggle" then
    local next_m = (config.get("monitor_mode") == "whitelist") and "all" or "whitelist"
    config.set("monitor_mode", next_m)
    if ui and ui.toast then
      pcall(ui.toast.show, next_m == "whitelist" and "Monitoring mode: Whitelist only" or "Monitoring mode: All channels", "info")
    end
    M.redraw_now()
  elseif id == "wl_clear_all" then
    async.spawn(function()
      local res = ui.dialog.confirm({
        title = "Clear Message Logger Whitelist",
        message = "Remove all whitelisted servers, categories, channels, DMs, and exclusions?",
        confirm_label = "Clear Whitelist",
      })
      if res and res.accepted then
        whitelist.clear_all()
        ui.toast.show("Whitelist cleared", "info")
        M.redraw_now()
      end
    end)
  elseif id == "flt_all" then
    ui_state.filter = "all"; ui_state.page = 1; M.redraw_now()
  elseif id == "flt_deleted" then
    ui_state.filter = "deleted"; ui_state.page = 1; M.redraw_now()
  elseif id == "flt_edited" then
    ui_state.filter = "edited"; ui_state.page = 1; M.redraw_now()
  elseif id == "flt_media" then
    ui_state.filter = "media"; ui_state.page = 1; M.redraw_now()
  elseif id == "page_prev" then
    ui_state.page = math.max(1, ui_state.page - 1); M.redraw_now()
  elseif id == "page_next" then
    ui_state.page = ui_state.page + 1; M.redraw_now()
  elseif id == "export_json" or id == "export_md" then
    local cid, gid = get_selected_context()
    local subset = persistence.query({
      scope = ui_state.scope,
      channel_id = cid,
      guild_id = gid,
      kind = (ui_state.tab == "media") and "media" or ui_state.filter,
      query = ui_state.query,
    })
    local is_json = (id == "export_json")
    local payload = is_json and persistence.export_json(subset) or persistence.export_markdown(subset)
    local fname = is_json and "ccord-message-logs.json" or "ccord-message-logs.md"
    async.spawn(function()
      local saved, err = ui.file.save({ suggested_name = fname, data = payload })
      if saved and saved.path then
        ui.toast.show("Exported " .. #subset .. " log(s) to " .. saved.path, "info")
      elseif err then
        util.safe_log("debug", "export cancelled/failed: " .. tostring(err))
      end
    end)
  elseif id == "clear_scope" then
    local cid, gid = get_selected_context()
    local scope = ui_state.scope
    local desc = (scope == "channel" and util.is_nonempty_id(cid)) and "all logged messages & saved media for this channel"
      or ((scope == "guild" and util.is_nonempty_id(gid)) and "all logged messages & saved media for this server"
      or "ALL logged messages & saved media")
    async.spawn(function()
      local res = ui.dialog.confirm({
        title = "Clear Logged Messages",
        message = "Permanently remove " .. desc .. "?",
        confirm_label = "Clear",
      })
      if res and res.accepted then
        local removed = 0
        if scope == "channel" and util.is_nonempty_id(cid) then
          removed = persistence.clear_channel(cid)
          capture.clear_inline_deleted_channel(cid)
        elseif scope == "guild" and util.is_nonempty_id(gid) then
          removed = persistence.clear_guild(gid)
          capture.refresh_all_inline_deleted()
          capture.refresh_all_inline_edits()
        else
          removed = persistence.clear_all()
          capture.clear_all_inline_deleted()
          media.clear_preview_textures()
        end
        ui.toast.show("Cleared " .. removed .. " logged message(s)", "info")
        M.redraw_now()
      end
    end)
  elseif id:sub(1, 12) == "profile_rec:" then
    local uid = id:sub(13)
    local rec = persistence.find_by_uid(uid)
    if rec and util.is_nonempty_id(rec.author_id) and ui and ui.open_user_profile then
      pcall(ui.open_user_profile, rec.author_id, (not rec.is_dm and util.is_nonempty_id(rec.guild_id)) and rec.guild_id or nil)
    end
  elseif id:sub(1, 9) == "jump_rec:" then
    local uid = id:sub(10)
    local rec = persistence.find_by_uid(uid)
    if rec then
      jump_to_record(rec)
    end
  elseif id:sub(1, 9) == "copy_rec:" then
    local uid = id:sub(10)
    local rec = persistence.find_by_uid(uid)
    if rec then
      local txt = rec.content or ""
      if txt == "" and type(rec.attachments) == "table" and #rec.attachments > 0 then
        txt = rec.attachments[1].url or rec.attachments[1].filename or ""
      end
      clipboard.write(txt)
      ui.toast.show("Copied logged message text", "info")
    end
  elseif id:sub(1, 9) == "show_rec:" then
    local uid = id:sub(10)
    local rec = persistence.find_by_uid(uid)
    if rec then
      capture.restore_inline_record(rec)
      M.redraw_now()
    end
  elseif id:sub(1, 8) == "del_rec:" then
    local uid = id:sub(9)
    local rec = persistence.find_by_uid(uid)
    if persistence.delete_record(uid) then
      if rec then capture.remove_inline_deleted(rec) end
      M.redraw_now()
    end
  elseif id:sub(1, 6) == "wl_rm:" then
    local scope_key, target_id = id:match("^wl_rm:([^:]+):(.+)$")
    if scope_key and target_id then
      whitelist.remove_entry(scope_key, target_id)
      M.redraw_now()
    end
  elseif id:sub(1, 9) == "view_att:" then
    local uid, idx_s = id:match("^view_att:([^:]+):(%d+)$")
    local rec = uid and persistence.find_by_uid(uid)
    if rec then
      open_attachment_lightbox(rec, tonumber(idx_s) or 1)
    end
  elseif id:sub(1, 12) == "copyurl_att:" then
    local uid, idx_s = id:match("^copyurl_att:([^:]+):(%d+)$")
    local rec = uid and persistence.find_by_uid(uid)
    local att = rec and rec.attachments and rec.attachments[tonumber(idx_s)]
    if att and att.url then
      clipboard.write(att.url)
      ui.toast.show("Copied attachment URL", "info")
    end
  elseif id:sub(1, 9) == "save_att:" then
    local uid, idx_s = id:match("^save_att:([^:]+):(%d+)$")
    local rec = uid and persistence.find_by_uid(uid)
    local att = rec and rec.attachments and rec.attachments[tonumber(idx_s)]
    if att then
      local bytes, rerr = media.read_attachment_bytes(att)
      if not bytes then
        ui.toast.show("Cannot export media: " .. tostring(rerr), "error")
      else
        async.spawn(function()
          local saved = ui.file.save({ suggested_name = att.filename or "attachment.bin", data = bytes })
          if saved and saved.path then
            ui.toast.show("Saved media to " .. saved.path, "info")
          end
        end)
      end
    end
  elseif id:sub(1, 10) == "retry_att:" then
    local uid = id:match("^retry_att:([^:]+):")
    local rec = uid and persistence.find_by_uid(uid)
    if rec then
      media.archive_for_record(rec)
      ui.toast.show("Retrying media archive...", "info")
      M.redraw_now()
    end
  end
end

function M.refresh_header_button()
  if not (ui and ui.actionButton) then return end
  if ui_state.header_btn_mounted then
    pcall(ui.actionButton.remove, HEADER_BTN_ID)
    ui_state.header_btn_mounted = false
  end
  if not config.get("show_header_button") then return end

  local cid, gid = live_selected_context()
  local cnt = util.is_nonempty_id(cid) and persistence.count_for_channel(cid) or 0
  local mon, reason = false, "none"
  if util.is_nonempty_id(cid) then
    mon, reason = whitelist.is_monitored(gid, cid)
  end
  local badge = nil
  if cnt > 0 then
    badge = cnt > 99 and "99+" or tostring(cnt)
  elseif mon then
    badge = (reason == "active") and "LIVE" or "ON"
  end

  local tip = (reason == "active")
    and "Message Logger (logging active channel; right-click to whitelist for background)"
    or (mon and "Message Logger (channel whitelisted) — click to toggle" or "Open Message Logger")

  local ok = pcall(ui.actionButton.add, {
    id = HEADER_BTN_ID,
    slot = "header",
    icon = "inbox",
    label = "Logs",
    badge = badge,
    tooltip = tip,
    action = function()
      M.toggle_drawer()
    end,
  })
  ui_state.header_btn_mounted = ok == true
end

function M.sync_rail_tab()
  if not (ui and ui.panel) then return end
  local want = config.get("show_rail_tab") == true
  if want and not ui_state.fullview_mounted then
    local ok = pcall(ui.panel.mount, {
      id = FULLVIEW_ID,
      slot = "full_view",
      title = "Message Logger",
      icon = "inbox",
      root = build_root_tree(false),
      on_event = handle_panel_event,
    })
    ui_state.fullview_mounted = ok == true
  elseif not want and ui_state.fullview_mounted then
    pcall(ui.panel.unmount, FULLVIEW_ID)
    ui_state.fullview_mounted = false
  end
end

function M.redraw_now()
  if redraw_timer and time and time.cancel then
    pcall(time.cancel, redraw_timer)
    redraw_timer = nil
  end
  M.refresh_header_button()

  if not (ui and ui.panel) then return end

  if ui_state.drawer_open then
    local tree = build_root_tree(true)
    if not ui_state.drawer_mounted then
      local ok = pcall(ui.panel.mount, {
        id = DRAWER_ID,
        slot = "right_sidebar",
        width = 360,
        title = "Message Logger",
        visible = true,
        root = tree,
        on_event = handle_panel_event,
      })
      ui_state.drawer_mounted = ok == true
    else
      pcall(ui.panel.update, DRAWER_ID, { visible = true, root = tree })
    end
  elseif ui_state.drawer_mounted then
    pcall(ui.panel.unmount, DRAWER_ID)
    ui_state.drawer_mounted = false
  end

  if ui_state.fullview_mounted then
    pcall(ui.panel.update, FULLVIEW_ID, { root = build_root_tree(false) })
  end
end

function M.schedule_redraw(delay_ms)
  if redraw_timer and time and time.cancel then
    pcall(time.cancel, redraw_timer)
    redraw_timer = nil
  end
  if time and time.after then
    redraw_timer = time.after(delay_ms or 120, function()
      redraw_timer = nil
      M.redraw_now()
    end)
  else
    M.redraw_now()
  end
end

function M.open_drawer(opts)
  opts = opts or {}
  if opts.tab then ui_state.tab = opts.tab end
  if opts.scope then ui_state.scope = opts.scope end
  if opts.filter then ui_state.filter = opts.filter end
  if opts.channel_id ~= nil then ui_state.target_channel_id = opts.channel_id end
  if opts.guild_id ~= nil then ui_state.target_guild_id = opts.guild_id end
  ui_state.page = 1
  ui_state.drawer_open = true
  M.redraw_now()
end

function M.toggle_drawer()
  ui_state.drawer_open = not ui_state.drawer_open
  if ui_state.drawer_open then
    ui_state.target_channel_id = nil
    ui_state.target_guild_id = nil
    ui_state.page = 1
  end
  M.redraw_now()
end

function M.on_navigation_changed()
  ui_state.target_channel_id = nil
  ui_state.target_guild_id = nil
  ui_state.page = 1
  M.schedule_redraw(80)
end

function M.init()
  M.sync_rail_tab()
  M.refresh_header_button()
end

return M
