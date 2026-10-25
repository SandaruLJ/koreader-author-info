-- What we know about an author besides their photo: a short bio, their
-- country, birth and death years, given and family names, genres and notable
-- works. Saved as <data dir>/authorinfo/<author>.json, beside their photo
-- (author_images), one file per author,
-- so each lookup (a forked child) writes only its own file.
--
-- Sources, starting from the same Open Library match and Wikipedia page the
-- photo lookup uses (author_images; shared through opts.session):
--   1. Open Library's author record: its bio, dates, and Wikidata id.
--   2. Without a Wikidata id there, the writer's Wikipedia page's one.
--   3. Wikidata: names, country of citizenship, dates, genres, notable works,
--      and the title of the author's Wikipedia page, with labels in KOReader's
--      language where Wikidata has them.
--   4. The bio: the summary (first paragraph) of that Wikipedia page in
--      KOReader's language, else in English, else Open Library's bio.

local Http = require("authorinfo/http")
local lfs = require("libs/libkoreader-lfs")
local json = require("json")
local logger = require("logger")

local AuthorImages = require("authorinfo/author_images")

local M = {}

M.VERSION = 1

local OL_HOST = "openlibrary.org"
local WD_HOST = "www.wikidata.org"
local WD_API = "https://www.wikidata.org/w/api.php?action=wbgetentities&format=json"
local JSON_HEADERS = { ["Accept"] = "application/json" }

-- Wikidata properties we keep.
local P = {
    given = "P735",
    family = "P734",
    country = "P27",
    born = "P569",
    died = "P570",
    genres = "P136",
    works = "P800",
}
-- Historical states, as Wikidata gives an older author's citizenship, and the
-- country they are now ("United Kingdom of Great Britain and Ireland" ->
-- "United Kingdom"), so a country filter finds everyone. Only where the
-- successor is unambiguous: not the Soviet Union, Russian Empire or Prussia.
local COUNTRY_SUCCESSORS = {
    Q174193 = "Q145", -- United Kingdom of Great Britain and Ireland
    Q161885 = "Q145", -- Kingdom of Great Britain
    Q43287 = "Q183",  -- German Empire
    Q41304 = "Q183",  -- Weimar Republic
    Q7318 = "Q183",   -- Nazi Germany
    Q713750 = "Q183", -- West Germany
    Q16957 = "Q183",  -- East Germany
    Q172579 = "Q38",  -- Kingdom of Italy
    Q207272 = "Q36",  -- Second Polish Republic
    Q211274 = "Q36",  -- Polish People's Republic
    Q29999 = "Q55",   -- Kingdom of the Netherlands
    Q70972 = "Q142",  -- Kingdom of France
    Q58296 = "Q142",  -- French First Republic
    Q71084 = "Q142",  -- First French Empire
    Q71092 = "Q142",  -- Second French Empire
    Q70802 = "Q142",  -- French Third Republic
    Q69829 = "Q142",  -- French Fourth Republic
    Q31747 = "Q27",   -- Irish Free State
}
M.COUNTRY_SUCCESSORS = COUNTRY_SUCCESSORS

local MAX_GENRES = 5
local MAX_WORKS = 8
-- An Open Library bio is cut at a sentence end after this many characters.
local MAX_BIO_CHARS = 1200

-- ---------------------------------------------------------------------
-- Storage
-- ---------------------------------------------------------------------

local dir_override

function M.dir()
    if dir_override then return dir_override end
    return require("datastorage"):getDataDir() .. "/authorinfo"
end

-- For specs: point the store somewhere disposable.
function M._setDir(dir)
    dir_override = dir
    M.invalidate()
end

function M.path(name)
    local stem = AuthorImages.fileStem(name)
    return stem and (M.dir() .. "/" .. stem .. ".json") or nil
end

-- Decoded files, by path, kept while the file is unchanged.
local cache = {}

function M.invalidate()
    cache = {}
end

-- load(name) -> the saved information, or nil.
function M.load(name)
    local path = type(name) == "string" and M.path(name)
    if not path then return nil end
    local modification = lfs.attributes(path, "modification")
    if not modification then return nil end
    local cached = cache[path]
    if cached and cached.modification == modification then return cached.info end
    local file = io.open(path, "rb")
    if not file then return nil end
    local text = file:read("*a")
    file:close()
    local ok, info = pcall(json.decode, text)
    info = ok and type(info) == "table" and info or nil
    cache[path] = { modification = modification, info = info }
    return info
end

function M.has(name)
    return M.load(name) ~= nil
