describe("open library photo download", function()
    local OpenLibrary, requests

    before_each(function()
        package.loaded["authorinfo/openlibrary"] = nil
        OpenLibrary = require("authorinfo/openlibrary")
        requests = {}
    end)

    -- answers: url -> destination (served) | { location = ... } (redirect) | status
    local function transport(answers)
        return function(url, destination, host)
            requests[#requests + 1] = host .. " " .. url
            local answer = answers[url]
            if answer == true then return destination end
            if type(answer) == "table" then
                return nil, { kind = "redirect", status = 302, location = answer.location }
            end
            return nil, { kind = "network", status = answer or 404 }
        end
    end

    local PHOTO = "https://covers.openlibrary.org/a/olid/OL1A-L.jpg?default=false"
    local ARCHIVE = "https://archive.org/download/l_covers_0011/l_covers_0011_53.zip/0011538051-L.jpg"
    local STORAGE = "https://ia800100.us.archive.org/view_archive.php?archive=/1/items/l_covers_0011/l_covers_0011_53.zip&file=0011538051-L.jpg"

    it("downloads a photo Open Library serves itself in one request", function()
        assert.are.equal("/tmp/p.jpg", OpenLibrary.downloadCover(PHOTO, "/tmp/p.jpg", transport({ [PHOTO] = true })))
        assert.are.same({ "covers.openlibrary.org " .. PHOTO }, requests)
    end)

    it("follows the redirect to archive.org and on to its storage server", function()
        local path = OpenLibrary.downloadCover(PHOTO, "/tmp/p.jpg", transport({
            [PHOTO] = { location = ARCHIVE },
            [ARCHIVE] = { location = STORAGE },
            [STORAGE] = true,
        }))
        assert.are.equal("/tmp/p.jpg", path)
        assert.are.same({
            "covers.openlibrary.org " .. PHOTO,
            "archive.org " .. ARCHIVE,
            "ia800100.us.archive.org " .. STORAGE,
        }, requests)
    end)

    it("refuses redirects anywhere else, and reports a missing photo", function()
        local path, err = OpenLibrary.downloadCover(PHOTO, "/tmp/p.jpg", transport({
            [PHOTO] = { location = "https://evil.example/p.jpg" },
        }))
        assert.is_nil(path)
        assert.are.equal("malformed", err.kind)
        assert.are.equal(1, #requests)

        path, err = OpenLibrary.downloadCover(PHOTO, "/tmp/p.jpg", transport({
            [PHOTO] = { location = ARCHIVE },
            [ARCHIVE] = { location = "https://ia800100.us.archive.org/somewhere-else.jpg" },
        }))
        assert.is_nil(path)
        assert.are.equal("malformed", err.kind)

        path, err = OpenLibrary.downloadCover(PHOTO, "/tmp/p.jpg", transport({}))
        assert.is_nil(path)
        assert.are.equal("no_match", err.kind)

        assert.is_nil(OpenLibrary.downloadCover("https://covers.openlibrary.org.evil/x.jpg", "/tmp/p.jpg",
            transport({})))
    end)
end)
