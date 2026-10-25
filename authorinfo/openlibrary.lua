-- Downloads an Open Library cover or author photo. covers.openlibrary.org
-- serves a photo either itself or by redirecting to archive.org, which may
-- redirect once more to one of its storage servers. The HTTP client never
-- follows redirects, so each hop is checked against an allow-list here, and
-- the download is asked for directly: a photo served by Open Library itself
-- (the usual case) then takes one request.
-- From ZenOS (GPL-3.0), modules/filebrowser/metadata/open_library.lua.

local Http = require("authorinfo/http")

local M = {}
local COVER_HOST = "covers.openlibrary.org"
local IMAGE_HEADERS = { ["Accept"] = "image/jpeg, image/png, image/webp, image/gif" }

-- next_hop(from_host, location) -> url, host of the redirect target when it
-- is the next step allowed after from_host; nil otherwise.
local function next_hop(from_host, location)
    if type(location) ~= "string" then return nil end
    if from_host == COVER_HOST then
        local prefix = "https://archive.org/download/"
        if location:sub(1, #prefix) == prefix then return location, "archive.org" end
        return nil
    end
    if from_host == "archive.org" then
        local host, path = location:match("^https://([^/]+)(/.*)$")
        local view_prefix = "/view_archive.php?archive=/"
        if host and host:match("^ia%d+%.us%.archive%.org$")
                and path:sub(1, #view_prefix) == view_prefix
                and path:find("&file=", 1, true) then
            return location, host
        end
    end
    return nil
end

-- downloadCover(url, destination, transport) -> destination | nil, err.
-- transport stubs the network in specs: transport(url, destination, host,
-- headers) -> destination | nil, err (err.kind "redirect" with err.location
-- to redirect).
function M.downloadCover(url, destination, transport)
    if type(url) ~= "string"
            or url:sub(1, #COVER_HOST + 9) ~= "https://" .. COVER_HOST .. "/" then
        return nil, Http.failure("malformed")
    end
    local host = COVER_HOST
    for _hop = 1, 3 do
        local path, err = Http.download(url, destination, host, IMAGE_HEADERS, transport)
        if path then return path end
        if not (type(err) == "table" and err.kind == "redirect") then
            if type(err) == "table" and err.status == 404 then
                return nil, Http.failure("no_match", 404)
            end
            return nil, err
        end
        url, host = next_hop(host, err.location)
        if not url then return nil, Http.failure("malformed") end
    end
    return nil, Http.failure("malformed")
end

return M
