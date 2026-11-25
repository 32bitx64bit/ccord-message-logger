-- Cross-platform binary image & video media archiver (v1.0.0: Linux, macOS, Windows, Android).
-- Uses Class 2 storage.files (plugin_data:// URIs) + net.http.download (up to 256 MiB, zero Lua heap),
-- atomic storage.files.rename (precache -> media promotion), net.http.get({ binary = true }) (RAM mode),
-- and ui.texture.upload_file (up to 32 MiB host-side thumbnails, 64-entry LRU).

local util = require("src.util")
local config = require("src.config")
local persistence = require("src.persistence")

local M = {}

local MAX_CONCURRENT_JOBS = 3
local MAX_MEM_TEXTURE_BYTES = 640 * 1024
local MAX_UPLOAD_FILE_BYTES = 32 * 1024 * 1024
local MAX_PREVIEW_TEXTURES = 64
local MAX_RAM_PRECACHE_BYTES = 8 * 1024 * 1024
local MAX_DISK_DOWNLOAD_CAP = 256 * 1024 * 1024
local MAX_EXPORT_BYTES = 32 * 1024 * 1024

local active_jobs = 0
local job_queue = {}

-- Pre-cache tracking (unpromoted files currently in plugin_data://precache/ or RAM)
local disk_precache = {}       -- key -> { rel, size, added_at }
local disk_precache_order = {}
local disk_precache_bytes = 0

local ram_precache = {}        -- key -> { bytes, size, added_at }
local ram_precache_order = {}
local ram_precache_bytes = 0

-- In-flight pre-cache downloads: key -> { waiters = { fn... } }
local inflight = {}

-- Uploaded GPU texture LRU for image previews
local tex_loaded = {}
local tex_order = {}

local function sfiles()
  return storage and storage.files or nil
end

local function file_exists(rel)
  local sf = sfiles()
  if not (sf and sf.stat and type(rel) == "string" and rel ~= "") then return false end
  local ok, st = pcall(sf.stat, rel)
  return ok and type(st) == "table"
end

local function max_ram_single_file()
  if platform and platform.is_android then
    return 4 * 1024 * 1024
  end
  return 8 * 1024 * 1024
end

local function make_key(message_id, att_id, idx)
  local mid = util.sanitize_filename(tostring(message_id or "msg"), "msg")
  local aid = util.sanitize_filename(tostring(att_id or idx or "0"), "0")
  return mid .. "_" .. aid
end

function M.should_archive(att)
  if not config.get("save_media") then return false end
  if type(att) ~= "table" then return false end
  local kind = att.media_kind or util.classify_attachment(att)
  if kind == "image" then return config.get("save_images") == true end
  if kind == "video" then return config.get("save_videos") == true end
  return config.get("save_other_files") == true
end

local function pump_queue()
  while active_jobs < MAX_CONCURRENT_JOBS and #job_queue > 0 do
    local job = table.remove(job_queue, 1)
    active_jobs = active_jobs + 1
    async.spawn(function()
      local ok, err = pcall(job)
      if not ok then
        util.safe_log("error", "media job failed: " .. tostring(err))
      end
      active_jobs = math.max(0, active_jobs - 1)
      pump_queue()
    end)
  end
end

local function enqueue(fn)
  job_queue[#job_queue + 1] = fn
  pump_queue()
end

-- Runs inside async.spawn coroutine: streams directly to plugin_data://<rel> via net.http.download
local function download_to_disk_sync(url, rel_dest, max_bytes)
  if not util.is_safe_https_url(url) then
    return false, "unsupported URL scheme"
  end
  if not (net and net.http and net.http.download) then
    return false, "net.http.download unavailable"
  end

  local dest_uri = util.plugin_data_uri(rel_dest)
  if not dest_uri then return false, "invalid destination path" end

  local cap = math.min(max_bytes, MAX_DISK_DOWNLOAD_CAP)
  local res, err = net.http.download({
    url = url,
    dest_path = dest_uri,
    max_bytes = cap,
    timeout_ms = 60000,
    follow_redirects = true,
  })

  if not res then
    return false, tostring(err or "download failed")
  end
  if not res.ok or (tonumber(res.bytes) or 0) <= 0 then
    return false, string.format("HTTP %s (CDN may have purged)", tostring(res.status or "error"))
  end
  return true, tonumber(res.bytes) or 0
end

-- Runs inside async.spawn coroutine: fetches raw binary bytes strictly in RAM via net.http.get({ binary = true })
local function download_to_ram_sync(url, max_bytes)
  if not util.is_safe_https_url(url) then
    return nil, "unsupported URL scheme"
  end
  if not (net and net.http and net.http.get) then
    return nil, "net.http.get unavailable"
  end

  local cap = math.min(max_bytes, max_ram_single_file())
  local resp, err = net.http.get(url, {
    binary = true,
    follow_redirects = true,
    max_bytes = cap,
    timeout_ms = 30000,
  })

  if not resp then
    return nil, tostring(err or "download failed")
  end
  if not resp.ok or type(resp.body) ~= "string" or #resp.body == 0 then
    return nil, string.format("HTTP %s (CDN may have purged)", tostring(resp.status or "error"))
  end
  return resp.body, nil
end

local function evict_disk_precache(max_bytes)
  local sf = sfiles()
  while disk_precache_bytes > max_bytes and #disk_precache_order > 0 do
    local old_k = table.remove(disk_precache_order, 1)
    local item = disk_precache[old_k]
    if item then
      disk_precache[old_k] = nil
      disk_precache_bytes = math.max(0, disk_precache_bytes - (item.size or 0))
      if sf and sf.remove and item.rel then
        pcall(sf.remove, item.rel)
      end
    end
  end
end

local function evict_ram_precache(max_bytes)
  while ram_precache_bytes > max_bytes and #ram_precache_order > 0 do
    local old_k = table.remove(ram_precache_order, 1)
    local item = ram_precache[old_k]
    if item then
      ram_precache[old_k] = nil
      ram_precache_bytes = math.max(0, ram_precache_bytes - (item.size or 0))
    end
  end
end

-- Enforce max_media_total_mb quota on permanently archived files inside plugin_data://media/
function M.enforce_disk_quota()
  if not config.is_disk_mode() then return end
  local sf = sfiles()
  if not (sf and sf.list and sf.stat and sf.remove) then return end

  local quota_bytes = math.max(25, math.floor(tonumber(config.get("max_media_total_mb")) or 250)) * 1024 * 1024
  local p = persistence.paths()
  local entries = sf.list(p.media)
  if type(entries) ~= "table" or #entries == 0 then return end

  local files = {}
  local total = 0
  for i = 1, #entries do
    local name = entries[i]
    if type(name) == "string" and name ~= "" and name:sub(1, 1) ~= "." then
      local rel = p.media .. "/" .. name
      local st = sf.stat(rel)
      if st and st.is_file then
        total = total + (st.size or 0)
        files[#files + 1] = { rel = rel, size = st.size or 0, mtime = st.mtime or 0 }
      end
    end
  end

  if total <= quota_bytes then return end
  table.sort(files, function(a, b) return a.mtime < b.mtime end)

  local removed_rels = {}
  for i = 1, #files do
    if total <= quota_bytes then break end
    local ok = sf.remove(files[i].rel)
    if ok then
      total = math.max(0, total - files[i].size)
      removed_rels[files[i].rel] = true
    end
  end

  if next(removed_rels) ~= nil then
    local recs = persistence.all_records()
    local touched = false
    for i = 1, #recs do
      local atts = recs[i].attachments
      if type(atts) == "table" then
        for j = 1, #atts do
          local a = atts[j]
          local rel = a and (a.rel_path or util.strip_plugin_data_uri(a.local_path))
          if a and rel and removed_rels[rel] then
            a.saved = false
            a.status = "pruned"
            a.save_error = "Pruned by media disk quota"
            touched = true
          end
        end
      end
    end
    if touched then
      persistence.compact_now()
    end
  end
end

-- Clear temporary pre-cache files (disk + RAM) and optionally sweep unreferenced orphans in media/
function M.cleanup_precache(sweep_media_orphans)
  disk_precache = {}
  disk_precache_order = {}
  disk_precache_bytes = 0
  ram_precache = {}
  ram_precache_order = {}
  ram_precache_bytes = 0

  if not config.is_disk_mode() then return end
  local sf = sfiles()
  if not sf then return end

  local p = persistence.paths()

  -- Wipe temporary precache/ folder cleanly and recreate it
  if file_exists(p.precache) and sf.remove then
    pcall(sf.remove, p.precache, true)
  end
  if sf.mkdir then
    pcall(sf.mkdir, p.precache)
  end

  if sweep_media_orphans == false then return end

  -- Sweep any orphaned files in media/ not referenced by persisted records
  if sf.list and sf.remove and file_exists(p.media) then
    local referenced = {}
    local recs = persistence.all_records()
    for i = 1, #recs do
      local atts = recs[i].attachments
      if type(atts) == "table" then
        for j = 1, #atts do
          local a = atts[j]
          local rel = a and (a.rel_path or util.strip_plugin_data_uri(a.local_path))
          if a and a.saved and rel then
            referenced[rel] = true
          end
        end
      end
    end

    local entries = sf.list(p.media)
    if type(entries) == "table" then
      for i = 1, #entries do
        local name = entries[i]
        if type(name) == "string" and name ~= "" and name:sub(1, 1) ~= "." then
          local rel = p.media .. "/" .. name
          if not referenced[rel] then
            pcall(sf.remove, rel)
          end
        end
      end
    end
  end
end

-- Pre-cache attachments from a newly received message into plugin_data://precache/ (or RAM)
function M.precache_message(msg)
  if not config.get("save_media") then return end
  if config.get("media_capture_mode") ~= "precache" then return end
  if type(msg) ~= "table" or type(msg.attachments) ~= "table" or #msg.attachments == 0 then return end

  local max_single_bytes = math.max(1, math.floor(tonumber(config.get("max_media_mb")) or 25)) * 1024 * 1024
  local max_precache_bytes = math.max(10, math.floor(tonumber(config.get("max_precache_mb")) or 100)) * 1024 * 1024
  local ram_single_cap = max_ram_single_file()

  for i = 1, #msg.attachments do
    local att = msg.attachments[i]
    if M.should_archive(att) then
      local key = make_key(msg.id, att.id, i)
      local known_size = tonumber(att.size) or 0
      local is_disk = config.is_disk_mode()
      local cap_bytes = is_disk and math.min(max_single_bytes, MAX_DISK_DOWNLOAD_CAP) or math.min(max_single_bytes, ram_single_cap)
      local skip = (known_size > 0 and known_size > cap_bytes)

      if not skip and not disk_precache[key] and not ram_precache[key] and not inflight[key] then
        local safe_name = util.sanitize_filename(att.filename, "media_" .. key)
        local job_state = { waiters = {} }
        inflight[key] = job_state

        enqueue(function()
          local ok_res = false
          if is_disk then
            local ok_dir = persistence.ensure_disk_dirs()
            if ok_dir then
              local p = persistence.paths()
              local rel_target = p.precache .. "/" .. key .. "_" .. safe_name
              local dl_ok, size = download_to_disk_sync(att.url, rel_target, cap_bytes)
              if dl_ok then
                disk_precache[key] = { rel = rel_target, size = size, added_at = time and time.now_ms() or 0 }
                disk_precache_order[#disk_precache_order + 1] = key
                disk_precache_bytes = disk_precache_bytes + size
                evict_disk_precache(max_precache_bytes)
                ok_res = true
              end
            end
          else
            local bytes = download_to_ram_sync(att.url, cap_bytes)
            if bytes and #bytes > 0 then
              ram_precache[key] = { bytes = bytes, size = #bytes, added_at = time and time.now_ms() or 0 }
              ram_precache_order[#ram_precache_order + 1] = key
              ram_precache_bytes = ram_precache_bytes + #bytes
              evict_ram_precache(MAX_RAM_PRECACHE_BYTES)
              ok_res = true
            end
          end

          inflight[key] = nil
          for w = 1, #job_state.waiters do
            pcall(job_state.waiters[w], ok_res)
          end
        end)
      end
    end
  end
end

-- Archive all eligible image/video/file attachments for a logged record.
function M.archive_for_record(record, on_progress)
  if type(record) ~= "table" or type(record.attachments) ~= "table" or #record.attachments == 0 then
    return
  end
  if not config.get("save_media") then return end

  local max_single_bytes = math.max(1, math.floor(tonumber(config.get("max_media_mb")) or 25)) * 1024 * 1024
  local is_disk = config.is_disk_mode()
  local ram_single_cap = max_ram_single_file()

  for i = 1, #record.attachments do
    local att = record.attachments[i]
    if M.should_archive(att) and not att.saved then
      local key = make_key(record.message_id, att.id, i)
      local known_size = tonumber(att.size) or 0
      local cap_bytes = is_disk and math.min(max_single_bytes, MAX_DISK_DOWNLOAD_CAP) or math.min(max_single_bytes, ram_single_cap)

      if known_size > 0 and known_size > cap_bytes then
        att.saved = false
        att.status = "skipped"
        att.save_error = "Exceeds max size (" .. util.format_bytes(cap_bytes) .. ")"
        persistence.mark_updated(record)
        if on_progress then pcall(on_progress, record, att) end
      else
        att.status = "archiving"
        att.save_error = nil

        local function do_archive()
          enqueue(function()
            -- Abort if the log record was removed/cleared before this async job ran
            if not persistence.find_by_uid(record.uid) then return end
            local safe_name = util.sanitize_filename(att.filename, "media_" .. key)

            if config.is_disk_mode() then
              local sf = sfiles()
              local ok_dir, derr = persistence.ensure_disk_dirs()
              if not ok_dir or not sf then
                att.saved = false
                att.status = "error"
                att.save_error = tostring(derr or "plugin storage unavailable")
                persistence.mark_updated(record)
                if on_progress then pcall(on_progress, record, att) end
                return
              end

              local p = persistence.paths()
              local dst_rel = p.media .. "/" .. key .. "_" .. safe_name
              local dst_uri = util.plugin_data_uri(dst_rel)

              -- 1. O(1) atomic rename promotion from plugin_data://precache/ -> plugin_data://media/
              local cached = disk_precache[key]
              if cached and cached.rel and file_exists(cached.rel) then
                disk_precache[key] = nil
                disk_precache_bytes = math.max(0, disk_precache_bytes - (cached.size or 0))
                local rok = sf.rename and sf.rename(cached.rel, dst_rel)
                if rok then
                  att.saved = true
                  att.storage = "disk"
                  att.rel_path = dst_rel
                  att.local_path = dst_uri
                  att.saved_bytes = cached.size or att.size or 0
                  att.status = "saved"
                  att.save_error = nil
                  persistence.mark_updated(record)
                  M.enforce_disk_quota()
                  if on_progress then pcall(on_progress, record, att) end
                  return
                end
              end

              -- 2. Promote from RAM pre-cache if mode was just switched to disk
              local rcached = ram_precache[key]
              if rcached and rcached.bytes and sf.write then
                ram_precache[key] = nil
                ram_precache_bytes = math.max(0, ram_precache_bytes - (rcached.size or 0))
                local wok = sf.write(dst_rel, rcached.bytes)
                if wok then
                  att.saved = true
                  att.storage = "disk"
                  att.rel_path = dst_rel
                  att.local_path = dst_uri
                  att.saved_bytes = #rcached.bytes
                  att.status = "saved"
                  att.save_error = nil
                  persistence.mark_updated(record)
                  M.enforce_disk_quota()
                  if on_progress then pcall(on_progress, record, att) end
                  return
                end
              end

              -- 3. Stream directly to plugin_data://media/ via net.http.download (zero Lua heap overhead)
              local dl_ok, size_or_err = download_to_disk_sync(att.url, dst_rel, math.min(max_single_bytes, MAX_DISK_DOWNLOAD_CAP))
              if not persistence.find_by_uid(record.uid) then
                if dl_ok and sf.remove then pcall(sf.remove, dst_rel) end
                return
              end
              if dl_ok then
                att.saved = true
                att.storage = "disk"
                att.rel_path = dst_rel
                att.local_path = dst_uri
                att.saved_bytes = size_or_err
                att.status = "saved"
                att.save_error = nil
                persistence.mark_updated(record)
                M.enforce_disk_quota()
              else
                att.saved = false
                att.storage = "none"
                att.status = "error"
                att.save_error = util.truncate(tostring(size_or_err or "download failed"), 120)
                persistence.mark_updated(record)
              end
              if on_progress then pcall(on_progress, record, att) end
            else
              -- Memory-Only Mode: raw binary bytes fetched strictly in RAM (zero disk writes)
              local bytes, dl_err = nil, nil
              local rcached = ram_precache[key]
              if rcached and rcached.bytes then
                ram_precache[key] = nil
                ram_precache_bytes = math.max(0, ram_precache_bytes - (rcached.size or 0))
                bytes = rcached.bytes
              else
                bytes, dl_err = download_to_ram_sync(att.url, cap_bytes)
              end
              if not persistence.find_by_uid(record.uid) then return end

              if bytes and #bytes > 0 then
                local pok, perr = persistence.put_mem_media(key, bytes)
                if pok then
                  att.saved = true
                  att.storage = "memory"
                  att.mem_key = key
                  att.saved_bytes = #bytes
                  att.status = "saved"
                  att.save_error = nil
                else
                  att.saved = false
                  att.storage = "none"
                  att.status = "error"
                  att.save_error = tostring(perr or "memory cap reached")
                end
              else
                att.saved = false
                att.storage = "none"
                att.status = "error"
                att.save_error = util.truncate(tostring(dl_err or "download failed"), 120)
              end
              persistence.mark_updated(record)
              if on_progress then pcall(on_progress, record, att) end
            end
          end)
        end

        if inflight[key] then
          inflight[key].waiters[#inflight[key].waiters + 1] = function()
            do_archive()
          end
        else
          do_archive()
        end
      end
    end
  end
end

function M.read_attachment_bytes(att)
  if type(att) ~= "table" or not att.saved then return nil, "attachment not archived" end
  if att.storage == "memory" and att.mem_key then
    local b = persistence.get_mem_media(att.mem_key)
    if b then return b end
    return nil, "memory media evicted"
  end
  local rel = att.rel_path or util.strip_plugin_data_uri(att.local_path)
  if att.storage == "disk" and rel then
    local sf = sfiles()
    if not sf then return nil, "storage.files unavailable" end
    local data, rerr = sf.read(rel)
    if data ~= nil then return data end
    -- Stream chunked for files > 16 MiB (up to 32 MiB Save-As safety cap)
    if sf.read_chunk then
      local parts, total = {}, 0
      while true do
        local chunk, eof_or_err = sf.read_chunk(rel, total, 524288)
        if not chunk then return nil, tostring(eof_or_err or rerr or "read failed") end
        if #chunk > 0 then
          total = total + #chunk
          if total > MAX_EXPORT_BYTES then
            return nil, "File exceeds 32 MiB Save-As buffer; open in media viewer instead"
          end
          parts[#parts + 1] = chunk
        end
        if eof_or_err == true or #chunk == 0 then break end
      end
      return table.concat(parts)
    end
    return nil, rerr
  end
  return nil, "no stored media source"
end

local function track_texture(tex_key)
  while #tex_order >= MAX_PREVIEW_TEXTURES do
    local old = table.remove(tex_order, 1)
    tex_loaded[old] = nil
    pcall(ui.texture.evict, old)
  end
  tex_loaded[tex_key] = true
  tex_order[#tex_order + 1] = tex_key
end

function M.ensure_preview_texture(att, opts)
  if type(att) ~= "table" or not att.saved then return nil end
  if not (ui and ui.texture) then return nil end

  opts = opts or {}
  local grayscale = opts.grayscale == true
  local suffix = grayscale and "_gs" or ""
  local tex_key = "ml_img_" .. util.sanitize_filename(tostring(att.id or att.mem_key or att.filename or "0"), "0") .. suffix
  if tex_loaded[tex_key] then
    return tex_key
  end

  -- Disk mode: host-side ui.texture.upload_file directly from plugin_data:// (PNG/JPEG/WebP/GIF up to 32 MiB!)
  local uri = att.local_path or util.plugin_data_uri(att.rel_path)
  if att.storage == "disk" and uri and ui.texture.upload_file then
    if not util.is_previewable_image(att, true) then return nil end
    local sz = tonumber(att.saved_bytes) or tonumber(att.size) or 0
    if sz > MAX_UPLOAD_FILE_BYTES then return nil end
    local ok, dims = pcall(ui.texture.upload_file, tex_key, uri, {
      max_w = opts.max_w or 512,
      max_h = opts.max_h or 512,
      grayscale = grayscale,
    })
    if ok and dims then
      track_texture(tex_key)
      return tex_key
    end
  end

  -- Memory mode (or fallback): ui.texture.upload for PNG/JPEG/WebP <= 640 KiB
  if not util.is_previewable_image(att, false) then return nil end
  if not ui.texture.upload then return nil end
  local sz = tonumber(att.saved_bytes) or tonumber(att.size) or 0
  if sz > MAX_MEM_TEXTURE_BYTES then return nil end

  local bytes = M.read_attachment_bytes(att)
  if not bytes or #bytes == 0 or #bytes > MAX_MEM_TEXTURE_BYTES then
    return nil
  end

  local ok = pcall(ui.texture.upload, tex_key, bytes)
  if ok then
    track_texture(tex_key)
    return tex_key
  end
  return nil
end

function M.clear_preview_textures()
  if not (ui and ui.texture and ui.texture.evict) then return end
  for i = 1, #tex_order do
    pcall(ui.texture.evict, tex_order[i])
  end
  tex_loaded = {}
  tex_order = {}
end

return M
