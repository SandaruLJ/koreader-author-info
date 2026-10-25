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
        package.loaded["authors_lib/author_index"] = nil
        package.loaded["authors_lib/view_options"] = nil
        ViewOptions = require("authors_lib/view_options")
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

    it("sorts by name, last name, number of books and recent reading", function()
        local authors = function()
            return {
                { name = "Terry Pratchett", files = { "/a", "/b", "/c" } },
                { name = "Le Guin, Ursula K.", files = { "/d" } },
                { name = "Neil Gaiman", files = { "/a", "/e" } },
            }
        end
        assert.are.same({ "Le Guin, Ursula K.", "Neil Gaiman", "Terry Pratchett" },
            names(ViewOptions.sort(authors(), { sort = "name" })))
        assert.are.same({ "Neil Gaiman", "Le Guin, Ursula K.", "Terry Pratchett" },
            names(ViewOptions.sort(authors(), { sort = "last_name" })))
        assert.are.same({ "Terry Pratchett", "Neil Gaiman", "Le Guin, Ursula K." },
            names(ViewOptions.sort(authors(), { sort = "books" })))
        assert.are.same({ "Le Guin, Ursula K.", "Neil Gaiman", "Terry Pratchett" },
            names(ViewOptions.sort(authors(), { sort = "recent" }, { ["/d"] = 300, ["/e"] = 200, ["/a"] = 100 })))
        assert.are.same({ "Terry Pratchett", "Neil Gaiman", "Le Guin, Ursula K." },
            names(ViewOptions.sort(authors(), { sort = "name", reverse = true })))
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
        assert.are.same({ sort = "name", reverse = false, filter = {} }, ViewOptions.load())
        ViewOptions.save({ sort = "books", reverse = true, filter = { keywords = "Fantasy", status = { unread = true } } })
        local loaded = ViewOptions.load()
        assert.are.equal("books", loaded.sort)
        assert.is_true(loaded.reverse)
        assert.are.equal("Unread · Keywords: Fantasy", ViewOptions.describe(loaded.filter))

        saved.authors_view = { sort = "first_name", filter = { series = "Discworld",
            status = { abandoned = true, complete = true, read = true } } }
        assert.are.same({ sort = "name", reverse = false, filter = { status = { read = true } } },
            ViewOptions.load())

        local filter = {}
        ViewOptions.toggleStatus(filter, "read")
        assert.are.same({ read = true }, filter.status)
        ViewOptions.toggleStatus(filter, "read")
        assert.is_nil(filter.status)
    end)
end)
