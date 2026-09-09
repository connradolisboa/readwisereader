-- Explicit links from a sideloaded local book to one Reader document.
--
-- A path is intentionally the key: a matching filename/title is only a search
-- hint, never an automatic association. Keeping the Reader fields here lets the
-- v2 highlight export reproduce the document identity without downloading its
-- HTML to the device.
local LocalLinks = {}

local function stringOrNil(value)
    return type(value) == "string" and value ~= "" and value or nil
end

function LocalLinks.normalizeReaderDocument(document)
    if type(document) ~= "table" then
        return nil
    end

    local id = stringOrNil(document.id)
    if not id then
        return nil
    end

    return {
        id = id,
        title = stringOrNil(document.title) or "Untitled",
        author = stringOrNil(document.author),
        source_url = stringOrNil(document.source_url),
        -- Fresh Reader metadata uses `url`; persisted links use `reader_url`.
        reader_url = stringOrNil(document.url) or stringOrNil(document.reader_url),
        category = stringOrNil(document.category),
        image_url = stringOrNil(document.image_url),
    }
end

function LocalLinks.set(links, filepath, document)
    if type(links) ~= "table" or type(filepath) ~= "string" or filepath == "" then
        return nil
    end
    local link = LocalLinks.normalizeReaderDocument(document)
    if not link then
        return nil
    end
    links[filepath] = link
    return link
end

function LocalLinks.get(links, filepath)
    if type(links) ~= "table" or type(filepath) ~= "string" or filepath == "" then
        return nil
    end
    return LocalLinks.normalizeReaderDocument(links[filepath])
end

function LocalLinks.remove(links, filepath)
    if type(links) ~= "table" or type(filepath) ~= "string" or filepath == "" then
        return false
    end
    if links[filepath] == nil then
        return false
    end
    links[filepath] = nil
    return true
end

return LocalLinks
