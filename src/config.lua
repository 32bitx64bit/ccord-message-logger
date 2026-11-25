-- Declarative settings schema & live config access for C-Cord Message Logger (v1.0.0).

local util = require("src.util")

local M = {}

local DEFAULTS = {
  -- Storage & Persistence
  storage_mode = "disk",
  max_log_entries = 1000,
  cache_per_channel = 200,

  -- Monitoring & Whitelist
  monitor_mode = "whitelist",
  monitor_active_channel = true,
  log_deleted = true,
  log_edited = true,
  log_uncached_deletes = false,
  ignore_bots = true,
  ignore_self = false,
  show_whitelist_badges = true,

  -- Media Archiving (Images & Videos)
  save_media = true,
  save_images = true,
  save_videos = true,
  save_other_files = false,
  media_capture_mode = "precache",
  max_media_mb = 25,
  max_media_total_mb = 250,
  max_precache_mb = 100,

  -- Display & Appearance
  show_inline_deleted = true,
  show_deleted_accent_bar = false,
  show_deleted_tint = true,
  decorate_edited = true,
  edited_style = "inline",
  show_header_button = true,
  show_rail_tab = true,
  toast_on_delete = false,
  deleted_color = "#e5484d",
  deleted_avatar_opacity = 55,
  edited_color = "#d99b26",
}

