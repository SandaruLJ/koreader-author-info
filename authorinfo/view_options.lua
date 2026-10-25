-- The Authors view's sort order and filters, remembered between visits the
-- way KOReader remembers a collection's (saved as they change, no "save view"
-- step).
--
-- Filters, which all must match:
--   language, keywords -- one value each; an author is listed when any of
--                         their books has it, with only those books.
--   country, genre     -- one value each, from the author's information
--                         (author_info); all their books are listed.
--   status             -- a set; an author is listed when any chosen status
--                         applies:
--     new, reading     -- has a book with that status (only those listed)
--     read             -- has a finished book (only finished ones listed)
--     unread           -- has no finished book at all (all books listed)

local ffiUtil = require("ffi/util")
local _ = require("gettext")
local T = ffiUtil.template

local AuthorIndex = require("authorinfo/author_index")

local M = {}

local SETTINGS_KEY = "author_info_view"

M.STATUSES = { "new", "reading", "unread", "read" }
M.PROPS = { "language", "keywords" }
M.AUTHOR_PROPS = { "country", "genre" }
-- Where an author property's values are in author_info's records.
local AUTHOR_FIELDS = { country = "countries", genre = "genres" }

local function known(list)
    local set = {}
    for _i, value in ipairs(list) do set[value] = true end
    return set
end
local KNOWN_STATUSES = known(M.STATUSES)

-- load() -> { sort, reverse, filter }, dropping anything no longer offered
-- (an older sort or filter saved before it was removed).
function M.load()
    local saved = G_reader_settings:readSetting(SETTINGS_KEY)
    saved = type(saved) == "table" and saved or {}
    local filter = {}
    local saved_filter = type(saved.filter) == "table" and saved.filter or {}
    if type(saved_filter.status) == "table" then
        for status in pairs(saved_filter.status) do
            if KNOWN_STATUSES[status] then
                filter.status = filter.status or {}
                filter.status[status] = true
            end
        end
    end
    for _i, prop in ipairs(M.PROPS) do
        if type(saved_filter[prop]) == "string" then filter[prop] = saved_filter[prop] end
    end
    for _i, prop in ipairs(M.AUTHOR_PROPS) do
        if type(saved_filter[prop]) == "string" then filter[prop] = saved_filter[prop] end
    end
    return {
        sort = M.SORTS[saved.sort] and saved.sort or "name",
        reverse = saved.reverse == true,
        filter = filter,
    }
end

function M.save(options)
    G_reader_settings:saveSetting(SETTINGS_KEY, {
        sort = options.sort,
        reverse = options.reverse or nil,
        filter = next(options.filter) and options.filter or nil,
    })
end

-- ---------------------------------------------------------------------
-- Filters
-- ---------------------------------------------------------------------

