-- Pure utility helpers for C-Cord Message Logger (Lua 5.5 sandbox-safe).

local M = {}

local IMAGE_EXTS = {
  png = true, jpg = true, jpeg = true, gif = true, webp = true,
  bmp = true, avif = true, apng = true, svg = true, ico = true, tiff = true, tif = true,
}

local PREVIEWABLE_IMAGE_EXTS = {
  png = true, jpg = true, jpeg = true, webp = true, gif = true,
}

local MEM_PREVIEWABLE_IMAGE_EXTS = {
  png = true, jpg = true, jpeg = true, webp = true,
}

local VIDEO_EXTS = {
  mp4 = true, webm = true, mov = true, mkv = true, avi = true,
  m4v = true, ogv = true, wmv = true, flv = true, mpg = true, mpeg = true, ["3gp"] = true,
}

function M.safe_log(level, msg)
  local s = tostring(msg or "")
  if #s > 950 then
    s = string.sub(s, 1, 947) .. "..."
  end
  local fn = log and log[level]
  if fn then
    pcall(fn, "[MessageLogger] " .. s)
  end
end

function M.trim(s)
  if type(s) ~= "string" then return "" end
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.truncate(s, max_chars)
  if type(s) ~= "string" then return "" end
  max_chars = max_chars or 200
  local ok, len = pcall(utf8.len, s)
  if ok and len then
    if len <= max_chars then return s end
    local byte_pos = utf8.offset(s, math.max(1, max_chars - 2))
    if byte_pos and byte_pos > 1 then
      return string.sub(s, 1, byte_pos - 1) .. "..."
    end
  end
  if #s <= max_chars then return s end
  return string.sub(s, 1, math.max(1, max_chars - 3)) .. "..."
end

function M.is_nonempty_id(id)
  return type(id) == "string" and id ~= "" and id ~= "0"
end

function M.is_valid_snowflake(id)
  if type(id) ~= "string" or id == "" or id == "0" then return false end
  if not id:match("^%d+$") then return false end
  -- Unconfirmed bit-63 local echo IDs overflow signed 64-bit integer in Lua 5.5
  return math.tointeger(id) ~= nil
end