local SCHEMA = {
  { type = "section", label = "Storage & Persistence" },
  {
    key = "storage_mode",
    type = "select",
    label = "Persistence Mode",
    description = "Disk persists logs & archived media inside C-Cord's sandboxed plugin data folder across restarts; Memory keeps everything strictly in RAM until restart.",
    default = DEFAULTS.storage_mode,
    options = {
      { label = "Persistent on Disk (Sandboxed Plugin Data)", value = "disk" },
      { label = "In-Memory Only (Until Restart)", value = "memory" },
    },
  },
  {
    key = "max_log_entries",
    type = "slider",
    label = "Max Stored Log Entries",
    description = "Oldest logged entries are pruned automatically once this limit is exceeded.",
    min = 50,
    max = 5000,
    step = 50,
    default = DEFAULTS.max_log_entries,
  },
  {
    key = "cache_per_channel",
    type = "slider",
    label = "Live Message Cache per Channel",
    description = "Recent messages cached in RAM per monitored channel so deletes and edits can be captured.",
    min = 50,
    max = 500,
    step = 25,
    default = DEFAULTS.cache_per_channel,
  },

  { type = "section", label = "Monitoring & Whitelist" },
  {
    key = "monitor_mode",
    type = "select",
    label = "Background Monitoring Scope",
    description = "Controls how idle/background channels are monitored. Right-click any channel, DM, category, voice channel, or server to whitelist or exclude it.",
    default = DEFAULTS.monitor_mode,
    options = {
      { label = "Whitelist Only for Idle Channels (Default)", value = "whitelist" },
      { label = "All Channels (Except Excluded)", value = "all" },
    },
  },
  {
    key = "monitor_active_channel",
    type = "toggle",
    label = "Monitor Actively Viewed Channel",
    description = "Automatically log deleted & edited messages in whichever channel or DM you are currently viewing (idle channels still require whitelisting).",
    default = DEFAULTS.monitor_active_channel,
  },
  {
    key = "log_deleted",
    type = "toggle",
    label = "Log Deleted Messages",
    description = "Capture and save messages when they are deleted (including bulk purges).",
    default = DEFAULTS.log_deleted,
  },
  {
    key = "log_edited",
    type = "toggle",
    label = "Log Edited Messages",
    description = "Track previous versions when a message is edited in a monitored channel.",
    default = DEFAULTS.log_edited,
  },
  {
    key = "log_uncached_deletes",
    type = "toggle",
    label = "Log Uncached Deletions",
    description = "Record a placeholder entry even if a deleted message was sent before it entered cache.",
    default = DEFAULTS.log_uncached_deletes,
    visible_when = { key = "log_deleted", truthy = true },
  },
  {
    key = "ignore_bots",
    type = "toggle",
    label = "Ignore Bots & Webhooks",
    description = "Skip messages authored by bots.",
    default = DEFAULTS.ignore_bots,
  },
  {
    key = "ignore_self",
    type = "toggle",
    label = "Ignore Your Own Messages",
    description = "Do not log messages that you delete or edit yourself.",
    default = DEFAULTS.ignore_self,
  },
  {
    key = "show_whitelist_badges",
    type = "toggle",
    label = "Sidebar Whitelist Badges",
    description = "Display a subtle LOG badge on whitelisted channels, DMs, and servers.",
    default = DEFAULTS.show_whitelist_badges,
  },

  { type = "section", label = "Media Archiving (Images & Videos)" },
  {
    key = "save_media",
    type = "toggle",
    label = "Store Deleted Media",
    description = "Archive images and videos from deleted messages before Discord CDN removes them.",
    default = DEFAULTS.save_media,
  },
  {
    key = "save_images",
    type = "toggle",
    label = "Archive Images",
    description = "Save PNG, JPEG, GIF, WebP, AVIF, and other image attachments.",
    default = DEFAULTS.save_images,
    visible_when = { key = "save_media", truthy = true },
  },
  {
    key = "save_videos",
    type = "toggle",
    label = "Archive Videos",
    description = "Save MP4, WebM, MOV, MKV, and other video attachments.",
    default = DEFAULTS.save_videos,
    visible_when = { key = "save_media", truthy = true },
  },
  {
    key = "save_other_files",
    type = "toggle",
    label = "Archive Other Attachments",
    description = "Also save non-image/video files (audio, documents, archives).",
    default = DEFAULTS.save_other_files,
    visible_when = { key = "save_media", truthy = true },
  },
  {
    key = "media_capture_mode",
    type = "select",
    label = "Media Capture Strategy",
    description = "Pre-cache saves media temporarily and promotes it atomically on delete so instant CDN purges cannot lose files.",
    default = DEFAULTS.media_capture_mode,
    visible_when = { key = "save_media", truthy = true },
    options = {
      { label = "Pre-cache & Promote on Delete (Most Reliable)", value = "precache" },
      { label = "Download Only When Deleted (Low Bandwidth)", value = "on_delete" },
    },
  },
  {
    key = "max_media_mb",
    type = "slider",
    label = "Max Single Media File Size (MiB)",
    description = "Skip downloading individual files larger than this limit (disk streams up to 256 MiB; memory caps at 8 MiB desktop / 4 MiB Android).",
    min = 1,
    max = 256,
    step = 1,
    default = DEFAULTS.max_media_mb,
    visible_when = { key = "save_media", truthy = true },
  },
  {
    key = "max_media_total_mb",
    type = "slider",
    label = "Max Total Archived Media Quota (MiB)",
    description = "Oldest archived media files are pruned when total archived media exceeds this quota.",
    min = 25,
    max = 2000,
    step = 25,
    default = DEFAULTS.max_media_total_mb,
    visible_when = { key = "storage_mode", equals = "disk" },
  },
  {
    key = "max_precache_mb",
    type = "slider",
    label = "Max Temporary Pre-cache Size (MiB)",
    description = "Rolling cache cap for active attachments waiting in monitored channels.",
    min = 10,
    max = 500,
    step = 10,
    default = DEFAULTS.max_precache_mb,
    visible_when = { key = "storage_mode", equals = "disk" },
  },

  { type = "section", label = "Display & Appearance" },
  {
    key = "show_inline_deleted",
    type = "toggle",
    label = "Show Deleted Messages Inline in Chat",
    description = "Keep deleted messages in their native timeline position in red, with red username and Rec.709 grayscale avatar on header rows.",
    default = DEFAULTS.show_inline_deleted,
  },
  {
    key = "show_deleted_tint",
    type = "toggle",
    label = "Subtle Red Row Tint on Deleted Messages",
    description = "Add a soft red background highlight behind deleted messages in chat.",
    default = DEFAULTS.show_deleted_tint,
    visible_when = { key = "show_inline_deleted", truthy = true },
  },
  {
    key = "show_deleted_accent_bar",
    type = "toggle",
    label = "Left Red Accent Bar on Deleted Messages",
    description = "Draw a 3px red vertical accent bar on the left edge of deleted messages.",
    default = DEFAULTS.show_deleted_accent_bar,
    visible_when = { key = "show_inline_deleted", truthy = true },
  },
  {
    key = "deleted_color",
    type = "color",
    label = "Deleted Message & Username Color",
    default = DEFAULTS.deleted_color,
    visible_when = { key = "show_inline_deleted", truthy = true },
  },
  {
    key = "deleted_avatar_opacity",
    type = "slider",
    label = "Deleted Profile Picture Opacity (%)",
    description = "Opacity applied alongside Rec.709 grayscale on deleted header message avatars.",
    min = 20,
    max = 100,
    step = 5,
    default = DEFAULTS.deleted_avatar_opacity,
    visible_when = { key = "show_inline_deleted", truthy = true },
  },
  {
    key = "decorate_edited",
    type = "toggle",
    label = "Show Former Versions Inside Edited Messages",
    description = "Render ordered previous versions directly inside edited messages above the current text.",
    default = DEFAULTS.decorate_edited,
  },
  {
    key = "edited_style",
    type = "select",
    label = "Former Version Inline Style",
    description = "Inline text blends natively into the message body in muted gray; Left Hairline adds a subtle vertical quote bar.",
    default = DEFAULTS.edited_style,
    visible_when = { key = "decorate_edited", truthy = true },
    options = {
      { label = "Native Inline Text (Default)", value = "inline" },
      { label = "Subtle Left Hairline", value = "quote" },
    },
  },
  {
    key = "edited_color",
    type = "color",
    label = "Edited Accent Color",
    default = DEFAULTS.edited_color,
    visible_when = { key = "decorate_edited", truthy = true },
  },
  {
    key = "show_header_button",
    type = "toggle",
    label = "Channel Header Log Button",
    description = "Show a quick-access Message Logger button with count badge in the header.",
    default = DEFAULTS.show_header_button,
  },
  {
    key = "show_rail_tab",
    type = "toggle",
    label = "Server Rail Full-View Tab",
    description = "Add a dedicated full-screen Message Logger workspace tab on the server rail.",
    default = DEFAULTS.show_rail_tab,
  },
  {
    key = "toast_on_delete",
    type = "toggle",
    label = "Toast Notification on Delete",
    description = "Display an actionable toast alert with a Jump button whenever a message is deleted in a monitored channel.",
    default = DEFAULTS.toast_on_delete,
  },

  { type = "section", label = "Maintenance" },
  {
    key = "export_logs_btn",
    type = "button",
    label = "Export Saved Logs",
    description = "Save all logged deleted & edited messages as a JSON file.",
    button_label = "Export JSON",
    variant = "secondary",
  },
  {
    key = "clear_precache_btn",
    type = "button",
    label = "Clear Media Pre-cache",
    description = "Remove temporary pre-cached attachments waiting for deletion.",
    button_label = "Clear Pre-cache",
    variant = "secondary",
  },
  {
    key = "clear_all_logs_btn",
    type = "button",
    label = "Clear All History & Archived Media",
    description = "Permanently delete every saved message log and archived media file.",
    button_label = "Clear All Logs",
    variant = "danger",
  },
}

