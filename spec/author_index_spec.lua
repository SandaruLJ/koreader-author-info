describe("author index", function()
    local AuthorIndex
    local existing

    before_each(function()
        existing = {}
        package.loaded["libs/libkoreader-lfs"] = {
            attributes = function(path, field)
                if existing[path] then return field == "mode" and "file" or { mode = "file" } end
            end,
        }
        package.loaded["ffi/util"] = { strcoll = function(a, b) return a < b end }
        package.loaded["authors_lib/author_index"] = nil
        AuthorIndex = require("authors_lib/author_index")
        _G.G_reader_settings = { readSetting = function() return "/books/" end }
    end)

    it("splits one name per line, keeps commas, trims and drops duplicates", function()
        assert.are.same({ "Terry Pratchett", "Neil Gaiman", "Le Guin, Ursula K." },
            AuthorIndex.splitAuthors(" Terry Pratchett \n\nNeil Gaiman\nLe Guin, Ursula K.\nNeil Gaiman"))
        assert.are.same({}, AuthorIndex.splitAuthors(nil))
    end)

    it("lists each book under every author, sorted, inside the home folder only", function()
        for _i, p in ipairs({ "/books/a.epub", "/books/b.epub", "/elsewhere/c.epub" }) do existing[p] = true end
        local authors = AuthorIndex.getAuthors(AuthorIndex.getBooks({
            { path = "/books/a.epub", authors = "Terry Pratchett\nNeil Gaiman" },
            { path = "/books/b.epub", authors = "Neil Gaiman" },
            { path = "/books/deleted.epub", authors = "Ghost Writer" },
            { path = "/elsewhere/c.epub", authors = "Outside Author" },
        }))
        assert.are.same({
            { name = "Neil Gaiman", files = { "/books/a.epub", "/books/b.epub" } },
            { name = "Terry Pratchett", files = { "/books/a.epub" } },
        }, authors)
    end)

    it("lists only the books a filter keeps", function()
        local books = {
            { path = "/books/a.epub", authors = "Terry Pratchett\nNeil Gaiman" },
            { path = "/books/b.epub", authors = "Neil Gaiman" },
        }
        local authors = AuthorIndex.getAuthors(books, function(book) return book.path == "/books/b.epub" end)
        assert.are.same({ { name = "Neil Gaiman", files = { "/books/b.epub" } } }, authors)
    end)
end)