end

-- missing(names) -> the names worth looking up: not a placeholder, nothing saved.
function M.missing(names)
    local result = {}
    for _i, name in ipairs(names or {}) do
        if type(name) == "string" and not AuthorImages.isPlaceholder(name) and not M.has(name) then
            result[#result + 1] = name
        end
    end
    return result
end

local function ensure_dir(dir)
    if lfs.attributes(dir, "mode") == "directory" then return true end
    local parent = dir:match("^(.*)/[^/]+$")
    if parent and parent ~= "" and lfs.attributes(parent, "mode") ~= "directory" then
        ensure_dir(parent)
    end
    lfs.mkdir(dir)
    return lfs.attributes(dir, "mode") == "directory"
end

local function save(name, info)
    local path = M.path(name)
    if not path or not ensure_dir(M.dir()) then return false end
    local tmp = path .. ".tmp"
    local file = io.open(tmp, "wb")
    if not file then return false end
    file:write(json.encode(info))
    file:close()
    if not os.rename(tmp, path) then
        os.remove(tmp)
        return false
    end
    cache[path] = nil
    return true
end

-- ---------------------------------------------------------------------
-- Parsing
-- ---------------------------------------------------------------------

-- uiLanguage() -> the Wikipedia language code for KOReader's language ("en",
-- "de", "pt" for pt_BR...).
function M.uiLanguage()
    local language = G_reader_settings and G_reader_settings:readSetting("language") or "en"
    local code = tostring(language):match("^(%a%a%a?)") or "en"
    return code:lower()
end

-- openLibraryBio(record) -> a plain-text bio or nil. Open Library bios are
-- Markdown-ish: links, footnote references, and sometimes long.
function M.openLibraryBio(record)
    local bio = type(record) == "table" and record.bio
    if type(bio) == "table" then bio = bio.value end
    if type(bio) ~= "string" then return nil end
    bio = bio:gsub("\r", "")
    bio = bio:gsub("\n%s*%[%d+%]:[^\n]*", "")          -- "[1]: https://..." lines
    bio = bio:gsub("%(%[[^%]]*%]%[%d+%]%)", "")         -- "([Source][1])"
    bio = bio:gsub("%[([^%]]+)%]%b()", "%1")            -- "[text](url)" -> text
    bio = bio:gsub("%[([^%]]+)%]%[%d+%]", "%1")         -- "[text][1]" -> text
    bio = bio:gsub("[ \t]+", " "):gsub("\n%s*\n+", "\n\n"):match("^%s*(.-)%s*$")
    if #bio < 40 then return nil end -- "Chinese author." says nothing more than the name
    if #bio > MAX_BIO_CHARS then
        local cut = bio:sub(1, MAX_BIO_CHARS):match("^(.*[%.!?])%s")
        bio = (cut or bio:sub(1, MAX_BIO_CHARS)) .. " …"
    end
    return bio
end

-- year(text) -> "1929" from Wikidata's "+1929-10-21T00:00:00Z" or Open
-- Library's "21 October 1929"; nil for none or for dates before year 1.
function M.year(text)
    if type(text) ~= "string" or text:match("^%-") then return nil end
    local y = text:match("(%d%d%d%d)")
    return y and tostring(tonumber(y)) or nil
end

