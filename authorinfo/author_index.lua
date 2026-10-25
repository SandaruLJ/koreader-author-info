-- The library's authors, read from CoverBrowser's book information cache
-- (the same metadata KOReader shows under each cover). A book with several
-- authors stores one name per line and is listed under each of them, as
-- KOReader's own "filter by author" does. Only books inside the home folder
-- that still exist are counted.
--
--   getBooks()                -> the library's books with their metadata
--   getAuthors(books, keep)   -> authors of the books keep() accepts

local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local M = {}

-- splitAuthors(s) -> names. One name per line; commas belong to a name
-- ("Le Guin, Ursula K."), so they never split.
function M.splitAuthors(authors)
    local result, seen = {}, {}
    if type(authors) ~= "string" then return result end
    for line in authors:gmatch("[^\n]+") do
        local name = line:match("^%s*(.-)%s*$")
        if name ~= "" and not seen[name] then
            seen[name] = true
            result[#result + 1] = name
        end
    end
    return result
end

local function home_prefix()
    local home = G_reader_settings and G_reader_settings:readSetting("home_dir")
    if type(home) ~= "string" or home == "" then return nil end
    return (home:gsub("/+$", "")) .. "/"
end

-- rows() -> { {path, authors, series, language, keywords}, ... } from the
-- cache; nil when CoverBrowser is not available.
local function rows()
    local ok, BookInfoManager = pcall(require, "bookinfomanager")
    if not ok or not BookInfoManager then return nil end
    BookInfoManager:openDbConnection()
    local conn = BookInfoManager.db_conn
    if not conn then return nil end
    local ok_exec, result = pcall(conn.exec, conn, [[
        SELECT directory, filename, authors, series, language, keywords
        FROM bookinfo
        WHERE in_progress = 0
          AND authors IS NOT NULL AND authors != ''
          AND (ignore_meta IS NULL OR ignore_meta != 'Y')
    ]])
    if not ok_exec then
        logger.warn("authors: book info query failed", result)
        return {}
    end
    local list = {}
    if type(result) == "table" and result[1] then
        for i = 1, #result[1] do
            list[#list + 1] = {
                path = result[1][i] .. result[2][i],
                authors = result[3][i],
                series = result[4][i],
                language = result[5][i],
                keywords = result[6][i],
            }
        end
    end
    return list
end

-- getBooks(source_rows) -> the books that exist inside the home folder, or
-- nil when the book information cache is unavailable. source_rows is for
-- specs.
function M.getBooks(source_rows)
    local list = source_rows or rows()
    if not list then return nil end
    local prefix = home_prefix()
    local books = {}
    for _i, row in ipairs(list) do
        if (not prefix or row.path:sub(1, #prefix) == prefix)
                and lfs.attributes(row.path, "mode") == "file" then
            books[#books + 1] = row
        end
    end
    return books
end

-- getAuthors(books, keep) -> { { name, files = {paths} }, ... } sorted by
-- name, listing only the books keep(book) accepts (all when keep is nil).
function M.getAuthors(books, keep)
    local by_name, names = {}, {}
    for _i, book in ipairs(books or {}) do
        if not keep or keep(book) then
            for _j, name in ipairs(M.splitAuthors(book.authors)) do
                if not by_name[name] then
                    by_name[name] = {}
                    names[#names + 1] = name
                end
                table.insert(by_name[name], book.path)
            end
        end
    end
    table.sort(names, function(a, b) return ffiUtil.strcoll(a, b) end)
    local authors = {}
    for _i, name in ipairs(names) do
        authors[#authors + 1] = { name = name, files = by_name[name] }
    end
    return authors
end

return M
