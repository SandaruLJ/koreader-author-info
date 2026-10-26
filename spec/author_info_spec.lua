local JSON = require("json")

describe("author info", function()
    local AuthorInfo, AuthorImages, dir, requests, responses

    -- Answers from the longest registered prefix of the url, so a specific
    -- endpoint wins over a shorter one it shares a prefix with.
    local function respond(url)
        requests[#requests + 1] = url
        local best
        for prefix in pairs(responses) do
            if url:sub(1, #prefix) == prefix and (not best or #prefix > #best) then best = prefix end
        end
        if best then return { status = 200, headers = {}, body = JSON.encode(responses[best]) } end
        return { status = 404, headers = {}, body = "" }
    end

    local OL_SEARCH = "https://openlibrary.org/search/authors.json"
    local OL_AUTHOR = "https://openlibrary.org/authors/"
    local WP_QUERY = "https://en.wikipedia.org/w/api.php"
    local function intro_url(language)
        return "https://" .. language .. ".wikipedia.org/w/api.php?action=query&format=json&formatversion=2"
            .. "&prop=extracts"
    end
    local function intro(text) return { query = { pages = { { title = "x", extract = text } } } } end
    local WDQS = "https://query.wikidata.org/sparql"
    local WD_LABELS = "https://www.wikidata.org/w/api.php?action=wbgetentities&format=json&props=labels"

    -- sparql{ Q1 = { field = { {id, label, ord}, ... } | time, sites = { lang = title } } }
    -- -> the query service's answer: one row per value or page.
    local function sparql(authors)
        local rows = {}
        local function uri(id) return { type = "uri", value = "http://www.wikidata.org/entity/" .. id } end
        local function lit(v) return { type = "literal", value = tostring(v) } end
        for item, fields in pairs(authors) do
            rows[#rows + 1] = { item = uri(item), sitelinks = lit(0) }
            for field, values in pairs(fields) do
                if field == "sites" then
                    for lang, title in pairs(values) do
                        rows[#rows + 1] = { item = uri(item), lang = lit(lang), title = lit(title) }
                    end
                elseif type(values) == "string" then
                    rows[#rows + 1] = { item = uri(item), field = lit(field), v = lit(values), vLabel = lit(values) }
                else
                    for _i, value in ipairs(values) do
                        rows[#rows + 1] = { item = uri(item), field = lit(field), v = uri(value[1]),
                            vLabel = lit(value[2] or value[1]), ord = value[3] and lit(value[3]) or nil }
                    end
                end
            end
        end
        return { results = { bindings = rows } }
    end

    local le_guin = {
        given = { { "Q1", "Ursula" } },
        family = { { "Q3", "Le Guin" }, { "Q2", "Kroeber" } },
        country = { { "Q30", "United States" } },
        born = "1929-10-21T00:00:00Z",
        died = "2018-01-22T00:00:00Z",
        genres = { { "Q132311", "fantasy" }, { "Q24925", "science fiction" } },
        works = { { "Q7", "The Dispossessed" } },
        sites = { en = "Ursula K. Le Guin" },
    }
    local le_guin_wd = sparql({ Q181659 = le_guin })

    before_each(function()
        package.loaded["authorinfo/author_info"] = nil
        package.loaded["authorinfo/author_images"] = nil
        AuthorImages = require("authorinfo/author_images")
        AuthorInfo = require("authorinfo/author_info")
        dir = os.tmpname()
        os.remove(dir)
        AuthorInfo._setDir(dir)
        requests, responses = {}, {}
        require("authorinfo/http").sleep = function() end
    end)

    after_each(function()
        os.execute("rm -rf '" .. dir .. "'")
        AuthorInfo._setDir(nil)
    end)

    local function fetch(name, language)
        return AuthorInfo.fetch(name, { transport = respond, language = language or "en", session = {} })
    end

    it("gathers Open Library, Wikidata and Wikipedia into one record and saves it", function()
        responses[OL_SEARCH] = { docs = { { key = "/authors/OL31353A", name = "Ursula K. Le Guin", work_count = 300 } } }
        responses[OL_AUTHOR .. "OL31353A.json"] = { remote_ids = { wikidata = "Q181659" }, birth_date = "21 October 1929",
            bio = "Short Open Library bio that should not be used because Wikipedia has one." }
        responses[WDQS] = le_guin_wd
        responses["https://en.wikipedia.org/api/rest_v1/page/summary/Ursula_K._Le_Guin"] =
            { type = "standard", extract = "Ursula Kroeber Le Guin was an American author." }
        responses[intro_url("en")] = intro("Ursula Kroeber Le Guin (, commonly ; 1929–2018) was an American author.\n"
            .. "She is best known for Earthsea.\n\nShe won many awards.")

        local info = assert(fetch("Ursula K. Le Guin"))
        assert.are.equal("Q181659", info.wikidata)
        assert.are.equal("OL31353A", info.openlibrary)
        assert.are.equal("1929", info.born)
        assert.are.equal("2018", info.died)
        assert.are.same({ "United States" }, info.countries)
        assert.are.same({ "Ursula" }, info.given)
        assert.are.same({ "Kroeber", "Le Guin" }, info.family) -- by item id, whatever the rows' order
        assert.are.same({ "science fiction", "fantasy" }, info.genres)
        assert.are.same({ "The Dispossessed" }, info.works)
        -- The whole introduction, one blank line between paragraphs, its first
        -- paragraph the tidied summary rather than the extract's debris.
        assert.are.equal("Ursula Kroeber Le Guin was an American author.\n\n"
            .. "She is best known for Earthsea.\n\nShe won many awards.", info.bio)
        assert.are.equal("wikipedia", info.bio_source)
        assert.are.same(info, AuthorInfo.load("Ursula K. Le Guin"))
        for _i, url in ipairs(requests) do
            assert.is_nil(url:find("prop=pageimages", 1, true), "no Wikipedia search when Open Library has the id")
        end
    end)

    it("asks Wikidata and Wikipedia in KOReader's language first", function()
        responses[OL_SEARCH] = { docs = { { key = "/authors/OL31353A", name = "Ursula K. Le Guin", work_count = 300 } } }
        responses[OL_AUTHOR .. "OL31353A.json"] = { remote_ids = { wikidata = "Q181659" } }
        responses[WDQS] = sparql({ Q181659 = { country = { { "Q30", "Vereinigte Staaten" } },
            sites = { de = "Ursula K. Le Guin", en = "Ursula K. Le Guin" } } })
        responses[intro_url("de")] = intro("Deutsch.")
        local info = assert(fetch("Ursula K. Le Guin", "de"))
        assert.are.same({ "Vereinigte Staaten" }, info.countries)
        assert.are.same({ lang = "de", title = "Ursula K. Le Guin" }, info.wikipedia)
        assert.are.equal("Deutsch.", info.bio)
        local query = ""
        for _i, url in ipairs(requests) do
            if url:find(WDQS, 1, true) then query = query .. url end
        end
        assert.is_truthy(query:find("de%2Cen%2Cmul", 1, true), "labels in German, else English")
        assert.is_truthy(query:find("https%3A%2F%2Fde.wikipedia.org%2F", 1, true))
    end)

    it("falls back to the writer's Wikipedia page for the id, and Open Library's bio", function()
        responses[OL_SEARCH] = { docs = { { key = "/authors/OL1A", name = "Saki", work_count = 100 } } }
        responses[OL_AUTHOR .. "OL1A.json"] = {
            bio = { type = "/type/text", value = "Hector Hugh Munro, better known as [Saki](https://example.org), "
                .. "was a British writer whose witty stories satirised Edwardian society.\n\n([Source][1])\n\n[1]: https://example.org" },
            birth_date = "1870", death_date = "1916",
        }
        responses[WP_QUERY] = { query = { pages = { { title = "Saki", description = "British writer (1870-1916)",
            pageprops = { wikibase_item = "Q311526" } } } } }
        responses[WDQS] = sparql({ Q311526 = { sites = {} } })
        local info = assert(fetch("Saki"))
        assert.are.equal("Q311526", info.wikidata)
        assert.are.equal("openlibrary", info.bio_source)
        assert.are.equal("Hector Hugh Munro, better known as Saki, was a British writer whose witty stories "
            .. "satirised Edwardian society.", info.bio)
        assert.are.equal("1870", info.born)
        assert.are.equal("1916", info.died)
    end)

    it("names historical states by the country they are now, once", function()
        responses[OL_SEARCH] = { docs = { { key = "/authors/OL2A", name = "Bram Stoker", work_count = 100 } } }
        responses[OL_AUTHOR .. "OL2A.json"] = { remote_ids = { wikidata = "Q36184" } }
        responses[WDQS] = sparql({ Q36184 = { country = {
            { "Q174193", "United Kingdom of Great Britain and Ireland" }, { "Q145", "United Kingdom" }, { "Q27", "Ireland" },
        } } })
        local info = assert(fetch("Bram Stoker"))
        assert.are.same({ "Ireland", "United Kingdom" }, info.countries)
        for _i, url in ipairs(requests) do
            assert.is_nil(url:find("props=labels", 1, true), "the query named every country")
        end

        -- Only the historical state: today's country's label is asked for.
        responses[WDQS] = sparql({ Q36184 = { country = { { "Q174193", "United Kingdom of Great Britain and Ireland" } } } })
        responses[WD_LABELS] = { entities = { Q145 = { labels = { en = { value = "United Kingdom" } } } } }
        assert.are.same({ "United Kingdom" }, assert(fetch("Bram Stoker")).countries)
    end)

    it("reports none or unreachable, and never looks up placeholders", function()
        responses[OL_SEARCH] = { docs = {} }
        local info, why = fetch("Zzqx Nobody")
        assert.is_nil(info)
        assert.are.equal("none", why)

        info, why = AuthorInfo.fetch("Naomi Novik", { session = {}, language = "en",
            transport = function() return nil, { kind = "offline" } end })
        assert.is_nil(info)
        assert.are.equal("unreachable", why)

        requests = {}
        info, why = fetch("Anonymous")
        assert.are.equal("placeholder", why)
        assert.are.equal(0, #requests)
    end)

    it("waits and retries when rate limited", function()
        local waited, calls = {}, 0
        require("authorinfo/http").sleep = function(seconds) waited[#waited + 1] = seconds end
        local data, err = require("authorinfo/http").getJson("https://openlibrary.org/x", "openlibrary.org", {},
            function()
                calls = calls + 1
                if calls < 3 then return { status = 429, headers = { ["Retry-After"] = "30" }, body = "" } end
                return { status = 200, headers = {}, body = "{\"ok\":true}" }
            end)
        assert.is_nil(err)
        assert.is_true(data.ok)
        assert.are.same({ 30, 30 }, waited)
        waited, calls = {}, 0
        require("authorinfo/http").getJson("https://openlibrary.org/x", "openlibrary.org", {}, function()
            calls = calls + 1
            return { status = 429, headers = { ["Retry-After"] = "600" }, body = "" }
        end)
        assert.are.same({ 30, 30 }, waited, "a long wait asked for is capped")

        -- No Retry-After: a short wait of our own.
        waited, calls = {}, 0
        data = require("authorinfo/http").getJson("https://openlibrary.org/x", "openlibrary.org", {}, function()
            calls = calls + 1
            if calls < 2 then return { status = 429, headers = {}, body = "" } end
            return { status = 200, headers = {}, body = "{\"ok\":true}" }
        end)
        assert.is_true(data.ok)
        assert.are.same({ 2 }, waited)

        -- No reply (a timeout): tried once more at once, not again and again.
        waited, calls = {}, 0
        local data2 = require("authorinfo/http").getJson("https://openlibrary.org/x", "openlibrary.org", {}, function()
            calls = calls + 1
            if calls == 1 then return nil, { kind = "network" } end
            return { status = 200, headers = {}, body = "{\"ok\":true}" }
        end)
        assert.is_true(data2.ok)
        assert.are.same({}, waited)
        calls = 0
        require("authorinfo/http").getJson("https://openlibrary.org/x", "openlibrary.org", {}, function()
            calls = calls + 1
            return nil, { kind = "network" }
        end)
        assert.are.equal(2, calls)
    end)

    it("keeps nothing from a lookup that was rate limited or cut short, so it is tried again", function()
        responses[OL_SEARCH] = { docs = { { key = "/authors/OL31353A", name = "Ursula K. Le Guin", work_count = 300 } } }
        responses[OL_AUTHOR .. "OL31353A.json"] = { remote_ids = { wikidata = "Q181659" } }
        responses[WDQS] = le_guin_wd
        responses["https://en.wikipedia.org/api/rest_v1/page/summary/Ursula_K._Le_Guin"] =
            { type = "standard", extract = "Summary only." }
        local function failing(status)
            return function(url)
                if url:find("prop=extracts", 1, true) then return { status = status, headers = {}, body = "" } end
                return respond(url)
            end
        end
        local info, why = AuthorInfo.fetch("Ursula K. Le Guin", { transport = failing(429), language = "en", session = {} })
        assert.is_nil(info)
        assert.are.equal("rate_limited", why)
        info, why = AuthorInfo.fetch("Ursula K. Le Guin", { transport = failing(502), language = "en", session = {} })
        assert.is_nil(info)
        assert.are.equal("incomplete", why)
        assert.is_false(AuthorInfo.has("Ursula K. Le Guin"))
    end)

    it("asks Wikidata about many authors at once", function()
        responses[OL_SEARCH] = { docs = { { key = "/authors/OL31353A", name = "Ursula K. Le Guin", work_count = 300 } } }
        responses[OL_AUTHOR .. "OL31353A.json"] = { remote_ids = { wikidata = "Q181659" } }
        responses[WDQS] = sparql({ Q181659 = le_guin, Q42 = { country = { { "Q145", "United Kingdom" } } } })
        local opts = { transport = respond, language = "en" }
        local a = assert(AuthorInfo.begin("Ursula K. Le Guin", { transport = respond, language = "en", session = {} }))
        local b = assert(AuthorInfo.begin("Douglas Adams", { transport = respond, language = "en", session = {} }))
        b.wikidata = "Q42"
        requests = {}
        AuthorInfo.addWikidata({ a, b }, opts)
        assert.are.equal(2, #requests, "the fields and pages queries, for both")
        for _i, url in ipairs(requests) do
            assert.is_truthy(url:find("wd%3AQ181659%20wd%3AQ42", 1, true))
        end
        assert.are.same({ "United States" }, a.info.countries)
        assert.are.same({ "United Kingdom" }, b.info.countries)
        assert(AuthorInfo.finish(a, opts))
        assert.are.same({ "The Dispossessed" }, AuthorInfo.load("Ursula K. Le Guin").works)
    end)

    it("orders given names by their series ordinal, and keeps few genres and works", function()
        local genres = {}
        for i = 1, 7 do genres[i] = { "Q" .. (100 + i), "genre " .. i } end
        local data = sparql({ Q1 = { given = { { "Q20", "Hugh", "2" }, { "Q10", "Hector", "1" } }, genres = genres } })
        local parsed = AuthorInfo.parseWikidata(data)
        assert.are.equal("Hector", parsed.Q1.given[1].label)
        assert.are.equal("Hugh", parsed.Q1.given[2].label)
        local job = { name = "Saki", wikidata = "Q1", state = {}, info = {} }
        AuthorInfo.addWikidata({ job }, { language = "en", transport = function()
            return { status = 200, headers = {}, body = JSON.encode(data) }
        end })
        assert.are.same({ "Hector", "Hugh" }, job.info.given)
        assert.are.same({ "genre 1", "genre 2", "genre 3", "genre 4", "genre 5" }, job.info.genres)
    end)

    it("picks the family name the shown name contains, latest first", function()
        local info = { family = { "Kroeber", "Le Guin" } }
        assert.are.equal("Le Guin", AuthorInfo.familyName(info, "Ursula K. Le Guin"))
        assert.are.equal("Le Guin", AuthorInfo.familyName(info, "Le Guin, Ursula K."))
        assert.are.equal("Liu", AuthorInfo.familyName({ family = { "Liu" } }, "Liu Cixin"))
        assert.is_nil(AuthorInfo.familyName({ family = { "Munro" } }, "Saki"))
        assert.is_nil(AuthorInfo.familyName(nil, "Saki"))
    end)

    it("cleans and trims Open Library bios, and skips ones that say nothing", function()
        assert.is_nil(AuthorInfo.openLibraryBio({ bio = "Chinese author." }))
        local long = string.rep("A sentence about the author. ", 80)
        local bio = AuthorInfo.openLibraryBio({ bio = long })
        assert.is_true(#bio <= 1210)
        assert.is_truthy(bio:match("%. …$"))
        assert.are.equal("1929", AuthorInfo.year("+1929-10-21T00:00:00Z"))
        assert.are.equal("1870", AuthorInfo.year("c. 1870"))
        assert.is_nil(AuthorInfo.year("-0500-01-01T00:00:00Z"))
    end)

    it("uses the summary or the introduction alone when only one is there", function()
        responses[OL_SEARCH] = { docs = { { key = "/authors/OL31353A", name = "Ursula K. Le Guin", work_count = 300 } } }
        responses[OL_AUTHOR .. "OL31353A.json"] = { remote_ids = { wikidata = "Q181659" } }
        responses[WDQS] = le_guin_wd
        responses["https://en.wikipedia.org/api/rest_v1/page/summary/Ursula_K._Le_Guin"] =
            { type = "standard", extract = "Summary only." }
        assert.are.equal("Summary only.", assert(fetch("Ursula K. Le Guin")).bio)
        responses["https://en.wikipedia.org/api/rest_v1/page/summary/Ursula_K._Le_Guin"] = nil
        responses[intro_url("en")] = intro("First.\nSecond.")
        assert.are.equal("First.\n\nSecond.", assert(fetch("Ursula K. Le Guin")).bio)
    end)

    it("mends paragraphs a line break in a template split, without repeating the summary", function()
        -- Anton Chekhov's English introduction, shortened.
        local summary = "Anton Pavlovich Chekhov was a Russian playwright. "
            .. "\"Medicine is my lawful wife,\" he once said, \"and literature is my mistress.\""
        local intro = "Anton Pavlovich Chekhov (; Russian: Антон Павлович Чехов;\n"
            .. "29 January 1860 – 15 July 1904) was a Russian playwright. "
            .. "\"Medicine is my lawful wife,\" he once said, \"and literature is my mistress.\"\n"
            .. "Chekhov renounced the theatre in 1896.\n"
            .. "Chekhov began writing stories to earn money."
        assert.are.equal(summary .. "\n\nChekhov renounced the theatre in 1896.\n\n"
            .. "Chekhov began writing stories to earn money.", AuthorInfo.bioText(summary, intro))
        -- A summary whose end differs from the introduction's replaces its
        -- first paragraph.
        assert.are.equal("Short.\n\nSecond.", AuthorInfo.bioText("Short.", "Long (1900) first.\nSecond."))
    end)

    it("removes saved information", function()
        responses[OL_SEARCH] = { docs = { { key = "/authors/OL1A", name = "Saki", work_count = 100 } } }
        responses[OL_AUTHOR .. "OL1A.json"] = { birth_date = "1870" }
        assert(fetch("Saki"))
        assert.is_true(AuthorInfo.has("Saki"))
        assert.is_true(AuthorInfo.remove("Saki"))
        assert.is_false(AuthorInfo.has("Saki"))
        assert.is_false(AuthorInfo.remove("Saki"))
    end)

    it("names the sources the information came from", function()
        assert.are.equal("Wikipedia (en), Wikidata", AuthorInfo.sourcesText({ bio_source = "wikipedia",
            wikipedia = { lang = "en" }, wikidata = "Q1" }))
        assert.are.equal("Open Library", AuthorInfo.sourcesText({ bio_source = "openlibrary" }))
        assert.is_nil(AuthorInfo.sourcesText({}))
    end)
end)
