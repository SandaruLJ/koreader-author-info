-- Time spent reading an author's books, from KOReader's Statistics plugin.
--
--   seconds(files, opts) -> the total time in seconds, or nil when there is
--                           none (Statistics off, or none of the books read)
--
-- Books are matched as Statistics matches them: by the fingerprint
-- (partial_md5_checksum) KOReader saves in a book's sidecar the first time it
-- is opened, never recomputed, so the time survives the file being edited
-- outside KOReader. A book with no sidecar has never been opened. Summing by
-- fingerprint alone also counts every row Statistics keeps for a book (it
-- starts a new one when the title or authors change). Statistics stores a
-- book's total when it is closed or the device sleeps.
--
-- The database is opened read-only, and closed before returning.

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local M = {}

local function db_path()
    return require("datastorage"):getSettingsDir() .. "/statistics.sqlite3"
end

-- The fingerprint KOReader saved for a book, or nil when it was never opened.
local function saved_md5(file)
    local DocSettings = require("docsettings")
    local sidecar = DocSettings:findSidecarFile(file)
    return sidecar and DocSettings.openSettingsFile(sidecar):readSetting("partial_md5_checksum") or nil
end

-- opts (for specs): db = the database path, md5 = function(file) -> fingerprint.
function M.seconds(files, opts)
    opts = opts or {}
    local db = opts.db or db_path()
    if lfs.attributes(db, "mode") ~= "file" then return nil end
    local md5_of = opts.md5 or saved_md5
    local md5s, seen = {}, {}
    for _i, file in ipairs(files or {}) do
        local ok, md5 = pcall(md5_of, file)
        if ok and type(md5) == "string" and not seen[md5] then
            seen[md5] = true
            md5s[#md5s + 1] = md5
        end
    end
    if #md5s == 0 then return nil end
    local SQ3 = require("lua-ljsqlite3/init")
    local ok_open, conn = pcall(SQ3.open, db, "ro")
    if not ok_open then
        logger.warn("AuthorInfo: couldn't open the statistics database:", conn)
        return nil
    end
    local ok, total = pcall(function()
        local marks = string.rep("?", #md5s, ", ")
        local stmt = conn:prepare("SELECT sum(total_read_time) FROM book WHERE md5 IN (" .. marks .. ");")
        local row = stmt:reset():bind(unpack(md5s)):step()
        stmt:close()
        return row and tonumber(row[1])
    end)
    conn:close()
    if not ok then
        logger.warn("AuthorInfo: couldn't read the statistics database:", total)
        return nil
    end
    return total and total > 0 and total or nil
end

return M