local change_listeners = {}
local action_listeners = {}
local initialized = false

function M.init()
  if initialized then return end
  initialized = true
  settings.schema(SCHEMA)
  settings.on_change(function(key, val)
    for i = 1, #change_listeners do
      local ok, err = pcall(change_listeners[i], key, val)
      if not ok then
        util.safe_log("error", "settings listener error for " .. tostring(key) .. ": " .. tostring(err))
      end
    end
  end)
  if settings.on_action then
    settings.on_action(function(key)
      for i = 1, #action_listeners do
        local ok, err = pcall(action_listeners[i], key)
        if not ok then
          util.safe_log("error", "settings action error for " .. tostring(key) .. ": " .. tostring(err))
        end
      end
    end)
  end
end

function M.get(key)
  local def = DEFAULTS[key]
  -- Always pass explicit 2nd argument to settings.get per C-Cord API guidelines.
  local val = settings.get(key, def)
  if val == nil then return def end
  return val
end

function M.set(key, val)
  settings.set(key, val)
  for i = 1, #change_listeners do
    pcall(change_listeners[i], key, val)
  end
end

function M.on_change(fn)
  if type(fn) == "function" then
    change_listeners[#change_listeners + 1] = fn
  end
end

function M.on_action(fn)
  if type(fn) == "function" then
    action_listeners[#action_listeners + 1] = fn
  end
end

function M.is_disk_mode()
  return M.get("storage_mode") == "disk"
end

return M