-- statements(entity, property) -> its values in Wikidata's order, preferred
-- ones only when any are marked preferred, deprecated ones never.
local function statements(entity, property)
    local claims = type(entity) == "table" and type(entity.claims) == "table"
        and entity.claims[property]
    if type(claims) ~= "table" then return {} end
    local preferred, normal = {}, {}
    for _i, claim in ipairs(claims) do
        local snak = type(claim) == "table" and claim.mainsnak
        local value = type(snak) == "table" and type(snak.datavalue) == "table" and snak.datavalue.value
        if value ~= nil and claim.rank ~= "deprecated" then
            local list = claim.rank == "preferred" and preferred or normal
            list[#list + 1] = value
        end
    end
    return #preferred > 0 and preferred or normal
end

local function item_ids(entity, property, limit)
    local ids = {}
    for _i, value in ipairs(statements(entity, property)) do
        if type(value) == "table" and type(value.id) == "string" and value.id:match("^Q%d+$") then
            ids[#ids + 1] = value.id
            if limit and #ids >= limit then break end
        end
    end
    return ids
end

local function time_year(entity, property)
    local value = statements(entity, property)[1]
    return type(value) == "table" and M.year(value.time) or nil
end

-- label(entity, languages) -> its label in the first language it has.
-- "mul" holds labels that are the same in all languages (most names).
local function label(entity, languages)
    local labels = type(entity) == "table" and entity.labels
    if type(labels) ~= "table" then return nil end
    for _i, language in ipairs(languages) do
        local l = labels[language]
        if type(l) == "table" and type(l.value) == "string" and l.value ~= "" then return l.value end
    end
    return nil
end

local function escape(s)
    return (s:gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

-- answered(data, err): a server replied at all, even with an error status.
local function answered(data, err)
    return data ~= nil or (type(err) == "table" and err.status ~= nil)
end

-- ---------------------------------------------------------------------
-- Choosing what to show
-- ---------------------------------------------------------------------

-- familyName(info, name) -> the family name to sort by, or nil. Wikidata may
-- list several (a birth and a married name); the one the shown name contains
-- is taken, the latest in it when several are ("Ursula K. Le Guin": Le Guin,
-- not Kroeber). One the name does not contain is not trusted.
function M.familyName(info, name)
    local families = type(info) == "table" and info.family
    if type(families) ~= "table" or type(name) ~= "string" then return nil end
    local lower = name:lower()
    local best, best_at
    for _i, family in ipairs(families) do
        if type(family) == "string" and family ~= "" then
            local at
            local from = 1
            while true do
                local s = lower:find(family:lower(), from, true)
                if not s then break end
                at, from = s, s + 1
            end
            if at and (not best_at or at > best_at) then best, best_at = family, at end
        end
    end
    return best
end

-- sourcesText(info) -> where the information came from ("Wikipedia (en),
-- Wikidata"), or nil.
function M.sourcesText(info)
    if type(info) ~= "table" then return nil end
    local _ = require("gettext")
    local T = require("ffi/util").template
    local sources = {}
    if info.bio_source == "wikipedia" then
        sources[#sources + 1] = info.wikipedia and info.wikipedia.lang
            and T(_("Wikipedia (%1)"), info.wikipedia.lang) or _("Wikipedia")
    elseif info.bio_source == "openlibrary" then
        sources[#sources + 1] = _("Open Library")
    end
    if info.wikidata then sources[#sources + 1] = _("Wikidata") end
    return #sources > 0 and table.concat(sources, ", ") or nil
end

-- ---------------------------------------------------------------------
-- Network
-- ---------------------------------------------------------------------

local function get(url, host, transport, state)
    local data, err = Http.getJson(url, host, JSON_HEADERS, transport)
    state.answered = state.answered or answered(data, err)
    return type(data) == "table" and data or nil
end

local function wikidata_entity(id, languages, transport, state)
    local sites = {}
    for _i, language in ipairs(languages) do
        if language ~= "mul" then sites[#sites + 1] = language .. "wiki" end
    end
    local data = get(WD_API .. "&props=claims%7Csitelinks&ids=" .. escape(id)
        .. "&sitefilter=" .. escape(table.concat(sites, "|")), WD_HOST, transport, state)
    local entity = data and type(data.entities) == "table" and data.entities[id]
    return type(entity) == "table" and not entity.missing and entity or nil
end

-- labels(ids, languages) -> id -> label, in batches of 50 as the API allows.
local function wikidata_labels(ids, languages, transport, state)
    local result = {}
    for start = 1, #ids, 50 do
        local batch = {}
        for i = start, math.min(#ids, start + 49) do batch[#batch + 1] = ids[i] end
        local data = get(WD_API .. "&props=labels&languages=" .. escape(table.concat(languages, "|"))
            .. "&ids=" .. escape(table.concat(batch, "|")), WD_HOST, transport, state)
        for id, entity in pairs(data and type(data.entities) == "table" and data.entities or {}) do
            result[id] = label(entity, languages)
        end
    end
    return result
end

local function wikipedia_summary(language, title, transport, state)
    if not language:match("^[a-z][a-z]?[a-z]?$") or type(title) ~= "string" then return nil end
    local host = language .. ".wikipedia.org"
    local data = get("https://" .. host .. "/api/rest_v1/page/summary/"
        .. escape(title:gsub(" ", "_")), host, transport, state)
    local extract = data and data.type ~= "disambiguation" and data.extract
    if type(extract) ~= "string" then return nil end
    extract = extract:match("^%s*(.-)%s*$")
    return extract ~= "" and extract or nil
end

-- fetch(name, opts) -> info | nil, reason. Looks the author up and saves what
-- was found, replacing anything saved before.
--   opts.session   -- shared with author_images.fetch for the same author
--   opts.language  -- Wikipedia/Wikidata language (default KOReader's)
--   opts.transport -- stubs the network (specs)
--   reason: "placeholder", "bad name", "none" (asked, nothing found),
--           "unreachable" (no source answered), "no storage"
function M.fetch(name, opts)
    opts = opts or {}
    if AuthorImages.isPlaceholder(name) then return nil, "placeholder" end
    if not M.path(name) then return nil, "bad name" end
    local transport, session = opts.transport, opts.session or {}
    local state = { answered = false }
    local language = opts.language or M.uiLanguage()
    local languages = language == "en" and { "en", "mul" } or { language, "en", "mul" }
    local info = { version = M.VERSION, name = name, fetched = os.time() }

    -- 1. Open Library.
    local doc, ol_answered = AuthorImages.searchOpenLibrary(name, transport, session)
    state.answered = state.answered or ol_answered
    local olid = AuthorImages.openLibraryId(doc)
    local record
    if olid then
        info.openlibrary = olid
        record = get("https://" .. OL_HOST .. "/authors/" .. olid .. ".json", OL_HOST, transport, state)
    end
    local wikidata_id = record and type(record.remote_ids) == "table" and record.remote_ids.wikidata

    -- 2. Wikipedia's page for the Wikidata id when Open Library has none.
    if type(wikidata_id) ~= "string" or not wikidata_id:match("^Q%d+$") then
        local page, wp_answered = AuthorImages.findWikipediaPage(name, transport, session)
        state.answered = state.answered or wp_answered
        wikidata_id = page and type(page.pageprops) == "table" and page.pageprops.wikibase_item
        if page then info.wikipedia = { lang = "en", title = page.title } end
    end
    if type(wikidata_id) ~= "string" or not wikidata_id:match("^Q%d+$") then wikidata_id = nil end

    -- 3. Wikidata.
    local entity = wikidata_id and wikidata_entity(wikidata_id, languages, transport, state)
    if entity then
        info.wikidata = wikidata_id
        info.born = time_year(entity, P.born)
        info.died = time_year(entity, P.died)
        local wanted = {
            given = item_ids(entity, P.given),
            family = item_ids(entity, P.family),
            countries = {},
            genres = item_ids(entity, P.genres, MAX_GENRES),
            works = item_ids(entity, P.works, MAX_WORKS),
        }
        local seen_country = {}
        for _i, id in ipairs(item_ids(entity, P.country)) do
            id = COUNTRY_SUCCESSORS[id] or id
            if not seen_country[id] then
                seen_country[id] = true
                table.insert(wanted.countries, id)
            end
        end
        local all = {}
        for _field, ids in pairs(wanted) do
            for _i, id in ipairs(ids) do all[#all + 1] = id end
        end
        local labels = #all > 0 and wikidata_labels(all, languages, transport, state) or {}
        for field, ids in pairs(wanted) do
            local values, seen = {}, {}
            for _i, id in ipairs(ids) do
                local value = labels[id]
                if value and not seen[value] then
                    seen[value] = true
                    values[#values + 1] = value
                end
            end
            if #values > 0 then info[field] = values end
        end
        local sitelinks = type(entity.sitelinks) == "table" and entity.sitelinks or {}
        for _i, l in ipairs(languages) do
            local link = sitelinks[l .. "wiki"]
            if type(link) == "table" and type(link.title) == "string" then
                info.wikipedia = { lang = l, title = link.title }
                break
            end
        end
    end
    if record then
        info.born = info.born or M.year(record.birth_date)
        info.died = info.died or M.year(record.death_date)
    end

    -- 4. The bio.
    if info.wikipedia then
        info.bio = wikipedia_summary(info.wikipedia.lang, info.wikipedia.title, transport, state)
        if not info.bio and info.wikipedia.lang ~= "en" and entity then
            local link = type(entity.sitelinks) == "table" and entity.sitelinks.enwiki
            if type(link) == "table" and link.title then
                info.wikipedia = { lang = "en", title = link.title }
                info.bio = wikipedia_summary("en", link.title, transport, state)
            end
        end
        if info.bio then info.bio_source = "wikipedia" end
    end
    if not info.bio then
        info.bio = M.openLibraryBio(record)
        if info.bio then info.bio_source = "openlibrary" end
    end

    if not (info.bio or info.wikidata or record) then
        return nil, state.answered and "none" or "unreachable"
    end
    if not save(name, info) then return nil, "no storage" end
    logger.dbg("authors: saved info for", name, "wikidata =", tostring(info.wikidata))
    return info
end

return M
