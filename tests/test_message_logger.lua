-- Comprehensive End-to-End Integration Test Suite for C-Cord Message Logger v1.0.0 (Lua 5.5)
-- Exercises ALL v1.0.0 C-Cord APIs with ZERO fs.*, ZERO system.*, ZERO gateway.raw exposed:
-- storage.files.* + plugin_data:// URIs, atomic storage.files.rename, ui.decorate.message_accessory (above_body),
-- upgraded events.messages (attachments, author_bot, message.delete_bulk, messages.loaded),
-- plugin.on_unload, time.format_discord/local_parts, ui.media.open, navigation.jump_to_message,
-- ui.open_user_profile, ui.menu.popup, interactive ui.toast.show, settings visible_when & buttons.

local real_io = io
local real_os = os
local real_print = print
local real_loadfile = loadfile

local script_path = (arg and arg[0]) or "tests/test_message_logger.lua"
local script_dir = script_path:match("^(.*)[/\\][^/\\]+$") or "."
local PLUGIN_DIR = (script_dir == "." or script_dir == "tests") and "." or (script_dir .. "/..")
local TEST_TMP = (real_os.getenv("TMPDIR") or "/tmp") .. "/ccord-message-logger-test"
local JAIL_ROOT = TEST_TMP .. "/plugin_data"

real_os.execute("rm -rf " .. string.format("%q", TEST_TMP) .. " && mkdir -p " .. string.format("%q", JAIL_ROOT))

local function json_escape(s)
  return s:gsub('[%z\1-\31\\"]', function(c)
    if c == '"' then return '\\"'
    elseif c == '\\' then return '\\\\'
    elseif c == '\n' then return '\\n'
    elseif c == '\r' then return '\\r'
    elseif c == '\t' then return '\\t'
    else return string.format("\\u%04x", string.byte(c)) end
  end)
end

local function is_array(t)
  local n = #t
  if n == 0 then return false end
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k > n or math.floor(k) ~= k then return false end
  end
  return true
end

