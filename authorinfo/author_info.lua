-- What we know about an author besides their photo: a short bio, their
-- country, birth and death years, given and family names and notable works. Saved as <data dir>/authorinfo/<author>.json, beside their photo
-- (author_images), one file per author,
-- so each lookup (a forked child) writes only its own file.
--
-- Sources, starting from the same Open Library match and Wikipedia page the
-- photo lookup uses (author_images; shared through opts.session):
--   1. Open Library's author record: its bio, dates, and Wikidata id.
--   2. Without a Wikidata id there, the writer's Wikipedia page's one.
--   3. Wikidata, through its query service (many authors at once): names,
--      country of citizenship, dates, notable works, and the title of
--      the author's Wikipedia page, with labels in KOReader's language where
--      Wikidata has them.
--   4. The bio: the introduction (the lead section, before the first
--      heading) of that Wikipedia page in KOReader's language, else in
--      English, else Open Library's bio. Its first paragraph is Wikipedia's
--      page summary, which drops the brackets after the name; the text
--      extracts would leave them as debris ("Anne Brontë (, commonly ;"),
--      since they remove English pronunciation templates from inside them.
--      The other paragraphs come from the extracts.

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
local WDQS_HOST = "query.wikidata.org"
local WDQS = "https://query.wikidata.org/sparql?format=json&query="
local SPARQL_HEADERS = { ["Accept"] = "application/sparql-results+json" }
local JSON_HEADERS = { ["Accept"] = "application/json" }

