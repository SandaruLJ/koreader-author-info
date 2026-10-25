describe("authors view options", function()
    local ViewOptions, saved

    before_each(function()
        saved = {}
        _G.G_reader_settings = {
            readSetting = function(_self, key) return saved[key] end,
            saveSetting = function(_self, key, value) saved[key] = value end,
        }
        package.loaded["ffi/util"] = {
            strcoll = function(a, b) return a < b end,
            template = function(s, ...)
                local args = { ... }
                return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
            end,
        }
        package.loaded["gettext"] = setmetatable({}, { __call = function(_self, s) return s end })
        package.loaded["libs/libkoreader-lfs"] = { attributes = function() return "file" end }
        package.loaded["authorinfo/author_index"] = nil
        package.loaded["authorinfo/view_options"] = nil
        ViewOptions = require("authorinfo/view_options")
    end)

    local function names(authors)
        local list = {}
        for _i, author in ipairs(authors) do list[#list + 1] = author.name end
        return list
    end

    local function shown(authors)
        local result = {}
        for _i, author in ipairs(authors) do result[author.name] = author.files end
        return result
    end

    -- Pratchett: one finished (/a), one new (/b). Gaiman: shares /a, and /c
    -- in progress. Christie: one abandoned (/d). Herron: one new (/e).
    local books = {
        { path = "/a", authors = "Terry Pratchett\nNeil Gaiman", keywords = "Fantasy\nHumour", language = "EN" },
        { path = "/b", authors = "Terry Pratchett", keywords = "Fantasy", language = "en" },
        { path = "/c", authors = "Neil Gaiman", keywords = "Fantasy" },
        { path = "/d", authors = "Agatha Christie", keywords = "Mystery" },
        { path = "/e", authors = "Mick Herron", keywords = "Thriller" },
    }
    local statuses = { ["/a"] = "complete", ["/b"] = "new", ["/c"] = "reading", ["/d"] = "abandoned", ["/e"] = "new" }
    local function status_of(path) return statuses[path] end

    it("sorts by first name, last name, number of books and recent reading", function()
        local authors = function()
            return {
                { name = "Terry Pratchett", files = { "/a", "/b", "/c" } },
                { name = "Le Guin, Ursula K.", files = { "/d" } },
                { name = "Neil Gaiman", files = { "/a", "/e" } },
            }
        end
        -- First name reads "Le Guin, Ursula K." as "Ursula K. Le Guin".
        assert.are.same({ "Neil Gaiman", "Terry Pratchett", "Le Guin, Ursula K." },
            names(ViewOptions.sort(authors(), { sort = "first_name" })))
        assert.are.same({ "Neil Gaiman", "Le Guin, Ursula K.", "Terry Pratchett" },
            names(ViewOptions.sort(authors(), { sort = "last_name" })))
        assert.are.same({ "Terry Pratchett", "Neil Gaiman", "Le Guin, Ursula K." },
            names(ViewOptions.sort(authors(), { sort = "books" })))
        assert.are.same({ "Le Guin, Ursula K.", "Neil Gaiman", "Terry Pratchett" },
            names(ViewOptions.sort(authors(), { sort = "recent" }, { ["/d"] = 300, ["/e"] = 200, ["/a"] = 100 })))
        assert.are.same({ "Le Guin, Ursula K.", "Terry Pratchett", "Neil Gaiman" },
            names(ViewOptions.sort(authors(), { sort = "first_name", reverse = true })))
    end)

    it("finds surnames with particles and suffixes", function()
        local cases = {
            ["Terry Pratchett"] = "Pratchett",
            ["Le Guin, Ursula K."] = "Le Guin",
            ["Ursula K. Le Guin"] = "Le Guin",
            ["Walter de la Mare"] = "de la Mare",
            ["Ludwig van Beethoven"] = "van Beethoven",
            ["Johann Wolfgang von Goethe"] = "von Goethe",
            ["Martin Luther King Jr."] = "King",
            ["Martin Luther King, Jr."] = "King",
            ["John Smith III"] = "Smith",
            ["Van Morrison"] = "Morrison",
            ["Saki"] = "Saki",
            ["Anonymous"] = "Anonymous",
        }
        for name, expected in pairs(cases) do
            assert.are.equal(expected, ViewOptions.surname(name), name)
        end
        local sorted = ViewOptions.sort({
            { name = "Walter de la Mare", files = {} },
            { name = "Ursula K. Le Guin", files = {} },
            { name = "Agatha Christie", files = {} },
            { name = "Martin Luther King Jr.", files = {} },
        }, { sort = "last_name" })
        assert.are.same({ "Agatha Christie", "Walter de la Mare", "Martin Luther King Jr.", "Ursula K. Le Guin" },
            names(sorted))
    end)

    it("sorts by the family name from author information when the name contains it", function()
        local infos = {
            ["Liu Cixin"] = { family = { "Liu" } },
            ["Ursula K. Le Guin"] = { family = { "Kroeber", "Le Guin" } },
            ["Saki"] = { family = { "Munro" } }, -- not in the shown name: not trusted
        }
        local sorted = ViewOptions.sort({
            { name = "Ursula K. Le Guin", files = {} },
            { name = "Saki", files = {} },
            { name = "Liu Cixin", files = {} },
            { name = "Becky Chambers", files = {} },
        }, { sort = "last_name" }, nil, function(name) return infos[name] end)
        -- Chambers, Le Guin, Liu (not "Cixin"), Saki
        assert.are.same({ "Becky Chambers", "Ursula K. Le Guin", "Liu Cixin", "Saki" }, names(sorted))
    end)

    it("filters by country from author information, listing all their books", function()
        local infos = {
            ["Terry Pratchett"] = { countries = { "United Kingdom" } },
            ["Neil Gaiman"] = { countries = { "United Kingdom", "United States" } },
            ["Agatha Christie"] = { countries = { "United Kingdom" } },
        }
        local infoOf = function(name) return infos[name] end
        assert.are.same({ ["Agatha Christie"] = { "/d" }, ["Neil Gaiman"] = { "/a", "/c" },
                ["Terry Pratchett"] = { "/a", "/b" } },
            shown(ViewOptions.filterAuthors(books, { country = "United Kingdom" }, status_of, infoOf)))
        assert.are.same({ ["Neil Gaiman"] = { "/a", "/c" } },
            shown(ViewOptions.filterAuthors(books, { country = "United States" }, status_of, infoOf)))
        assert.are.same({ { value = "United Kingdom", count = 3 }, { value = "United States", count = 1 } },
            ViewOptions.authorValueCounts(ViewOptions.filterAuthors(books, {}, status_of, infoOf), "country", infoOf))
        assert.are.equal("Country: United States · Keywords: Fantasy",
            ViewOptions.describe({ country = "United States", keywords = "Fantasy" }))
    end)

    it("Read lists authors with a finished book, and only those books", function()
        assert.are.same({ ["Neil Gaiman"] = { "/a" }, ["Terry Pratchett"] = { "/a" } },
            shown(ViewOptions.filterAuthors(books, { status = { read = true } }, status_of)))
    end)

    it("Unread lists authors with no finished book at all, with all their books", function()
        assert.are.same({ ["Agatha Christie"] = { "/d" }, ["Mick Herron"] = { "/e" } },
            shown(ViewOptions.filterAuthors(books, { status = { unread = true } }, status_of)))
        -- Pratchett's finished book is Humour; filtering to Fantasy hides it,
        -- but he has still been read, so he is not Unread.
        local read_elsewhere = {
            { path = "/x", authors = "Terry Pratchett", keywords = "Humour" },
            { path = "/y", authors = "Terry Pratchett", keywords = "Fantasy" },
            { path = "/z", authors = "Neil Gaiman", keywords = "Fantasy" },
        }
        local s = { ["/x"] = "complete", ["/y"] = "new", ["/z"] = "new" }
        assert.are.same({ ["Neil Gaiman"] = { "/z" } },
            shown(ViewOptions.filterAuthors(read_elsewhere, { status = { unread = true }, keywords = "Fantasy" },
                function(path) return s[path] end)))
    end)

    it("New and Reading list books with that status; chosen statuses add up", function()
        assert.are.same({ ["Terry Pratchett"] = { "/b" }, ["Mick Herron"] = { "/e" },
                ["Neil Gaiman"] = { "/c" } },
            shown(ViewOptions.filterAuthors(books, { status = { new = true, reading = true } }, status_of)))
    end)

    it("keyword and language filters keep matching books, case-insensitive for languages", function()
        assert.are.same({ ["Terry Pratchett"] = { "/a", "/b" }, ["Neil Gaiman"] = { "/a" } },
            shown(ViewOptions.filterAuthors(books, { keywords = "Fantasy", language = "en" }, status_of)))
        assert.are.same({ { value = "Fantasy", count = 3 }, { value = "Humour", count = 1 },
                { value = "Mystery", count = 1 }, { value = "Thriller", count = 1 } },
            ViewOptions.valueCounts(books, "keywords"))
        local kept = ViewOptions.keptBooks(books, { status = { read = true } }, status_of)
        assert.are.equal(1, #kept)
        assert.are.equal("/a", kept[1].path)
    end)

    it("remembers the last sort and filters, dropping options no longer offered", function()
        assert.are.same({ sort = "first_name", reverse = false, filter = {}, name_position = "below" },
            ViewOptions.load())
        ViewOptions.save({ sort = "books", reverse = true, name_position = "on_photo",
            filter = { keywords = "Fantasy", status = { unread = true } } })
        local loaded = ViewOptions.load()
        assert.are.equal("books", loaded.sort)
        assert.is_true(loaded.reverse)
        assert.are.equal("on_photo", loaded.name_position)
        assert.are.equal("Unread · Keywords: Fantasy", ViewOptions.describe(loaded.filter))

        saved.authorinfo_view = { sort = "name", filter = { series = "Discworld",
            status = { abandoned = true, complete = true, read = true } } }
        assert.are.same({ sort = "first_name", reverse = false, filter = { status = { read = true } },
                name_position = "below" },
            ViewOptions.load())

        local filter = {}
        ViewOptions.toggleStatus(filter, "read")
        assert.are.same({ read = true }, filter.status)
        ViewOptions.toggleStatus(filter, "read")
        assert.is_nil(filter.status)
    end)
end)
