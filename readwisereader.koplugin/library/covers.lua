-- Best-effort Reader cover handling. Covers stay out of article HTML and are
-- installed through KOReader's native custom-cover sidecar support.
local DocSettings = require("docsettings")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local http = require("socket.http")
local socket = require("socket")
local socketutil = require("socketutil")
local util = require("util")

local Covers = {}

local MAX_COVER_BYTES = 5 * 1024 * 1024
local FORMAT_BY_CONTENT_TYPE = {
    ["image/jpeg"] = "jpg",
    ["image/png"] = "png",
}

local function safeDocumentId(document_id)
    if type(document_id) ~= "string" or document_id == "" then
        return nil
    end
    return document_id:gsub("[^%w_-]", "_")
end

local function detectFormat(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end

    local header = file:read(8)
    file:close()

    if header and header:sub(1, 3) == "\255\216\255" then
        return "jpg"
    end
    if header == "\137PNG\r\n\26\n" then
        return "png"
    end
end

local function isUsableCache(path, expected_format)
    local attributes = lfs.attributes(path)
    if not attributes or attributes.mode ~= "file" or attributes.size < 8 then
        return false
    end
    return detectFormat(path) == expected_format
end

local function contentType(headers)
    local value = headers and headers["content-type"]
    if type(value) ~= "string" then
        return nil
    end
    local media_type = value:match("^%s*([^;]+)")
    return media_type and media_type:lower() or nil
end

local function downloadToFile(url, temporary_path)
    local file, open_err = io.open(temporary_path, "wb")
    if not file then
        return nil, "could not open temporary cover file: " .. tostring(open_err)
    end

    local bytes_written = 0
    local function sink(chunk, sink_err)
        if chunk then
            bytes_written = bytes_written + #chunk
            if bytes_written > MAX_COVER_BYTES then
                return nil, "cover exceeds 5 MB limit"
            end
            return file:write(chunk)
        end
        file:close()
        return 1
    end

    local request_ok, code, headers, status = pcall(function()
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        return socket.skip(1, http.request({
            url = url,
            method = "GET",
            headers = {
                ["User-Agent"] = "KOReader Readwise Reader Plugin",
                ["Accept"] = "image/jpeg,image/png;q=0.9,image/*;q=0.1",
            },
            redirect = true,
            sink = sink,
        }))
    end)
    socketutil:reset_timeout()
    pcall(function() file:close() end)

    if not request_ok then
        return nil, "network request error: " .. tostring(code)
    end
    if code ~= 200 then
        return nil, "HTTP " .. tostring(code or status or "network unreachable")
    end
    if bytes_written == 0 then
        return nil, "empty response"
    end
    return headers
end

local function applyCustomCover(document_path, cover_path)
    local custom_settings = DocSettings.openSettingsFile()
    local ok, result = pcall(function()
        return custom_settings:flushCustomCover(document_path, cover_path)
    end)
    if not ok then
        return nil, tostring(result)
    end
    if not result then
        return nil, "DocSettings returned false"
    end
    return true
end

-- options.cache_dir is a hidden per-library directory. options.cached_url is
-- the previously persisted image URL for this document, if any.
-- Returns a result table; callers must treat every failure as non-fatal.
function Covers.apply(document, document_path, options)
    options = options or {}
    local image_url = document and document.image_url
    if type(image_url) ~= "string" or image_url == "" then
        logger.dbg("ReadwiseReader:Covers: no image_url for document", document and document.id)
        return { status = "missing" }
    end
    if not image_url:match("^https://") then
        logger.warn("ReadwiseReader:Covers: unsupported non-HTTPS cover URL for", document.id)
        return { status = "unsupported_url" }
    end

    local document_id = safeDocumentId(document.id)
    if not document_id or type(document_path) ~= "string" or document_path == "" then
        logger.warn("ReadwiseReader:Covers: invalid document identity or path")
        return { status = "invalid_document" }
    end
    if type(options.cache_dir) ~= "string" or options.cache_dir == "" then
        logger.warn("ReadwiseReader:Covers: no cache directory for", document.id)
        return { status = "no_cache_dir" }
    end

    local cache_dir = options.cache_dir:gsub("/$", "")
    util.makePath(cache_dir)

    if options.cached_url == image_url then
        for _, extension in ipairs({ "jpg", "png" }) do
            local cached_path = cache_dir .. "/" .. document_id .. "." .. extension
            if isUsableCache(cached_path, extension) then
                logger.dbg("ReadwiseReader:Covers: cache hit for", document.id)
                local applied, apply_err = applyCustomCover(document_path, cached_path)
                if applied then
                    logger.dbg("ReadwiseReader:Covers: applied cached cover for", document.id)
                    return { status = "cache_hit", cache_url = image_url }
                end
                logger.warn("ReadwiseReader:Covers: failed to apply cached cover for", document.id, apply_err)
                return { status = "apply_failed", cache_url = image_url }
            end
        end
        logger.warn("ReadwiseReader:Covers: cached cover is missing or invalid for", document.id)
    end

    logger.dbg("ReadwiseReader:Covers: downloading cover for", document.id)
    local temporary_path = cache_dir .. "/." .. document_id .. ".cover.tmp"
    os.remove(temporary_path)
    local headers, download_err = downloadToFile(image_url, temporary_path)
    if not headers then
        os.remove(temporary_path)
        logger.warn("ReadwiseReader:Covers: cover download failed for", document.id, download_err)
        return { status = "download_failed" }
    end

    local expected_format = FORMAT_BY_CONTENT_TYPE[contentType(headers)]
    local actual_format = detectFormat(temporary_path)
    if not expected_format or actual_format ~= expected_format then
        os.remove(temporary_path)
        logger.warn("ReadwiseReader:Covers: unsupported or invalid cover format for", document.id,
            "content type:", contentType(headers), "detected:", actual_format)
        return { status = "unsupported_format" }
    end

    local cache_path = cache_dir .. "/" .. document_id .. "." .. actual_format
    local renamed, rename_err = os.rename(temporary_path, cache_path)
    if not renamed then
        os.remove(temporary_path)
        logger.warn("ReadwiseReader:Covers: could not cache cover for", document.id, rename_err)
        return { status = "cache_failed" }
    end
    logger.dbg("ReadwiseReader:Covers: cached cover for", document.id, "at", cache_path)

    local applied, apply_err = applyCustomCover(document_path, cache_path)
    if not applied then
        logger.warn("ReadwiseReader:Covers: failed to apply cover for", document.id, apply_err)
        return { status = "apply_failed", cache_url = image_url }
    end

    logger.dbg("ReadwiseReader:Covers: applied cover for", document.id)
    return { status = "downloaded", cache_url = image_url }
end

return Covers
