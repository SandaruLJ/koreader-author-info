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
    local WD = "https://www.wikidata.org/w/api.php?action=wbgetentities&format=json&props=claims"
    local WD_LABELS = "https://www.wikidata.org/w/api.php?action=wbgetentities&format=json&props=labels"

    local function item(id, rank) return { rank = rank or "normal", mainsnak = { datavalue = { value = { id = id } } } } end
    local function time(t) return { rank = "normal", mainsnak = { datavalue = { value = { time = t } } } } end

    local le_guin_entity = { entities = { Q181659 = {
        claims = {
            P735 = { item("Q1") },
            P734 = { item("Q2"), item("Q3") },
            P27 = { item("Q30") },
            P569 = { time("+1929-10-21T00:00:00Z") },
            P570 = { time("+2018-01-22T00:00:00Z") },
            P136 = { item("Q24925"), item("Q132311"), item("Q99", "deprecated") },
            P800 = { item("Q7") },
        },
        sitelinks = { enwiki = { title = "Ursula K. Le Guin" } },
    } } }
    local le_guin_labels = { entities = {
        Q1 = { labels = { mul = { value = "Ursula" } } },
        Q2 = { labels = { en = { value = "Kroeber" } } },
        Q3 = { labels = { en = { value = "Le Guin" } } },
        Q30 = { labels = { en = { value = "United States" }, de = { value = "Vereinigte Staaten" } } },
        Q24925 = { labels = { en = { value = "science fiction" } } },
        Q132311 = { labels = { en = { value = "fantasy" } } },
        Q7 = { labels = { en = { value = "The Dispossessed" } } },
    } }

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
        responses[WD] = le_guin_entity
        responses[WD_LABELS] = le_guin_labels
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
        assert.are.same({ "Ursula" }, info.given) -- a "mul" label
        assert.are.same({ "Kroeber", "Le Guin" }, info.family)
        assert.are.same({ "science fiction", "fantasy" }, info.genres) -- deprecated dropped
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
        local entity = le_guin_entity.entities.Q181659
        entity.sitelinks.dewiki = { title = "Ursula K. Le Guin" }
        responses[WD] = le_guin_entity
        responses[WD_LABELS] = le_guin_labels
        responses[intro_url("de")] = intro("Deutsch.")
        local info = assert(fetch("Ursula K. Le Guin", "de"))
        assert.are.same({ "Vereinigte Staaten" }, info.countries)
        assert.are.same({ lang = "de", title = "Ursula K. Le Guin" }, info.wikipedia)
        assert.are.equal("Deutsch.", info.bio)
        entity.sitelinks.dewiki = nil
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
        responses[WD] = { entities = { Q311526 = { claims = {}, sitelinks = {} } } }
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
        responses[WD] = { entities = { Q36184 = { claims = {
            P27 = { item("Q174193"), item("Q145"), item("Q27") },
        }, sitelinks = {} } } }
        responses[WD_LABELS] = { entities = {
            Q145 = { labels = { en = { value = "United Kingdom" } } },
            Q27 = { labels = { en = { value = "Ireland" } } },
        } }
        local info = assert(fetch("Bram Stoker"))
        assert.are.same({ "United Kingdom", "Ireland" }, info.countries)
        for _i, url in ipairs(requests) do
            assert.is_nil(url:find("Q174193", 1, true), "the historical state's label is not asked for")
        end
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
        assert.are.same({ 10, 10 }, waited) -- the server asked for 30 s; capped
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
        responses[WD] = le_guin_entity
        responses[WD_LABELS] = le_guin_labels
        responses["https://en.wikipedia.org/api/rest_v1/page/summary/Ursula_K._Le_Guin"] =
            { type = "standard", extract = "Summary only." }
        assert.are.equal("Summary only.", assert(fetch("Ursula K. Le Guin")).bio)
        responses["https://en.wikipedia.org/api/rest_v1/page/summary/Ursula_K._Le_Guin"] = nil
        responses[intro_url("en")] = intro("First.\nSecond.")
        assert.are.equal("First.\n\nSecond.", assert(fetch("Ursula K. Le Guin")).bio)
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