function M.sanitize_filename(name, fallback)
  local s = type(name) == "string" and name or ""
  -- Strip directory components
  s = s:gsub("^.*[/\\]", "")
  -- Replace unsafe characters
  s = s:gsub("[^A-Za-z0-9._-]", "_")
  -- Collapse leading dots or double dots
  s = s:gsub("^%.+", "")
  s = s:gsub("%.%.+", ".")
  if #s > 96 then
    local ext = s:match("(%.%w+)$") or ""
    if #ext > 12 then ext = "" end
    local stem = string.sub(s, 1, 96 - #ext)
    s = stem .. ext
  end
  if s == "" then
    return fallback or "file.bin"
  end
  return s
end

function M.extract_ext(filename, url)
  local cand = type(filename) == "string" and filename or ""
  local ext = cand:match("%.([A-Za-z0-9]+)$")
  if not ext and type(url) == "string" then
    local clean = url:match("^([^?#]+)") or url
    ext = clean:match("%.([A-Za-z0-9]+)$")
  end
  return ext and string.lower(ext) or ""
end

function M.classify_attachment(att)
  if type(att) ~= "table" then return "other" end
  local ct = string.lower(tostring(att.content_type or ""))
  if ct:sub(1, 6) == "image/" then return "image" end
  if ct:sub(1, 6) == "video/" then return "video" end
  local ext = M.extract_ext(att.filename, att.url)
  if IMAGE_EXTS[ext] then return "image" end
  if VIDEO_EXTS[ext] then return "video" end
  return "other"
end

function M.plugin_data_uri(rel_path)
  if type(rel_path) ~= "string" or rel_path == "" then return nil end
  if rel_path:sub(1, 14) == "plugin_data://" then return rel_path end
  local clean = rel_path:gsub("^/+", "")
  if clean == "" then return nil end
  return "plugin_data://" .. clean
end

function M.strip_plugin_data_uri(path)
  if type(path) ~= "string" or path == "" then return nil end
  if path:sub(1, 14) == "plugin_data://" then
    path = path:sub(15)
  end
  path = path:gsub("^/+", "")
  if path == "" then return nil end
  return path
end

function M.is_previewable_image(att, allow_gif)
  if type(att) ~= "table" then return false end
  local ct = string.lower(tostring(att.content_type or ""))
  if ct == "image/png" or ct == "image/jpeg" or ct == "image/jpg" or ct == "image/webp" then
    return true
  end
  if allow_gif and ct == "image/gif" then
    return true
  end
  local ext = M.extract_ext(att.filename, att.rel_path or att.local_path or att.url)
  if allow_gif then
    return PREVIEWABLE_IMAGE_EXTS[ext] == true
  end
  return MEM_PREVIEWABLE_IMAGE_EXTS[ext] == true
end

function M.is_safe_https_url(url)
  if type(url) ~= "string" then return false end
  if #url < 10 or #url > 2048 then return false end
  if url:sub(1, 8) ~= "https://" then return false end
  if url:find("[%c%s]") then return false end
  return true
end

function M.format_bytes(bytes)
  local n = tonumber(bytes) or 0
  if n < 0 then n = 0 end
  if n < 1024 then
    return string.format("%d B", math.floor(n))
  elseif n < 1024 * 1024 then
    return string.format("%.1f KiB", n / 1024)
  elseif n < 1024 * 1024 * 1024 then
    return string.format("%.2f MiB", n / (1024 * 1024))
  else
    return string.format("%.2f GiB", n / (1024 * 1024 * 1024))
  end
end

-- Fallback civil date conversion (UTC) if host time.format_discord/local_parts are unavailable.
local function civil_from_days(z)
  z = z + 719468
  local era = (z >= 0 and z or (z - 146096)) // 146097
  local doe = z - era * 146097
  local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
  local mp = (5 * doy + 2) // 153
  local d = doy - (153 * mp + 2) // 5 + 1
  local m = mp + (mp < 10 and 3 or -9)
  if m <= 2 then y = y + 1 end
  return y, m, d
end

function M.format_timestamp(ts_ms)
  local ms = math.floor(tonumber(ts_ms) or 0)
  if ms <= 0 then return "Unknown time" end
  if time and time.format_discord then
    local ok, s = pcall(time.format_discord, ms, "message")
    if ok and type(s) == "string" and s ~= "" then return s end
  end
  if time and time.local_parts then
    local ok, p = pcall(time.local_parts, ms)
    if ok and type(p) == "table" then
      return string.format("%04d-%02d-%02d %02d:%02d", p.year or 1970, p.month or 1, p.day or 1, p.hour or 0, p.min or 0)
    end
  end
  local total_s = ms // 1000
  local days = total_s // 86400
  local rem = total_s % 86400
  local hour = rem // 3600
  local min = (rem % 3600) // 60
  local sec = rem % 60
  local y, mo, d = civil_from_days(days)
  return string.format("%04d-%02d-%02d %02d:%02d:%02d", y, mo, d, hour, min, sec)
end

function M.format_timestamp_full(ts_ms)
  local ms = math.floor(tonumber(ts_ms) or 0)
  if ms <= 0 then return "Unknown time" end
  if time and time.format_discord then
    local ok, s = pcall(time.format_discord, ms, "f")
    if ok and type(s) == "string" and s ~= "" then return s end
  end
  return M.format_timestamp(ms)
end

function M.format_relative(ts_ms, now_ms)
  local ts = math.floor(tonumber(ts_ms) or 0)
  if ts <= 0 then return "" end
  if time and time.format_discord then
    local ok, s = pcall(time.format_discord, ts, "R")
    if ok and type(s) == "string" and s ~= "" then return s end
  end
  local now = tonumber(now_ms) or (time and time.now_ms() or 0)
  local diff_s = math.floor((now - ts) / 1000)
  if diff_s < 0 then diff_s = 0 end
  if diff_s < 10 then return "just now" end
  if diff_s < 60 then return diff_s .. "s ago" end
  if diff_s < 3600 then return (diff_s // 60) .. "m ago" end
  if diff_s < 86400 then return (diff_s // 3600) .. "h ago" end
  return (diff_s // 86400) .. "d ago"
end

function M.safe_hex(col, fallback)
  if type(col) == "string" and (col:match("^#%x%x%x%x%x%x$") or col:match("^#%x%x%x%x%x%x%x%x$")) then
    return col
  end
  return fallback or "#e5484d"
end

function M.hex_tint(hex, alpha_frac)
  local base = M.safe_hex(hex, "#e5484d")
  if color and color.alpha then
    local ok, out = pcall(color.alpha, base, alpha_frac or 0.14)
    if ok and type(out) == "string" then return out end
  end
  local a = math.max(0, math.min(255, math.floor((alpha_frac or 0.14) * 255 + 0.5)))
  return base:sub(1, 7) .. string.format("%02x", a)
end

function M.table_count(tbl)
  if type(tbl) ~= "table" then return 0 end
  local n = 0
  for _ in pairs(tbl) do n = n + 1 end
  return n
end

return M
