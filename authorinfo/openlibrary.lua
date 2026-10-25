-- Downloads an Open Library cover or author photo. covers.openlibrary.org
-- answers either directly or with a redirect to archive.org; the HTTP client
-- never follows redirects, so each hop is checked against an allow-list here.
-- From ZenOS (GPL-3.0), modules/filebrowser/metadata/open_library.lua.

local Http = require("authorinfo/http")

local M = {}
local COVER_HOST = "covers.openlibrary.org"

local function header_value(headers, wanted)
    wanted = wanted:lower()
    for key, value in pairs(type(headers) == "table" and headers or {}) do
        if type(key) == "string" and key:lower() == wanted then return value end
    end
end

local function redirect_status(status)
    return status == 301 or status == 302 or status == 307 or status == 308
end

-- head(url, host) -> false (served here) | redirect location | nil, err
local function head(url, host)
    local response, err = Http.request{
        url = url,
        host = host,
        method = "HEAD",
        headers = { ["Accept"] = "image/jpeg" },
    }
    if not response then return nil, err end
    local status = tonumber(response.status)
    if status == 200 then return false end
    if redirect_status(status) then
        return header_value(response.headers, "location") or ""
    end
    if status == 404 then return nil, Http.failure("no_match", status) end
    if status == 429 then return nil, Http.failure("rate_limited", status) end
    if status and status >= 500 then return nil, Http.failure("server", status) end
    return nil, Http.failure("network", status)
end

local function resolved_cover(url)
    local redirect, err = head(url, COVER_HOST)
    if redirect == nil then return nil, nil, err end
    if redirect == false then return url, COVER_HOST end
    local archive_prefix = "https://archive.org/download/"
    if redirect:sub(1, #archive_prefix) ~= archive_prefix then
        return nil, nil, Http.failure("malformed")
    end
    local final, archive_err = head(redirect, "archive.org")
    if final == nil then return nil, nil, archive_err end
    if final == false then return redirect, "archive.org" end
    local host, path = final:match("^https://([^/]+)(/.*)$")
    local view_prefix = "/view_archive.php?archive=/"
    if not host or not host:match("^ia%d+%.us%.archive%.org$")
            or path:sub(1, #view_prefix) ~= view_prefix
            or not path:find("&file=", 1, true) then
        return nil, nil, Http.failure("malformed")
    end
    return final, host
end

-- downloadCover(url, destination, transport) -> destination | nil, err.
-- transport stubs the network in specs (and skips redirect resolution).
function M.downloadCover(url, destination, transport)
    if type(url) ~= "string"
            or url:sub(1, #COVER_HOST + 9) ~= "https://" .. COVER_HOST .. "/" then
        return nil, Http.failure("malformed")
    end
    local host = COVER_HOST
    if not transport then
        local resolved, resolved_host, err = resolved_cover(url)
        if not resolved then return nil, err end
        url, host = resolved, resolved_host
    end
    return Http.download(url, destination, host, {
        ["Accept"] = "image/jpeg, image/png, image/webp, image/gif",
    }, transport)
end

return M