local function json_encode(v)
  local tv = type(v)
  if tv == "nil" then return "null"
  elseif tv == "boolean" then return v and "true" or "false"
  elseif tv == "number" then return tostring(v)
  elseif tv == "string" then return '"' .. json_escape(v) .. '"'
  elseif tv == "table" then
    if is_array(v) then
      local parts = {}
      for i = 1, #v do parts[i] = json_encode(v[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local parts = {}
      for k, val in pairs(v) do
        if type(k) == "string" and val ~= nil then
          parts[#parts + 1] = '"' .. json_escape(k) .. '":' .. json_encode(val)
        end
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  error("unsupported json type: " .. tv)
end

local function json_decode(str)
  local i, len = 1, #str
  local function skip_ws()
    while i <= len do
      local c = str:sub(i, i)
      if c == " " or c == "\t" or c == "\r" or c == "\n" then i = i + 1 else break end
    end
  end
  local parse_val
  local function parse_str()
    i = i + 1
    local out = {}
    while i <= len do
      local c = str:sub(i, i)
      if c == '"' then i = i + 1; return table.concat(out)
      elseif c == '\\' then
        i = i + 1
        local e = str:sub(i, i)
        if e == '"' or e == '\\' or e == '/' then out[#out+1] = e; i = i + 1
        elseif e == 'n' then out[#out+1] = '\n'; i = i + 1
        elseif e == 'r' then out[#out+1] = '\r'; i = i + 1
        elseif e == 't' then out[#out+1] = '\t'; i = i + 1
        elseif e == 'b' then out[#out+1] = '\b'; i = i + 1
        elseif e == 'f' then out[#out+1] = '\f'; i = i + 1
        elseif e == 'u' then
          local hex = str:sub(i+1, i+4)
          out[#out+1] = utf8.char(tonumber(hex, 16))
          i = i + 5
        else error("bad escape") end
      else
        out[#out+1] = c; i = i + 1
      end
    end
    error("unterminated string")
  end
  local function parse_obj()
    i = i + 1; skip_ws()
    local obj = {}
    if str:sub(i, i) == '}' then i = i + 1; return obj end
    while true do
      skip_ws()
      local k = parse_str()
      skip_ws(); assert(str:sub(i, i) == ':'); i = i + 1
      skip_ws()
      obj[k] = parse_val()
      skip_ws()
      local c = str:sub(i, i)
      if c == '}' then i = i + 1; return obj end
      assert(c == ','); i = i + 1
    end
  end
  local function parse_arr()
    i = i + 1; skip_ws()
    local arr = {}
    if str:sub(i, i) == ']' then i = i + 1; return arr end
    while true do
      skip_ws()
      arr[#arr+1] = parse_val()
      skip_ws()
      local c = str:sub(i, i)
      if c == ']' then i = i + 1; return arr end
      assert(c == ','); i = i + 1
    end
  end
  parse_val = function()
    skip_ws()
    local c = str:sub(i, i)
    if c == '"' then return parse_str()
    elseif c == '{' then return parse_obj()
    elseif c == '[' then return parse_arr()
    elseif str:sub(i, i+3) == "true" then i = i + 4; return true
    elseif str:sub(i, i+4) == "false" then i = i + 5; return false
    elseif str:sub(i, i+3) == "null" then i = i + 4; return nil
    else
      local num = str:match("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
      assert(num and #num > 0, "bad json near: " .. str:sub(i, i+20))
      i = i + #num
      return tonumber(num)
    end
  end
  return parse_val()
end

local function freeze(tbl)
  return setmetatable({}, {
    __index = tbl,
    __newindex = function() error("attempt to modify frozen C-Cord API table") end,
  })
end

local ALLOWED_HOSTS = {
  ["cdn.discordapp.com"] = true,
  ["media.discordapp.net"] = true,
  ["images-ext-1.discordapp.net"] = true,
  ["images-ext-2.discordapp.net"] = true,
}

local function check_allowed_host(url)
  local host = url:match("^https://([^/:]+)")
  assert(host and ALLOWED_HOSTS[host], "blocked host not in allowed_hosts: " .. tostring(url))
end

local function resolve_jail_rel(rel)
  assert(type(rel) == "string" and rel ~= "", "storage.files requires non-empty relative path")
  assert(rel:sub(1, 1) ~= "/", "storage.files forbids absolute paths: " .. rel)
  assert(not rel:find("..", 1, true), "storage.files forbids traversal: " .. rel)
  return JAIL_ROOT .. "/" .. rel
end

local function resolve_plugin_data_uri(uri)
  assert(type(uri) == "string" and uri:sub(1, 14) == "plugin_data://", "expected plugin_data:// URI, got: " .. tostring(uri))
  return resolve_jail_rel(uri:sub(15))
end

local mock = {
  now_ms = 1763960000000,
  uuid_n = 0,
  kv = {},
  settings_schema = nil,
  settings_listeners = {},
  settings_action_listeners = {},
  unload_cbs = {},
  event_listeners = {},
  menus = {},
  menu_states = {},
  panels = {},
  panel_patches = {},
  textures = {},
  upload_file_calls = {},
  media_open_calls = {},
  profile_open_calls = {},
  popup_calls = {},
  jump_calls = {},
  select_channel_calls = {},
  decors = {},
  action_buttons = {},
  commands = {},
  keybinds = {},
  toasts = {},
  clipboard = "",
  saved_files = {},
  local_msgs = {},
  local_msgs_by_id = {},
  local_updates = {},
  next_local_id = 1,
  logs = {},
  dialog_accept = true,
  download_calls = {},
  http_get_calls = {},
  rename_calls = {},
  fake_cdn = {
    ["https://cdn.discordapp.com/attachments/100/200/cat.png"] = "\x89PNG\r\n\x1a\n\x00FAKEPNGDATA1234567890",
    ["https://cdn.discordapp.com/attachments/100/201/clip.mp4"] = "\x00\x00\x00\x18ftypmp42FAKEVIDEODATA" .. string.rep("V", 8192),
    ["https://cdn.discordapp.com/attachments/100/203/huge.png"] = "\x89PNG\r\n\x1a\n" .. string.rep("H", 900 * 1024),
  },
  selected = { guild_id = "1000", channel_id = "2000", view = "channel", is_dm = false },
  self_user = { id = "9999", name = "Gavin" },
  guilds = {
    ["1000"] = { id = "1000", name = "Dev Server", is_dm = false, muted = false },
    ["1001"] = { id = "1001", name = "Gaming", is_dm = false, muted = false },
  },
  channels = {
    ["2000"] = { id = "2000", guild_id = "1000", parent_id = "3000", name = "general", display_name = "general", kind = "text", is_dm = false },
    ["2001"] = { id = "2001", guild_id = "1000", parent_id = "3000", name = "bot-spam", display_name = "bot-spam", kind = "text", is_dm = false },
    ["2002"] = { id = "2002", guild_id = "1001", parent_id = nil, name = "off-topic", display_name = "off-topic", kind = "text", is_dm = false },
    ["2003"] = { id = "2003", guild_id = "dm", parent_id = nil, name = "Alice", display_name = "Alice", kind = "dm", is_dm = true },
    ["3000"] = { id = "3000", guild_id = "1000", parent_id = nil, name = "Main Category", display_name = "Main Category", kind = "category", is_dm = false },
  },
  store_msgs = {
    ["2000"] = {
      {
        id = "500001", channel_id = "2000", guild_id = "1000", author_id = "8001", author_name = "Bob", author_bot = false,
        content = "Pre-existing message in store", timestamp_ms = 1763959900000,
        attachments = {}, embeds = {},
      },
    },
  },
}

local sandbox_modules = {}
local function sandbox_require(mod)
  if sandbox_modules[mod] ~= nil then return sandbox_modules[mod] end
  local rel = mod:gsub("%.", "/") .. ".lua"
  local full = PLUGIN_DIR .. "/" .. rel
  local fn, err = real_loadfile(full)
  assert(fn, "require(" .. mod .. ") failed: " .. tostring(err))
  local res = fn()
  sandbox_modules[mod] = res == nil and true or res
  return sandbox_modules[mod]
end

_G.require = sandbox_require
_G.plugin = freeze({
  id = "io.github.32bitx64bit.message-logger",
  name = "Message Logger",
  version = "1.0.0",
  dir = PLUGIN_DIR,
  expose = function() return true end,
  on_unload = function(fn)
    mock.unload_cbs[#mock.unload_cbs + 1] = fn
    return true
  end,
})
_G.platform = freeze({
  os = "linux", arch = "x86_64", form_factor = "desktop",
  is_mobile = false, is_desktop = true, is_android = false,
  is_linux = true, is_macos = false, is_windows = false,
  touch = false, api_version = 1,
  has = function(c) return c == "panels" or c == "hover" end,
  viewport = function() return { width = 1280, height = 800, scale = 1 } end,
})
_G.log = freeze({
  debug = function(m) mock.logs[#mock.logs+1] = "D:" .. m end,
  info  = function(m) mock.logs[#mock.logs+1] = "I:" .. m end,
  warn  = function(m) mock.logs[#mock.logs+1] = "W:" .. m end,
  error = function(m) mock.logs[#mock.logs+1] = "E:" .. m end,
})
_G.time = freeze({
  now_ms = function() return mock.now_ms end,
  now_iso = function() return "2026-11-24T06:00:00Z" end,
  tz_offset_min = function() return -360 end,
  local_parts = function() return { year = 2026, month = 11, day = 24, hour = 5, min = 54, sec = 0, wday = 3, yday = 328, is_dst = false, tz_offset_min = -360 } end,
  format_discord = function(ms, style)
    if style == "R" then return "just now"
    elseif style == "f" then return "November 24, 2026 5:54 AM"
    else return "Today at 5:54 AM" end
  end,
  after = function(_, fn) fn(); return 1 end,
  every = function() error("polling time.every must not be used in v1.0.0!") end,
  cancel = function() return true end,
})
_G.async = freeze({
  spawn = function(fn, ...)
    local co = coroutine.create(fn)
    local ok, err = coroutine.resume(co, ...)
    if not ok then error(err) end
    return co
  end,
  sleep = function() end,
})
_G.json = freeze({
  encode = json_encode,
  decode = json_decode,
})
_G.crypto = freeze({
  uuid = function()
    mock.uuid_n = mock.uuid_n + 1
    return string.format("00000000-0000-4000-8000-%012d", mock.uuid_n)
  end,
})
_G.color = freeze({
  alpha = function(hex, a)
    local b = hex:sub(1, 7)
    local n = math.max(0, math.min(255, math.floor(a * 255 + 0.5)))
    return b .. string.format("%02x", n)
  end,
})
_G.clipboard = freeze({
  write = function(t) mock.clipboard = t end,
})

local storage_files = freeze({
  mkdir = function(rel)
    local full = resolve_jail_rel(rel)
    local ok = real_os.execute("mkdir -p " .. string.format("%q", full))
    return ok == true or ok == 0
  end,
  read = function(rel)
    local full = resolve_jail_rel(rel)
    local f, e = real_io.open(full, "rb")
    if not f then return nil, e end
    local d = f:read("*a"); f:close()
    assert(#d <= 16 * 1024 * 1024, "storage.files.read > 16 MiB")
    return d
  end,
  read_chunk = function(rel, off, len)
    local full = resolve_jail_rel(rel)
    local f, e = real_io.open(full, "rb")
    if not f then return nil, e end
    f:seek("set", off or 0)
    local d = f:read(math.min(len or 524288, 524288)) or ""
    local cur = f:seek()
    local total = f:seek("end")
    f:close()
    return d, cur >= total
  end,
  write = function(rel, data)
    local full = resolve_jail_rel(rel)
    local dir = full:match("^(.*)/[^/]+$")
    if dir then real_os.execute("mkdir -p " .. string.format("%q", dir)) end
    local f, e = real_io.open(full, "wb")
    if not f then return nil, e end
    f:write(data); f:close()
    return true
  end,
  append = function(rel, data)
    local full = resolve_jail_rel(rel)
    local dir = full:match("^(.*)/[^/]+$")
    if dir then real_os.execute("mkdir -p " .. string.format("%q", dir)) end
    local f, e = real_io.open(full, "ab")
    if not f then return nil, e end
    f:write(data); f:close()
    return true
  end,
  rename = function(src_rel, dst_rel)
    local src = resolve_jail_rel(src_rel)
    local dst = resolve_jail_rel(dst_rel)
    local dir = dst:match("^(.*)/[^/]+$")
    if dir then real_os.execute("mkdir -p " .. string.format("%q", dir)) end
    local ok, e = real_os.rename(src, dst)
    mock.rename_calls[#mock.rename_calls + 1] = { src = src_rel, dst = dst_rel, ok = ok ~= nil }
    return ok ~= nil, e
  end,
  remove = function(rel, recursive)
    local full = resolve_jail_rel(rel)
    if recursive == true or (type(recursive) == "table" and recursive.recursive) then
      local ok = real_os.execute("rm -rf " .. string.format("%q", full))
      return ok == true or ok == 0
    end
    local ok, e = real_os.remove(full)
    return ok ~= nil, e
  end,
  list = function(rel)
    local full = (rel and rel ~= "") and resolve_jail_rel(rel) or JAIL_ROOT
    local h = real_io.popen("ls -1 " .. string.format("%q", full) .. " 2>/dev/null")
    if not h then return {} end
    local out = {}
    for line in h:lines() do out[#out+1] = line end
    h:close()
    return out
  end,
  stat = function(rel)
    local full = (rel and rel ~= "") and resolve_jail_rel(rel) or JAIL_ROOT
    local f = real_io.open(full, "rb")
    if f then
      local sz = f:seek("end")
      f:close()
      if sz then
        return { size = sz, mtime = math.floor(mock.now_ms / 1000), is_dir = false, is_file = true }
      end
    end
    local is_d = real_os.execute("test -d " .. string.format("%q", full))
    if is_d == true or is_d == 0 then
      return { size = 0, mtime = math.floor(mock.now_ms / 1000), is_dir = true, is_file = false }
    end
    return nil, "not found"
  end,
  usage = function()
    local h = real_io.popen("find " .. string.format("%q", JAIL_ROOT) .. " -type f -printf '%s\\n' 2>/dev/null")
    local bytes, count = 0, 0
    if h then
      for line in h:lines() do
        bytes = bytes + (tonumber(line) or 0)
        count = count + 1
      end
      h:close()
    end
    return { used_bytes = bytes, file_count = count }
  end,
})

_G.storage = freeze({
  files = storage_files,
  get = function(k) return mock.kv["st:" .. k] end,
  set = function(k, v) mock.kv["st:" .. k] = v end,
  delete = function(k) mock.kv["st:" .. k] = nil end,
  keys = function() return {} end,
  clear = function() end,
})
_G.settings = freeze({
  schema = function(fields)
    mock.settings_schema = fields
    for _, f in ipairs(fields) do
      if f.key and f.default ~= nil and mock.kv["cfg:" .. f.key] == nil then
        mock.kv["cfg:" .. f.key] = f.default
      end
    end
    return true
  end,
  get = function(k, def)
    assert(def ~= nil or mock.kv["cfg:" .. k] ~= nil, "settings.get called without explicit default for " .. tostring(k))
    local v = mock.kv["cfg:" .. k]
    if v == nil then return def end
    return v
  end,
  set = function(k, v) mock.kv["cfg:" .. k] = v end,
  all = function() return {} end,
  on_change = function(fn) mock.settings_listeners[#mock.settings_listeners+1] = fn end,
  on_action = function(fn) mock.settings_action_listeners[#mock.settings_action_listeners+1] = fn end,
})
_G.events = freeze({
  on = function(name, fn)
    mock.event_listeners[name] = mock.event_listeners[name] or {}
    mock.event_listeners[name][#mock.event_listeners[name]+1] = fn
    return true
  end,
  off = function(name) mock.event_listeners[name] = nil end,
})
_G.commands = freeze({
  register = function(spec) mock.commands[spec.name] = spec end,
  unregister = function(name) mock.commands[name] = nil; return true end,
})
_G.keybinds = freeze({
  register = function(spec) mock.keybinds[spec.id] = spec; return true end,
  unregister = function(id) mock.keybinds[id] = nil; return true end,
})
_G.navigation = freeze({
  jump_to_message = function(cid, mid)
    mock.jump_calls[#mock.jump_calls + 1] = { channel_id = cid, message_id = mid }
    return true
  end,
  select_channel = function(cid, opts)
    mock.select_channel_calls[#mock.select_channel_calls + 1] = { channel_id = cid, opts = opts }
    return true
  end,
})
_G.store = freeze({
  self = function() return mock.self_user end,
  selected = function() return mock.selected end,
  guild = function(id) return mock.guilds[id] end,
  channel = function(id) return mock.channels[id] end,
  channels = function(gid)
    local out = {}
    for _, c in pairs(mock.channels) do
      if c.guild_id == gid then out[#out+1] = c end
    end
    return out
  end,
  messages = function(cid) return mock.store_msgs[cid] or {} end,
  message = function(cid, mid)
    for _, m in ipairs(mock.store_msgs[cid] or {}) do
      if m.id == mid then return m end
    end
    return nil
  end,
})
_G.messages = freeze({
  inject_local = function(cid, spec)
    assert(type(cid) == "string" and cid ~= "")
    assert(type(spec) == "table")
    if spec.attachments then
      for _, a in ipairs(spec.attachments) do
        if a.local_path then resolve_plugin_data_uri(a.local_path) end
      end
    end
    local existing_lid = spec.id and mock.local_msgs_by_id[spec.id]
    if existing_lid and mock.local_msgs[existing_lid] then
      mock.local_msgs[existing_lid] = { local_id = existing_lid, channel_id = cid, spec = spec }
      return existing_lid
    end
    local lid = mock.next_local_id
    mock.next_local_id = lid + 1
    mock.local_msgs[lid] = { local_id = lid, channel_id = cid, spec = spec }
    if spec.id then mock.local_msgs_by_id[spec.id] = lid end
    return lid
  end,
  update_local = function(id_or_lid, patch)
    local lid = type(id_or_lid) == "string" and mock.local_msgs_by_id[id_or_lid] or id_or_lid
    local rec = lid and mock.local_msgs[lid]
    if not rec then return false, "not found" end
    if patch.attachments then
      for _, a in ipairs(patch.attachments) do
        if a.local_path then resolve_plugin_data_uri(a.local_path) end
      end
    end
    for k, v in pairs(patch) do rec.spec[k] = v end
    mock.local_updates[#mock.local_updates+1] = { id = id_or_lid, patch = patch }
    return true
  end,
  dismiss_local = function(id_or_lid)
    local lid = type(id_or_lid) == "string" and mock.local_msgs_by_id[id_or_lid] or id_or_lid
    local rec = lid and mock.local_msgs[lid]
    if rec and rec.spec.id then mock.local_msgs_by_id[rec.spec.id] = nil end
    if lid then mock.local_msgs[lid] = nil end
    return true
  end,
  clear_local = function(cid)
    if cid == nil then
      mock.local_msgs = {}
      mock.local_msgs_by_id = {}
    else
      for lid, rec in pairs(mock.local_msgs) do
        if rec.channel_id == cid then
          if rec.spec.id then mock.local_msgs_by_id[rec.spec.id] = nil end
          mock.local_msgs[lid] = nil
        end
      end
    end
    return true
  end,
})
_G.ui = freeze({
  open_user_profile = function(uid, gid)
    mock.profile_open_calls[#mock.profile_open_calls + 1] = { user_id = uid, guild_id = gid }
    return true
  end,
  media = freeze({
    open = function(spec)
      if spec.items then
        for _, it in ipairs(spec.items) do
          if it.local_path then resolve_plugin_data_uri(it.local_path) end
        end
      elseif spec.local_path then
        resolve_plugin_data_uri(spec.local_path)
      end
      mock.media_open_calls[#mock.media_open_calls + 1] = spec
      return true
    end,
  }),
  menu = freeze({
    popup = function(spec)
      assert(type(spec.items) == "table" and #spec.items > 0)
      mock.popup_calls[#mock.popup_calls + 1] = spec
      return true
    end,
  }),
  contextMenu = freeze({
    add = function(spec) mock.menus[spec.id] = spec end,
    remove = function(id) mock.menus[id] = nil; mock.menu_states[id] = nil end,
    set_state = function(id, tid, state)
      mock.menu_states[id] = mock.menu_states[id] or {}
      mock.menu_states[id][tid or "*"] = state
      return true
    end,
    clear_state = function(id, tid)
      if tid == nil then mock.menu_states[id] = {}
      elseif mock.menu_states[id] then mock.menu_states[id][tid] = nil end
      return true
    end,
  }),
  actionButton = freeze({
    add = function(spec) mock.action_buttons[spec.id] = spec; return true end,
    remove = function(id) mock.action_buttons[id] = nil; return true end,
  }),
  dialog = freeze({
    confirm = function() return { accepted = mock.dialog_accept, value = mock.dialog_accept or nil } end,
  }),
  file = freeze({
    save = function(opts)
      mock.saved_files[#mock.saved_files + 1] = opts
      return { path = "/exported/" .. tostring(opts.suggested_name) }
    end,
  }),
  toast = freeze({
    show = function(text, level, opts)
      mock.toasts[#mock.toasts+1] = { text = text, level = level, opts = opts }
    end,
  }),
  panel = freeze({
    mount = function(spec)
      local enc = json_encode(spec.root)
      assert(#enc < 512 * 1024, "panel JSON too large")
      mock.panels[spec.id] = spec
      return true
    end,
    update = function(id, patch)
      assert(mock.panels[id], "update on unmounted panel: " .. id)
      if patch.root then
        local enc = json_encode(patch.root)
        assert(#enc < 512 * 1024, "panel update JSON too large")
        mock.panels[id].root = patch.root
      end
      return true
    end,
    patch = function(id, ops)
      assert(mock.panels[id], "patch on unmounted panel: " .. id)
      mock.panel_patches[#mock.panel_patches+1] = { id = id, ops = ops }
      return true
    end,
    unmount = function(id) mock.panels[id] = nil; return true end,
  }),
  texture = freeze({
    upload = function(k, bytes)
      assert(#bytes <= 640 * 1024, "texture > 640 KiB")
      mock.textures[k] = bytes
      return true
    end,
    upload_file = function(k, path, opts)
      local full = resolve_plugin_data_uri(path)
      local f = assert(real_io.open(full, "rb"), "upload_file missing path: " .. tostring(full))
      local d = f:read("*a"); f:close()
      assert(#d <= 32 * 1024 * 1024, "upload_file > 32 MiB")
      mock.textures[k] = { file = path, bytes = #d, opts = opts }
      mock.upload_file_calls[#mock.upload_file_calls+1] = { key = k, path = path, opts = opts }
      return { width = (opts and opts.max_w) or 512, height = (opts and opts.max_h) or 512 }
    end,
    evict = function(k) mock.textures[k] = nil; return true end,
    exists = function(k) return mock.textures[k] ~= nil end,
  }),
  decorate = freeze({
    message_badge = function(s) mock.decors[s.id] = s; return true end,
    message_accessory = function(s)
      if s.position ~= nil then
        assert(s.position == "above_body" or s.position == "below_body", "invalid accessory position: " .. tostring(s.position))
      end
      mock.decors[s.id] = s
      return true
    end,
    message_style = function(s) mock.decors[s.id] = s; return true end,
    channel_badge = function(s) mock.decors[s.id] = s; return true end,
    guild_badge = function(s) mock.decors[s.id] = s; return true end,
    remove = function(id) mock.decors[id] = nil; return true end,
    clear = function() mock.decors = {}; return true end,
  }),
})
_G.net = freeze({
  http = freeze({
    download = function(opts)
      check_allowed_host(opts.url)
      local full = resolve_plugin_data_uri(opts.dest_path)
      mock.download_calls[#mock.download_calls+1] = opts
      local data = mock.fake_cdn[opts.url]
      if not data then
        return { status = 404, ok = false, bytes = 0 }
      end
      if opts.max_bytes and #data > opts.max_bytes then
        return nil, "max_bytes exceeded"
      end
      local dir = full:match("^(.*)/[^/]+$")
      if dir then real_os.execute("mkdir -p " .. string.format("%q", dir)) end
      local f = assert(real_io.open(full, "wb"))
      f:write(data); f:close()
      return { status = 200, ok = true, bytes = #data, content_type = "application/octet-stream" }
    end,
    get = function(url, opts)
      check_allowed_host(url)
      mock.http_get_calls[#mock.http_get_calls+1] = { url = url, opts = opts }
      local data = mock.fake_cdn[url]
      if not data then
        return { status = 404, ok = false, body = "" }
      end
      assert(opts and opts.binary == true, "memory media fetch must pass binary=true!")
      return { status = 200, ok = true, body = data }
    end,
  }),
})

-- STRICTLY ZERO fs, ZERO system, ZERO gateway exposed!
_G.fs = nil; _G.system = nil; _G.gateway = nil
_G.os = nil; _G.io = nil; _G.package = nil; _G.debug = nil
_G.dofile = nil; _G.loadfile = nil; _G.load = nil
_G.print = nil; _G.warn = nil; _G.collectgarbage = nil

local function emit_event(name, payload)
  for _, fn in ipairs(mock.event_listeners[name] or {}) do fn(payload) end
end

local main_fn, lerr = real_loadfile(PLUGIN_DIR .. "/main.lua")
assert(main_fn, "Failed loading main.lua: " .. tostring(lerr))
main_fn()

local persistence = sandbox_require("src.persistence")
local whitelist = sandbox_require("src.whitelist")
local config = sandbox_require("src.config")
local media = sandbox_require("src.media")
local capture = sandbox_require("src.capture")

-- Test 1: Boot with ZERO fs/system/gateway, plugin.on_unload registered, visible_when & button schema verified
assert(config.get("storage_mode") == "disk")
assert(#mock.unload_cbs == 1, "plugin.on_unload must be registered")
local has_visible_when, has_maint_btn = false, false
for _, f in ipairs(mock.settings_schema) do
  if f.visible_when then has_visible_when = true end
  if f.type == "button" and f.key == "clear_all_logs_btn" then has_maint_btn = true end
end
assert(has_visible_when and has_maint_btn, "settings schema must use visible_when and type='button'")
-- Active channel auto-monitored, idle non-whitelisted channel ignored
local mon_act, rsn_act = whitelist.is_monitored("1000", "2000")
assert(mon_act == true and rsn_act == "active")
local mon_idle, rsn_idle = whitelist.is_monitored("1001", "2002")
assert(mon_idle == false and rsn_idle == "none")
emit_event("message.create", { id = "555001", channel_id = "2002", guild_id = "1001", author_id = "8009", author_name = "IdleUser", author_bot = false, content = "Idle msg", timestamp_ms = 1763959990000 })
emit_event("message.delete", { message_id = "555001", channel_id = "2002", guild_id = "1001", value = 1 })
assert(persistence.find_by_message("2002", "555001") == nil)
real_print("[PASS] 1. v1.0.0 boot (ZERO fs/system/gateway), on_unload, visible_when/buttons, and active vs idle monitoring verified")

-- Test 2: Dynamic context menus
mock.menus["ml-ch-toggle"].action({ channel_id = "2003", guild_id = "dm" })
assert(mock.menu_states["ml-ch-toggle"]["2003"].checked == true)
mock.menus["ml-guild-toggle"].action({ guild_id = "1000" })
mock.menus["ml-ch-exclude"].action({ channel_id = "2001", guild_id = "1000" })
assert(whitelist.is_monitored("1000", "2001") == false)
real_print("[PASS] 2. Dynamic context menus (set_state + resolve) verified")

-- Test 3: Native timeline deleted row + actionable Jump toast + messages.loaded + message.delete_bulk
config.set("toast_on_delete", true)
emit_event("message.delete", { guild_id = "1000", channel_id = "2000", message_id = "500001", value = 1 })
local lid_501 = mock.local_msgs_by_id["ml-del-500001"]
assert(lid_501 and mock.local_msgs[lid_501].spec.position == "timeline")
assert(mock.local_msgs[lid_501].spec.avatar_grayscale == true and mock.local_msgs[lid_501].spec.author_color == "#e5484d")
local last_toast = mock.toasts[#mock.toasts]
assert(last_toast and last_toast.opts and last_toast.opts.action_label == "Jump" and type(last_toast.opts.on_action) == "function")
last_toast.opts.on_action()
assert(#mock.jump_calls == 1 and mock.jump_calls[1].message_id == "500001", "toast Jump button must invoke navigation.jump_to_message")
config.set("toast_on_delete", false)

-- messages.loaded seeds prepended history + message.delete_bulk captures bulk deletes
mock.store_msgs["2000"][#mock.store_msgs["2000"] + 1] = {
  id = "500010", channel_id = "2000", guild_id = "1000", author_id = "8005", author_name = "Eve", author_bot = false,
  content = "Bulk target 1", timestamp_ms = 1763959800000, attachments = {}, embeds = {},
}
mock.store_msgs["2000"][#mock.store_msgs["2000"] + 1] = {
  id = "500011", channel_id = "2000", guild_id = "1000", author_id = "8005", author_name = "Eve", author_bot = false,
  content = "Bulk target 2", timestamp_ms = 1763959805000, attachments = {}, embeds = {},
}
emit_event("messages.loaded", { guild_id = "1000", channel_id = "2000", count = 3, is_prepend = true })
emit_event("message.delete_bulk", { guild_id = "1000", channel_id = "2000", message_ids = { "500010", "500011" } })
local b1 = persistence.find_by_message("2000", "500010")
local b2 = persistence.find_by_message("2000", "500011")
assert(b1 and b1.bulk_deleted == true and b2 and b2.bulk_deleted == true, "message.delete_bulk must capture bulk purges")
real_print("[PASS] 3. Timeline deleted row, actionable Jump toast, messages.loaded seeding, and message.delete_bulk verified")

-- Test 4: plugin_data:// precache -> atomic storage.files.rename -> media/ + update_local + upload_file + usage()
emit_event("message.create", {
  id = "600010", channel_id = "2003", guild_id = "dm",
  author_id = "8002", author_name = "Alice", author_bot = false,
  content = "Pic, video, and 900 KiB huge pic!", timestamp_ms = 1763960100000,
  attachments = {
    { id = "a1", filename = "cat.png", content_type = "image/png", url = "https://cdn.discordapp.com/attachments/100/200/cat.png", size = 32 },
    { id = "a2", filename = "clip.mp4", content_type = "video/mp4", url = "https://cdn.discordapp.com/attachments/100/201/clip.mp4", size = 8216 },
    { id = "a4", filename = "huge.png", content_type = "image/png", url = "https://cdn.discordapp.com/attachments/100/203/huge.png", size = 900 * 1024 + 8 },
  },
  embeds = {},
})
local orig_png = mock.fake_cdn["https://cdn.discordapp.com/attachments/100/200/cat.png"]
local orig_mp4 = mock.fake_cdn["https://cdn.discordapp.com/attachments/100/201/clip.mp4"]
local orig_huge = mock.fake_cdn["https://cdn.discordapp.com/attachments/100/203/huge.png"]
-- Purge CDN BEFORE delete to prove atomic storage.files.rename promotion from precache/ -> media/!
mock.fake_cdn["https://cdn.discordapp.com/attachments/100/200/cat.png"] = nil
mock.fake_cdn["https://cdn.discordapp.com/attachments/100/201/clip.mp4"] = nil
mock.fake_cdn["https://cdn.discordapp.com/attachments/100/203/huge.png"] = nil

emit_event("message.delete", { message_id = "600010", channel_id = "2003", guild_id = "dm", value = 1 })
local rec_m = persistence.find_by_message("2003", "600010")
assert(rec_m and rec_m.attachments[1].saved and rec_m.attachments[2].saved and rec_m.attachments[3].saved)
assert(#mock.rename_calls >= 3, "precache -> media promotion must use atomic storage.files.rename")
assert(rec_m.attachments[1].local_path:sub(1, 20) == "plugin_data://media/")
assert(storage.files.read(rec_m.attachments[1].rel_path) == orig_png)
assert(storage.files.read(rec_m.attachments[2].rel_path) == orig_mp4)
assert(storage.files.read(rec_m.attachments[3].rel_path) == orig_huge)
local lid_610 = mock.local_msgs_by_id["ml-del-600010"]
assert(lid_610 and mock.local_msgs[lid_610].spec.attachments[1].local_path == rec_m.attachments[1].local_path)
local huge_tex = media.ensure_preview_texture(rec_m.attachments[3])
assert(huge_tex ~= nil and #mock.upload_file_calls >= 1)
assert(persistence.stats().jail_used_bytes > 900 * 1024, "storage.files.usage must report real disk usage")
real_print("[PASS] 4. plugin_data:// precache -> atomic storage.files.rename -> media/, update_local, upload_file, and usage() verified")

-- Test 5: Panel UX — ui.media.open gallery lightbox, ui.open_user_profile, navigation.jump_to_message, and ui.menu.popup!
mock.action_buttons["msglog-header-btn"].action({})
local drawer = mock.panels["msglog-drawer"]
assert(drawer ~= nil)
-- Trigger lightbox view on attachment #2 (video) -> should open 3-item gallery focused on index 2!
drawer.on_event({ panel_id = "msglog-drawer", type = "click", id = "view_att:" .. rec_m.uid .. ":2" })
assert(#mock.media_open_calls == 1 and mock.media_open_calls[1].items and #mock.media_open_calls[1].items == 3 and mock.media_open_calls[1].index == 2)
assert(mock.media_open_calls[1].items[2].kind == "video" and mock.media_open_calls[1].items[2].local_path == rec_m.attachments[2].local_path)
-- Trigger author profile popout
drawer.on_event({ panel_id = "msglog-drawer", type = "click", id = "profile_rec:" .. rec_m.uid })
assert(#mock.profile_open_calls == 1 and mock.profile_open_calls[1].user_id == "8002")
-- Trigger Jump button
drawer.on_event({ panel_id = "msglog-drawer", type = "click", id = "jump_rec:" .. rec_m.uid })
assert(#mock.jump_calls == 2 and mock.jump_calls[2].message_id == "600010")
-- Trigger right-click card popup menu
drawer.on_event({ panel_id = "msglog-drawer", type = "right_click", id = "card:" .. rec_m.uid })
assert(#mock.popup_calls == 1 and #mock.popup_calls[1].items >= 4)
mock.popup_calls[1].on_select("copy")
assert(mock.clipboard == "Pic, video, and 900 KiB huge pic!")
real_print("[PASS] 5. Native ui.media.open lightbox gallery, ui.open_user_profile, jump_to_message, and ui.menu.popup verified")

-- Test 6: plugin.on_unload("quit"), orphan sweep, and persistent dismiss across reload
storage.files.write("media/orphan_stale.png", "stale")
storage.files.write("precache/temp_junk.png", "junk")
mock.unload_cbs[1]("quit")
assert(storage.files.stat("precache/temp_junk.png") == nil, "on_unload('quit') must wipe precache/")
local dm_lid = mock.local_msgs_by_id["ml-del-600010"]
mock.local_msgs[dm_lid].spec.on_event({ id = "ml-del-600010", local_id = dm_lid, type = "dismiss" })
messages.clear_local()
persistence.load()
media.cleanup_precache(true)
assert(storage.files.stat("media/orphan_stale.png") == nil, "startup sweep must remove unreferenced orphan in media/")
assert(storage.files.stat(rec_m.attachments[1].rel_path) ~= nil, "referenced media must remain intact")
emit_event("channel.select", { channel_id = "2003", guild_id = "dm" })
assert(mock.local_msgs_by_id["ml-del-600010"] == nil, "dismissed deleted row must stay hidden after reload")
assert(capture.restore_inline_record(persistence.find_by_message("2003", "600010")) == true)
assert(mock.local_msgs_by_id["ml-del-600010"] ~= nil)
real_print("[PASS] 6. plugin.on_unload, orphan sweep, persistent dismiss, and restore_inline_record verified")

-- Test 7: Pure-RAM Memory-Only mode (zero storage.files writes!)
mock.fake_cdn["https://cdn.discordapp.com/attachments/100/200/cat.png"] = orig_png
local disk_before = storage.files.read("events.jsonl")
mock.commands["msglog"].run("mode memory", { channel_id = "2000", guild_id = "1000" })
assert(config.get("storage_mode") == "memory")
emit_event("message.create", {
  id = "600099", channel_id = "2000", guild_id = "1000",
  author_id = "8004", author_name = "Dave", author_bot = false,
  content = "Pure RAM binary image", timestamp_ms = 1763960500000,
  attachments = { { id = "a99", filename = "cat.png", content_type = "image/png", url = "https://cdn.discordapp.com/attachments/100/200/cat.png", size = #orig_png } },
  embeds = {},
})
emit_event("message.delete", { message_id = "600099", channel_id = "2000", guild_id = "1000", value = 1 })
local rec_mem = persistence.find_by_message("2000", "600099")
assert(rec_mem and rec_mem.attachments[1].saved and rec_mem.attachments[1].storage == "memory")
assert(persistence.get_mem_media(rec_mem.attachments[1].mem_key) == orig_png)
assert(storage.files.read("events.jsonl") == disk_before, "memory mode must NOT touch plugin_data://events.jsonl")
persistence.load()
assert(#persistence.all_records() == 0, "memory mode clears cleanly on restart")
real_print("[PASS] 7. Pure-RAM Memory-Only mode (binary HTTP, zero disk writes, reboot clear) verified")

-- Test 8: Native inline above_body edit history + seamless 2-row deleted edited message layout!
mock.commands["msglog"].run("mode disk", { channel_id = "2000", guild_id = "1000" })
persistence.clear_all()
messages.clear_local()
ui.decorate.clear()

emit_event("message.create", {
  id = "710001", channel_id = "2000", guild_id = "1000",
  author_id = "8003", author_name = "Carol", author_bot = false,
  content = "First draft text", timestamp_ms = 1763961000000, attachments = {}, embeds = {},
})
emit_event("message.update", {
  id = "710001", channel_id = "2000", guild_id = "1000",
  author_id = "8003", author_name = "Carol", author_bot = false,
  content = "Second draft text", timestamp_ms = 1763961000000, edited = true, edited_ms = 1763961010000,
})
local acc = mock.decors["ml-ed-710001"]
assert(acc ~= nil, "edited message must attach in-message accessory ml-ed-710001")
assert(acc.position == "above_body" and acc.priority == 10, "accessory must use position='above_body' and priority=10")
assert(acc.root.bg == nil and acc.root.border_w == nil, "default inline edit style must have no card background or border box")
assert(mock.local_msgs_by_id["ml-ed-710001-1"] == nil and mock.local_msgs_by_id["ml-ed-710001"] == nil, "must NOT inject floating external local edit rows")
local k1 = next(mock.decors)
assert(k1 == "ml-ed-710001" and next(mock.decors, k1) == nil, "live edited message must have ONLY the above_body accessory (no extra style/badge decorators)")
local enc_acc1 = json_encode(acc.root)
assert(not enc_acc1:find("(edited)", 1, true), "former versions must NOT append redundant (edited)")
assert(enc_acc1:find('"text":"v1"', 1, true) and enc_acc1:find('"size":11', 1, true), "must render small v1 indicator")
assert(enc_acc1:find('"text":"First draft text"', 1, true), "must render former version text")
assert(enc_acc1:find('"type":"divider"', 1, true), "must render horizontal separator divider underneath former version")
assert(enc_acc1:find('"hover_color":"text_muted"', 1, true), "markdown must set explicit hover_color so hover never blanks text")
assert(not enc_acc1:find('"show_on_hover":true', 1, true), "dismiss button must not shift layout on hover")

-- Verify optional 'quote' style renders left hairline without bg box
config.set("edited_style", "quote")
assert(mock.decors["ml-ed-710001"].root.border_sides == "left" and mock.decors["ml-ed-710001"].root.bg == nil)
config.set("edited_style", "inline")

-- Edit #2: ordered v1 -> v2 inside the SAME in-message accessory, each separated by a divider!
emit_event("message.update", {
  id = "710001", channel_id = "2000", guild_id = "1000",
  author_id = "8003", author_name = "Carol", author_bot = false,
  content = "Final polished text", timestamp_ms = 1763961000000, edited = true, edited_ms = 1763961020000,
})
local acc2 = mock.decors["ml-ed-710001"]
local enc_acc2 = json_encode(acc2.root)
local p1 = enc_acc2:find('"text":"v1"', 1, true)
local p2 = enc_acc2:find('"text":"v2"', 1, true)
assert(p1 and p2 and p1 < p2, "ordered v1 must appear before v2 inside above_body accessory")
assert(#acc2.root.children == 4, "2 versions + 2 separator dividers = 4 children")
assert(acc2.root.children[2].type == "divider" and acc2.root.children[4].type == "divider")

-- Dismissing the in-message accessory via X button persists across reload!
acc2.on_event({ id = "dismiss", type = "click" }, "710001")
assert(mock.decors["ml-ed-710001"] == nil)
persistence.load()
emit_event("channel.select", { channel_id = "2000", guild_id = "1000" })
assert(mock.decors["ml-ed-710001"] == nil, "dismissed edit accessory must stay hidden after reload")

-- Restoring via panel 'Show' puts it back, and deleting the message keeps former versions ABOVE final deleted text in muted gray!
assert(capture.restore_inline_record(persistence.find_by_message("2000", "710001")) == true)
assert(mock.decors["ml-ed-710001"] ~= nil)
emit_event("message.delete", { message_id = "710001", channel_id = "2000", guild_id = "1000", value = 1 })
assert(mock.decors["ml-ed-710001"] == nil, "above_body edit accessory removed when message is deleted")
local hist_lid = mock.local_msgs_by_id["ml-del-710001-ed"]
local del_lid = mock.local_msgs_by_id["ml-del-710001"]
assert(hist_lid and del_lid, "deleted edited message must inject both history header row and red body row")
local hspec = mock.local_msgs[hist_lid].spec
local bspec = mock.local_msgs[del_lid].spec
assert(hspec.sort_id == "710001" and bspec.sort_id == "710001", "both rows share deleted snowflake sort_id")
assert(hspec.timestamp_ms < bspec.timestamp_ms, "former versions row MUST sort directly ABOVE final deleted text row")
assert(hspec.compact == "auto" and hspec.avatar_grayscale == true and hspec.author_color == "#e5484d" and hspec.badge == "DELETED")
assert(hspec.text_color == "text_muted", "former versions on deleted message must stay muted gray, NOT bright red")
assert(not hspec.content:find("(edited)", 1, true), "deleted former versions must not include redundant (edited)")
assert(hspec.content:find("*v1*  First draft text", 1, true) and hspec.content:find("*v2*  Second draft text", 1, true))
assert(hspec.content:find("────────────────────────", 1, true), "deleted former versions must include separator lines")
assert(bspec.compact == "always" and bspec.text_color == "#e5484d" and bspec.content == "Final polished text", "final deleted text stays below in red with compact='always'")

-- Dismissing the history sibling row dismisses BOTH rows together!
hspec.on_event({ id = "ml-del-710001-ed", local_id = hist_lid, type = "dismiss" })
assert(mock.local_msgs_by_id["ml-del-710001"] == nil, "dismissing history sibling must also dismiss final body row")
assert(capture.restore_inline_record(persistence.find_by_message("2000", "710001")) == true)
assert(mock.local_msgs_by_id["ml-del-710001-ed"] ~= nil and mock.local_msgs_by_id["ml-del-710001"] ~= nil)
real_print("[PASS] 8. Native inline above_body edit history + muted-above-red deleted edited message layout verified")

-- Test 9: Synchronous delete_record + anti-resurrection + Settings maintenance action buttons!
local rec_710 = persistence.find_by_message("2000", "710001")
assert(persistence.delete_record(rec_710.uid) == true)
capture.remove_inline_deleted(rec_710)
assert(mock.local_msgs_by_id["ml-del-710001"] == nil and mock.local_msgs_by_id["ml-del-710001-ed"] == nil, "remove_inline_deleted must remove both deleted sibling rows")
persistence.mark_updated(rec_710) -- racing update on deleted record must be ignored!
assert(storage.files.stat("events.jsonl") == nil, "deleting last record must synchronously remove events.jsonl")
messages.clear_local()
persistence.load()
assert(#persistence.all_records() == 0)

-- Settings Maintenance button: export_logs_btn & clear_all_logs_btn
mock.settings_action_listeners[1]("export_logs_btn")
assert(#mock.saved_files == 1 and mock.saved_files[1].suggested_name == "ccord-message-logs.json")
mock.settings_action_listeners[1]("clear_precache_btn")
mock.settings_action_listeners[1]("clear_all_logs_btn")
real_print("[PASS] 9. Synchronous deletion, anti-resurrection guard, and Settings maintenance buttons verified")

real_os.execute("rm -rf " .. string.format("%q", TEST_TMP))
real_print("\nALL v1.0.0 TEST SUITES PASSED!")