-- propValues(book, prop) -> the values a book has for a metadata field.
-- Keywords may hold several, one per line; languages compare in lower case,
-- as Collections does.
function M.propValues(book, prop)
    local value = book[prop]
    if type(value) ~= "string" or value == "" then return {} end
    if prop == "language" then return { value:lower() } end
    local values = {}
    for line in value:gmatch("[^\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" then values[#values + 1] = line end
    end
    return values
end

local function props_matcher(filter)
    local any = false
    for _i, prop in ipairs(M.PROPS) do
        if filter[prop] then any = true end
    end
    if not any then return nil end
    return function(book)
        for _i, prop in ipairs(M.PROPS) do
            local wanted = filter[prop]
            if wanted then
                local found = false
                for _j, value in ipairs(M.propValues(book, prop)) do
                    if value == wanted then found = true; break end
                end
                if not found then return false end
            end
        end
        return true
    end
end

local function book_status(path)
    return require("ui/widget/booklist").getBookStatus(path)
end

-- authorValues(info, prop) -> an author's values for country or genre.
function M.authorValues(info, prop)
    local values = type(info) == "table" and info[AUTHOR_FIELDS[prop]]
    return type(values) == "table" and values or {}
end

local function has_value(info, prop, wanted)
    for _i, value in ipairs(M.authorValues(info, prop)) do
        if value == wanted then return true end
    end
    return false
end

-- filterAuthors(books, filter, statusOf, infoOf) -> the authors to show,
-- each with the books to list for them. statusOf(path) -> "new" | "reading" |
-- "abandoned" | "complete" and infoOf(name) -> author_info record are for
-- specs.
function M.filterAuthors(books, filter, statusOf, infoOf)
    filter = filter or {}
    local authors = AuthorIndex.getAuthors(books, props_matcher(filter))
    if filter.country or filter.genre then
        infoOf = infoOf or require("authorinfo/author_info").load
        local kept = {}
        for _i, author in ipairs(authors) do
            local info = infoOf(author.name)
            if (not filter.country or has_value(info, "country", filter.country))
                    and (not filter.genre or has_value(info, "genre", filter.genre)) then
                kept[#kept + 1] = author
            end
        end
        authors = kept
    end
    local wanted = filter.status
    if not wanted then return authors end

    statusOf = statusOf or book_status
    local statuses = {}
    local function status(path)
        if not statuses[path] then statuses[path] = statusOf(path) end
        return statuses[path]
    end
    -- "Unread" asks about all of an author's books, whatever else is filtered.
    local has_read = {}
    if wanted.unread then
        for _i, book in ipairs(books) do
            if status(book.path) == "complete" then
                for _j, name in ipairs(AuthorIndex.splitAuthors(book.authors)) do
                    has_read[name] = true
                end
            end
        end
    end

    local result = {}
    for _i, author in ipairs(authors) do
        local files
        if wanted.unread and not has_read[author.name] then
            files = author.files
        else
            files = {}
            for _j, file in ipairs(author.files) do
                local s = status(file)
                if (wanted.new and s == "new") or (wanted.reading and s == "reading")
                        or (wanted.read and s == "complete") then
                    files[#files + 1] = file
                end
            end
        end
        if #files > 0 then result[#result + 1] = { name = author.name, files = files } end
    end
    return result
end

-- authorValueCounts(authors, prop, infoOf) -> { {value, count}, ... }: the
-- countries or genres of the given authors, counting authors.
function M.authorValueCounts(authors, prop, infoOf)
    infoOf = infoOf or require("authorinfo/author_info").load
    local counts, values = {}, {}
    for _i, author in ipairs(authors) do
        for _j, value in ipairs(M.authorValues(infoOf(author.name), prop)) do
            if not counts[value] then values[#values + 1] = value end
            counts[value] = (counts[value] or 0) + 1
        end
    end
    table.sort(values, function(a, b) return ffiUtil.strcoll(a, b) end)
    local result = {}
    for _i, value in ipairs(values) do result[#result + 1] = { value = value, count = counts[value] } end
    return result
end

-- keptBooks(books, filter, statusOf, infoOf) -> the books the shown authors
-- list: where the value lists for further filters come from.
function M.keptBooks(books, filter, statusOf, infoOf)
    local kept = {}
    for _i, author in ipairs(M.filterAuthors(books, filter, statusOf, infoOf)) do
        for _j, file in ipairs(author.files) do kept[file] = true end
    end
    local result = {}
    for _i, book in ipairs(books) do
        if kept[book.path] then result[#result + 1] = book end
    end
    return result
end

-- valueCounts(books, prop) -> { {value, count}, ... } sorted by value: the
-- choices offered when filtering by prop.
function M.valueCounts(books, prop)
    local counts, values = {}, {}
    for _i, book in ipairs(books) do
        for _j, value in ipairs(M.propValues(book, prop)) do
            if not counts[value] then values[#values + 1] = value end
            counts[value] = (counts[value] or 0) + 1
        end
    end
    table.sort(values, function(a, b) return ffiUtil.strcoll(a, b) end)
    local result = {}
    for _i, value in ipairs(values) do result[#result + 1] = { value = value, count = counts[value] } end
    return result
end

function M.propText(prop)
    return ({
        language = _("Language"),
        keywords = _("Keywords"),
        country = _("Country"),
        genre = _("Genre"),
    })[prop]
end

function M.statusText(status)
    return ({
        new = _("New"),
        reading = _("Reading"),
        unread = _("Unread"),
        read = _("Read"),
    })[status]
end

-- describe(filter) -> a short summary for the view's subtitle, or nil.
function M.describe(filter)
    if not filter or next(filter) == nil then return nil end
    local parts = {}
    if filter.status then
        local names = {}
        for _i, status in ipairs(M.STATUSES) do
            if filter.status[status] then names[#names + 1] = M.statusText(status) end
        end
        parts[#parts + 1] = table.concat(names, ", ")
    end
    for _i, prop in ipairs(M.AUTHOR_PROPS) do
        if filter[prop] then parts[#parts + 1] = T("%1: %2", M.propText(prop), filter[prop]) end
    end
    for _i, prop in ipairs(M.PROPS) do
        if filter[prop] then parts[#parts + 1] = T("%1: %2", M.propText(prop), filter[prop]) end
    end
    return table.concat(parts, " · ")
end

-- toggleStatus(filter, status): the status filter is a set of choices.
function M.toggleStatus(filter, status)
    filter.status = filter.status or {}
    filter.status[status] = not filter.status[status] or nil
    if next(filter.status) == nil then filter.status = nil end
end

-- ---------------------------------------------------------------------
-- Sorting
-- ---------------------------------------------------------------------

-- Words that belong to the surname when they come right before it
-- ("Le Guin", "de la Mare", "van Beethoven"), compared in lower case.
local PARTICLES = {}
for _i, word in ipairs({
    "da", "das", "de", "dei", "del", "della", "der", "des", "di", "do", "dos", "du",
    "la", "le", "les", "lo", "van", "von", "ten", "ter", "zu", "st.", "san", "bin", "ibn",
    "al", "el", "mac", "af", "av",
}) do PARTICLES[word] = true end

-- Words after the surname that are not part of it ("King Jr.").
local SUFFIXES = {}
for _i, word in ipairs({ "jr", "jr.", "sr", "sr.", "ii", "iii", "iv", "phd", "md" }) do
    SUFFIXES[word] = true
end

-- surname(name) -> the part to sort a name by:
--   "Le Guin, Ursula K."     -> "Le Guin"      (comma: what comes before it)
--   "Ursula K. Le Guin"      -> "Le Guin"      (particles join the last word)
--   "Martin Luther King Jr." -> "King"         (suffixes are skipped)
--   "Van Morrison"           -> "Morrison"     (a first word is a given name)
-- Conventions differ between languages; this follows the common English one.
function M.surname(name)
    local last, rest = name:match("^([^,]+),%s*(.-)%s*$")
    if last and not SUFFIXES[rest:lower()] then return last:match("^%s*(.-)%s*$") end
    local words = {}
    for word in name:gmatch("%S+") do words[#words + 1] = word end
    local stop = #words
    while stop > 1 and SUFFIXES[words[stop]:lower():gsub(",$", "")] do stop = stop - 1 end
    if stop < 1 then return name end
    local start = stop
    while start > 2 and PARTICLES[words[start - 1]:lower()] do start = start - 1 end
    return (table.concat(words, " ", start, stop):gsub(",+$", ""))
end

-- Each sort orders the authors list ({name, files}); "reverse" flips it.
M.SORTS = {
    name = {
        text = _("Name"),
        order = 1,
        less = function(a, b) return ffiUtil.strcoll(a.name, b.name) end,
    },
    last_name = {
        text = _("Last name"),
        order = 2,
        -- Filled in by sort(): the family name from the author's information
        -- when it has a trustworthy one, else surname().
        less = nil,
    },
    books = {
        text = _("Number of books"),
        order = 3,
        -- Most books first; ties by name.
        less = function(a, b)
            if #a.files ~= #b.files then return #a.files > #b.files end
            return ffiUtil.strcoll(a.name, b.name)
        end,
    },
    recent = {
        text = _("Recently read"),
        order = 4,
        -- Filled in by sort(): the latest time any of the author's books was read.
        less = nil,
    },
}

local function last_read_times()
    local times = {}
    local ok, ReadHistory = pcall(require, "readhistory")
    for _i, entry in ipairs(ok and ReadHistory.hist or {}) do
        if entry.file and (times[entry.file] or 0) < (entry.time or 0) then
            times[entry.file] = entry.time
        end
    end
    return times
end

-- sortName(name, info) -> what the Last name sort compares, in lower case.
function M.sortName(name, info)
    local family = info and require("authorinfo/author_info").familyName(info, name)
    return (family or M.surname(name)):lower()
end

-- sort(authors, options, read_times, infoOf) sorts in place. read_times
-- (file -> time) and infoOf (name -> author_info record) are for specs.
function M.sort(authors, options, read_times, infoOf)
    local less = M.SORTS[options.sort] and M.SORTS[options.sort].less
    if options.sort == "last_name" then
        infoOf = infoOf or require("authorinfo/author_info").load
        local key = {}
        for _i, author in ipairs(authors) do key[author] = M.sortName(author.name, infoOf(author.name)) end
        less = function(a, b)
            if key[a] ~= key[b] then return ffiUtil.strcoll(key[a], key[b]) end
            return ffiUtil.strcoll(a.name, b.name)
        end
    elseif options.sort == "recent" then
        read_times = read_times or last_read_times()
        local latest = {}
        for _i, author in ipairs(authors) do
            local t = 0
            for _j, file in ipairs(author.files) do t = math.max(t, read_times[file] or 0) end
            latest[author] = t
        end
        less = function(a, b)
            if latest[a] ~= latest[b] then return latest[a] > latest[b] end
            return ffiUtil.strcoll(a.name, b.name)
        end
    end
    less = less or M.SORTS.name.less
    if options.reverse then
        local forward = less
        less = function(a, b) return forward(b, a) end
    end
    table.sort(authors, less)
    return authors
end

return M
