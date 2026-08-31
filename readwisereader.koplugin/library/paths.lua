-- Central Reader document-directory routing. Keep the legacy single directory
-- as the fallback so upgrading never moves or hides existing downloads.
local Paths = {}

local function normalize(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    return path:gsub("/+$", "") .. "/"
end

function Paths.getArticleDirectory(settings)
    return normalize(settings.article_directory) or normalize(settings.directory)
end

function Paths.getBookDirectory(settings)
    -- Deliberately fall back to articles: an upgrade keeps every document in the
    -- old folder until the user explicitly selects a separate book directory.
    return normalize(settings.book_directory) or Paths.getArticleDirectory(settings)
end

function Paths.getDocumentDirectory(document, settings)
    if document and document.category == "epub" then
        return Paths.getBookDirectory(settings)
    end
    return Paths.getArticleDirectory(settings)
end

function Paths.getAllDocumentDirectories(settings)
    local directories, seen = {}, {}
    for _, directory in ipairs({ Paths.getArticleDirectory(settings), Paths.getBookDirectory(settings) }) do
        if directory and not seen[directory] then
            seen[directory] = true
            table.insert(directories, directory)
        end
    end
    return directories
end

return Paths