-- Wikidata properties we keep.
local P = {
    given = "P735",
    family = "P734",
    country = "P27",
    born = "P569",
    died = "P570",
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

-- savedStems() -> the file stems that have information in the folder.
function M.savedStems()
    local stems = {}
    local ok, iter, dir_obj = pcall(lfs.dir, M.dir())
    if ok and type(iter) == "function" then
        for file in iter, dir_obj do
            local stem = file:sub(1, 1) ~= "." and file:match("^(.+)%.json$")
            if stem then stems[#stems + 1] = stem end
        end
    end
    return stems
end

-- remove(name) -> true when saved information was deleted.
function M.remove(name)
    local path = type(name) == "string" and M.path(name)
    if not path then return false end
    local removed = os.remove(path) and true or false
    cache[path] = nil
    return removed
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

-- get(url, host, transport, state) -> decoded JSON | nil; how it went is
-- noted in state (see AuthorImages.note).
local function get(url, host, transport, state, headers)
    local data, err = Http.getJson(url, host, headers or JSON_HEADERS, transport)
    AuthorImages.note(state, data, err)
    return type(data) == "table" and data or nil
end

-- Authors asked about in one Wikidata query (one pass step), and labels
-- asked for at once.
local WD_BATCH = 50
M.WD_BATCH = WD_BATCH

-- wikidataQueries(ids, languages) -> the SPARQL queries asking Wikidata's
-- query service for just what we keep of these authors (see parseWikidata):
--   fields: the values of each property in P, labelled in languages. Only
--           statements of the best rank (the preferred ones when any are
--           marked so, never deprecated ones), as Wikidata's own "truthy"
--           statements are.
--   pages:  a row for each author Wikidata has, with their Wikipedia pages
--           in languages.
-- The whole entity (wbgetentities) would be 100-400 KB per well-known author,
-- nearly all references; this is a few KB. Two queries, as one joining both
-- (a UNION) is planned badly by the service and times out.
function M.wikidataQueries(ids, languages)
    local items, props, wikis = {}, {}, {}
    for _i, id in ipairs(ids) do items[#items + 1] = "wd:" .. id end
    local names = {}
    for name in pairs(P) do names[#names + 1] = name end
    table.sort(names)
    for _i, name in ipairs(names) do
        local id = P[name]
        props[#props + 1] = string.format('("%s" p:%s ps:%s)', name, id, id)
    end
    for _i, language in ipairs(languages) do
        if language ~= "mul" then
            wikis[#wikis + 1] = string.format('("%s" <https://%s.wikipedia.org/>)', language, language)
        end
    end
    local values = "VALUES ?item { " .. table.concat(items, " ") .. " }"
    return {
        fields = table.concat({
            "SELECT ?item ?field ?v ?vLabel ?ord WHERE {",
            "  " .. values,
            "  VALUES (?field ?p ?ps) { " .. table.concat(props, " ") .. " }",
            "  ?item ?p ?st . ?st a wikibase:BestRank ; ?ps ?v .",
            "  OPTIONAL { ?st pq:P1545 ?ord }",
            '  SERVICE wikibase:label { bd:serviceParam wikibase:language "'
                .. table.concat(languages, ",") .. '". }',
            "}",
        }, "\n"),
        pages = table.concat({
            "SELECT ?item ?lang ?title WHERE {",
            "  " .. values,
            "  ?item wikibase:sitelinks ?sitelinks .",
            "  OPTIONAL {",
            "    VALUES (?lang ?wiki) { " .. table.concat(wikis, " ") .. " }",
            "    ?page schema:about ?item ; schema:isPartOf ?wiki ; schema:name ?title .",
            "  }",
            "}",
        }, "\n"),
    }
end

local function binding(row, key)
    local cell = type(row) == "table" and row[key]
    return type(cell) == "table" and type(cell.value) == "string" and cell.value or nil
end

local function qid(uri)
    return type(uri) == "string" and uri:match("/entity/(Q%d+)$") or nil
end

-- parseWikidata(data, into) -> id -> { field -> { {id, label, ord} | {time},
-- ... }, sites -> lang -> title }, from either query's results, added to into
-- when given. Values come in no
-- particular order: they are ordered by their series ordinal (the order of
-- given names), then by item id, so the same author always reads the same.
function M.parseWikidata(data, into)
    local rows = type(data) == "table" and type(data.results) == "table"
        and type(data.results.bindings) == "table" and data.results.bindings or {}
    local result, seen = into or {}, {}
    for _i, row in ipairs(rows) do
        local item = qid(binding(row, "item"))
        if item then
            local entry = result[item] or { sites = {} }
            result[item] = entry
            local field, v = binding(row, "field"), binding(row, "v")
            local lang, title = binding(row, "lang"), binding(row, "title")
            if lang and title then
                entry.sites[lang] = title
            elseif field and P[field] and v then
                local id = qid(v)
                local key = item .. " " .. field .. " " .. (id or v)
                if not seen[key] and (id or field == "born" or field == "died") then
                    seen[key] = true
                    local label = binding(row, "vLabel")
                    if label == id then label = nil end -- no label in any language asked
                    entry[field] = entry[field] or {}
                    table.insert(entry[field], {
                        id = id, label = label, time = not id and v or nil,
                        ord = tonumber(binding(row, "ord")),
                    })
                end
            end
        end
    end
    local function number(value) return tonumber(value.id and value.id:sub(2)) or 0 end
    for _id, entry in pairs(result) do
        for field, values in pairs(entry) do
            if field ~= "sites" then
                table.sort(values, function(a, b)
                    if (a.ord or math.huge) ~= (b.ord or math.huge) then
                        return (a.ord or math.huge) < (b.ord or math.huge)
                    end
                    if a.time or b.time then return (a.time or "") < (b.time or "") end
                    return number(a) < number(b)
                end)
            end
        end
    end
    return result
end

-- labels(ids, languages) -> id -> label, in batches.
local function wikidata_labels(ids, languages, transport, state)
    local result = {}
    for start = 1, #ids, WD_BATCH do
        local batch = {}
        for i = start, math.min(#ids, start + WD_BATCH - 1) do batch[#batch + 1] = ids[i] end
        local data = get(WD_API .. "&props=labels&languages=" .. escape(table.concat(languages, "|"))
            .. "&ids=" .. escape(table.concat(batch, "|")), WD_HOST, transport, state)
        for id, entity in pairs(data and type(data.entities) == "table" and data.entities or {}) do
            result[id] = label(entity, languages)
        end
    end
    return result
end

local function wikipedia_host(language, title)
    if not language:match("^[a-z][a-z]?[a-z]?$") or type(title) ~= "string" then return nil end
    return language .. ".wikipedia.org"
end

-- wikipediaSummary(language, title) -> the page summary: its first
-- paragraph, tidied by Wikipedia, or nil.
local function wikipedia_summary(language, title, transport, state)
    local host = wikipedia_host(language, title)
    if not host then return nil end
    local data = get("https://" .. host .. "/api/rest_v1/page/summary/"
        .. escape((title:gsub(" ", "_"))), host, transport, state)
    local extract = data and data.type ~= "disambiguation" and data.extract
    if type(extract) ~= "string" then return nil end
    extract = extract:match("^%s*(.-)%s*$")
    return extract ~= "" and extract or nil
end

-- wikipediaIntro(language, title) -> the introduction as plain text (lines
-- are paragraphs, mostly), or nil.
local function wikipedia_intro(language, title, transport, state)
    local host = wikipedia_host(language, title)
    if not host then return nil end
    local data = get("https://" .. host .. "/w/api.php?action=query&format=json&formatversion=2"
        .. "&prop=extracts&exintro=1&explaintext=1&redirects=1&titles=" .. escape(title),
        host, transport, state)
    local pages = data and type(data.query) == "table" and data.query.pages
    local page = type(pages) == "table" and pages[1]
    local extract = type(page) == "table" and not page.missing and page.extract
    return type(extract) == "string" and extract or nil
end

-- Whitespace collapsed, for comparing texts.
local function squash(text)
    return (text:gsub("%s+", " "):match("^ ?(.-) ?$"))
end

-- bioText(summary, intro) -> the bio, paragraphs separated by a blank line;
-- or nil. The introduction's first paragraph is replaced by the summary (see
-- the top of this file). Its lines are mostly paragraphs, but a line break
-- inside a template (a name's native spelling, its dates) breaks one: a line
-- not ending a sentence is joined to the next. The summary's end is then
-- found in the introduction, and what follows it kept, so a paragraph the
-- summary already holds is not repeated whatever the line breaks.
function M.bioText(summary, intro)
    local paragraphs = {}
    if type(intro) == "string" then
        local open = false
        for line in intro:gmatch("[^\n]+") do
            line = line:match("^%s*(.-)%s*$")
            if line ~= "" then
                if open then
                    paragraphs[#paragraphs] = paragraphs[#paragraphs] .. " " .. line
                else
                    paragraphs[#paragraphs + 1] = line
                end
                open = not line:match("[%.!?…:\"”’'%)%]»]$")
            end
        end
    end
    if type(summary) ~= "string" or summary == "" then
        return #paragraphs > 0 and table.concat(paragraphs, "\n\n") or nil
    end
    local rest = 2
    local tail = squash(summary)
    tail = tail:sub(math.max(1, #tail - 29))
    local seen = ""
    for i, paragraph in ipairs(paragraphs) do
        seen = squash(seen .. " " .. paragraph)
        if seen:sub(-#tail) == tail then
            rest = i + 1
            break
        end
    end
    local bio = { summary }
    for i = rest, #paragraphs do bio[#bio + 1] = paragraphs[i] end
    return table.concat(bio, "\n\n")
end

-- wikipediaBio(language, title) -> the introduction, its first paragraph
-- being the page summary; or nil.
local function wikipedia_bio(language, title, transport, state)
    local summary = wikipedia_summary(language, title, transport, state)
    local intro = wikipedia_intro(language, title, transport, state)
    return M.bioText(summary, intro)
end

-- A lookup goes in three stages, so that looking up many authors can ask
-- Wikidata about up to WD_BATCH of them at once (actions does that, running
-- each stage in a forked child):
--   begin(name, opts) -> job        -- Open Library, and Wikipedia's page
--                                      for the Wikidata id when needed
--   addWikidata(jobs, opts)         -- Wikidata, for all the jobs at once
--   finish(job, opts) -> info | nil, reason  -- the bio; saves the info
-- A job is plain data (it is passed between the children as JSON).
-- fetch(name, opts) does all three for one author.
--   opts.session   -- shared with author_images.fetch for the same author
--   opts.language  -- Wikipedia/Wikidata language (default KOReader's)
--   opts.transport -- stubs the network (specs)
--   reason: "placeholder", "bad name", "none" (asked, nothing found),
--           "rate_limited" (a source was still rate limiting; try later),
--           "incomplete" (a source did not answer properly; try later),
--           "unreachable" (no source answered), "no storage"
-- Nothing is saved from a lookup that was rate limited or incomplete, so
-- finding missing information tries the author again.

local function languages_for(opts)
    local language = opts.language or M.uiLanguage()
    return language == "en" and { "en", "mul" } or { language, "en", "mul" }
end

-- begin(name, opts) -> job | nil, reason
function M.begin(name, opts)
    opts = opts or {}
    if AuthorImages.isPlaceholder(name) then return nil, "placeholder" end
    if not M.path(name) then return nil, "bad name" end
    local transport, session = opts.transport, opts.session or {}
    local state = {}
    local job = {
        name = name,
        state = state,
        info = { version = M.VERSION, name = name, fetched = os.time() },
    }

    -- 1. Open Library.
    local doc, _answered, ol_state = AuthorImages.searchOpenLibrary(name, transport, session)
    AuthorImages.merge(state, ol_state)
    local olid = AuthorImages.openLibraryId(doc)
    local record
    if olid then
        job.info.openlibrary = olid
        record = get("https://" .. OL_HOST .. "/authors/" .. olid .. ".json", OL_HOST, transport, state)
    end
    if record then
        -- What finish needs of it.
        local bio = M.openLibraryBio(record)
        job.record = { bio = bio, born = M.year(record.birth_date), died = M.year(record.death_date) }
    end
    local wikidata_id = record and type(record.remote_ids) == "table" and record.remote_ids.wikidata

    -- 2. Wikipedia's page for the Wikidata id when Open Library has none.
    if type(wikidata_id) ~= "string" or not wikidata_id:match("^Q%d+$") then
        local page, _wp_answered, wp_state = AuthorImages.findWikipediaPage(name, transport, session)
        AuthorImages.merge(state, wp_state)
        wikidata_id = page and type(page.pageprops) == "table" and page.pageprops.wikibase_item
        if page then job.info.wikipedia = { lang = "en", title = page.title } end
    end
    if type(wikidata_id) == "string" and wikidata_id:match("^Q%d+$") then job.wikidata = wikidata_id end
    return job
end

-- addWikidata(jobs, opts) -> state (see AuthorImages.note): 3. Wikidata, for
-- every job with an id, WD_BATCH authors per query.
function M.addWikidata(jobs, opts)
    opts = opts or {}
    local transport = opts.transport
    local languages = languages_for(opts)
    local ids, seen = {}, {}
    for _i, job in ipairs(jobs) do
        if job.wikidata and not seen[job.wikidata] then
            seen[job.wikidata] = true
            ids[#ids + 1] = job.wikidata
        end
    end
    local state = {}
    if #ids == 0 then return state end
    local found = {}
    for start = 1, #ids, WD_BATCH do
        local queries = M.wikidataQueries({ unpack(ids, start, math.min(#ids, start + WD_BATCH - 1)) }, languages)
        local fields = {}
        M.parseWikidata(get(WDQS .. escape(queries.fields), WDQS_HOST, transport, state, SPARQL_HEADERS), fields)
        local pages = M.parseWikidata(get(WDQS .. escape(queries.pages), WDQS_HOST, transport, state, SPARQL_HEADERS))
        -- An author is found when the pages query names them.
        for id, entry in pairs(pages) do
            for field, values in pairs(fields[id] or {}) do
                if field ~= "sites" then entry[field] = values end
            end
            found[id] = entry
        end
    end

    -- Labels the query could not give: the countries historical states map to.
    local labels, missing, asked = {}, {}, {}
    for _id, entry in pairs(found) do
        for _field, values in pairs(entry) do
            for _i, value in ipairs(values) do
                if value.id and value.label then labels[value.id] = value.label end
            end
        end
    end
    for _id, entry in pairs(found) do
        for _i, value in ipairs(entry.country or {}) do
            local successor = COUNTRY_SUCCESSORS[value.id]
            if successor and not labels[successor] and not asked[successor] then
                asked[successor] = true
                missing[#missing + 1] = successor
            end
        end
    end
    if #missing > 0 then
        for id, value in pairs(wikidata_labels(missing, languages, transport, state)) do labels[id] = value end
    end

    local limits = { works = MAX_WORKS }
    for _i, job in ipairs(jobs) do
        local entry = job.wikidata and found[job.wikidata]
        if entry then
            local info = job.info
            info.wikidata = job.wikidata
            info.born = entry.born and M.year(entry.born[1].time)
            info.died = entry.died and M.year(entry.died[1].time)
            -- info field <- query field (P's names)
            for field, from in pairs({ given = "given", family = "family", countries = "country",
                    works = "works" }) do
                local values, seen_value = {}, {}
                for _k, value in ipairs(entry[from] or {}) do
                    local id = from == "country" and COUNTRY_SUCCESSORS[value.id] or value.id
                    local text = labels[id]
                    if text and not seen_value[text] then
                        seen_value[text] = true
                        values[#values + 1] = text
                        if limits[field] and #values >= limits[field] then break end
                    end
                end
                if #values > 0 then info[field] = values end
            end
            for _j, l in ipairs(languages) do
                if entry.sites[l] then
                    info.wikipedia = { lang = l, title = entry.sites[l] }
                    break
                end
            end
            job.enwiki = entry.sites.en
        end
        if job.wikidata then AuthorImages.merge(job.state, state) end
    end
    return state
end

-- finish(job, opts) -> info | nil, reason: 4. the bio, then saves.
function M.finish(job, opts)
    opts = opts or {}
    local transport = opts.transport
    local state, info, record = job.state, job.info, job.record
    if record then
        info.born = info.born or record.born
        info.died = info.died or record.died
    end
    if info.wikipedia then
        info.bio = wikipedia_bio(info.wikipedia.lang, info.wikipedia.title, transport, state)
        if not info.bio and info.wikipedia.lang ~= "en" and job.enwiki then
            info.wikipedia = { lang = "en", title = job.enwiki }
            info.bio = wikipedia_bio("en", job.enwiki, transport, state)
        end
        if info.bio then info.bio_source = "wikipedia" end
    end
    if not info.bio and record and record.bio then
        info.bio = record.bio
        info.bio_source = "openlibrary"
    end

    if state.limited then return nil, "rate_limited" end
    if state.incomplete then return nil, state.answered and "incomplete" or "unreachable" end
    if not (info.bio or info.wikidata or record) then
        return nil, state.answered and "none" or "unreachable"
    end
    if not save(job.name, info) then return nil, "no storage" end
    logger.dbg("authors: saved info for", job.name, "wikidata =", tostring(info.wikidata))
    return info
end

-- fetch(name, opts) -> info | nil, reason. Looks the author up and saves what
-- was found, replacing anything saved before.
function M.fetch(name, opts)
    local job, reason = M.begin(name, opts)
    if not job then return nil, reason end
    M.addWikidata({ job }, opts)
    return M.finish(job, opts)
end

return M
