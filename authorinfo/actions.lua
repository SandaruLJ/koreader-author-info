-- The ways a reader asks for author photos and information (author_images
-- and author_info do the finding and saving):
--
--   findPhoto(name, on_done)  -- an author's hold menu: their photo,
--                                replacing the one there.
--   findInfo(name, on_done)   -- an author's hold menu: their information,
--                                replacing what was there.
--   findMissing(names, on_done, what) -- every author missing a photo
--                                and/or information (what.photo, what.info),
--                                after a confirm that says how many.
--   clear(names, on_done, what) -- deletes the saved photos and/or
--                                information of the given authors, after a
--                                confirm.
--   remove(name, on_done)     -- an author's hold menu, when a photo is set.
--   showDetails(name, count)  -- "Author information", laid out like
--                                KOReader's "Book information".
--
-- Lookups wait for Wi-Fi the KOReader way (runWhenOnline asks; nothing
-- connects by itself) and run each author in a forked child, so the UI keeps
-- answering and tapping the progress message stops the work. Within a child,
-- the photo and information lookups share their first requests. The device
-- is kept awake while they run (hold_awake).

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template
local _ = require("gettext")
local logger = require("logger")

local M = {}

-- Consecutive authors that reached no source before the bulk pass gives up: a
-- dropped connection should cost a few seconds, not one timeout per author.
M.MAX_UNREACHABLE = 3

local function images()
    return require("authorinfo/author_images")
end

local function infos()
    return require("authorinfo/author_info")
end

local function unreachable_text()
    return _("Couldn't reach Open Library, Wikipedia or Wikidata.")
end

local function when_online(fn)
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        require("ui/trapper"):wrap(fn)
    end)
end

local function notify(on_done)
    images().invalidate()
    infos().invalidate()
    if type(on_done) == "function" then
        local ok, err = pcall(on_done)
        if not ok then logger.warn("authors: refresh after lookup failed", err) end
    end
end

-- lookup(Trapper, name, trap, want) -> completed, result. One author in a
-- forked child, which saves what it finds itself and answers with one line
-- per part: "<photo|info> <found|missed|skipped> <reason>".
--   result.photo / result.info: true when found
--   result.unreachable: no source answered for any part asked
--   result.no_storage: a part could not be saved
local function lookup(Trapper, name, trap, want)
    local completed, out = Trapper:dismissableRunInSubprocess(function()
        local session = {}
        local lines = {}
        if want.photo then
            local path, why = require("authorinfo/author_images").fetch(name, { session = session })
            lines[#lines + 1] = "photo " .. (path and "found" or "missed") .. " " .. tostring(why or "")
        end
        if want.info then
            local info, why = require("authorinfo/author_info").fetch(name, { session = session })
            lines[#lines + 1] = "info " .. (info and "found" or "missed") .. " " .. tostring(why or "")
        end
        return table.concat(lines, "\n")
    end, trap, true)
    if not completed then return false end
    local result, asked, unreachable = {}, 0, 0
    for part, what, why in tostring(out or ""):gmatch("(%a+) (%a+) ([^\n]*)") do
        asked = asked + 1
        if what == "found" then result[part] = true end
        if why == "unreachable" then unreachable = unreachable + 1 end
        if why == "no storage" then result.no_storage = true end
    end
    result.unreachable = asked > 0 and unreachable == asked
    return true, result
end

local function show_failure(result, name, what)
    local text
    if result.unreachable then
        text = unreachable_text()
    elseif result.no_storage then
        text = _("Couldn't save to the author images or information folder.")
    elseif what == "info" then
        text = T(_("No information found for %1."), name)
    else
        text = T(_("No photo found for %1."), name)
    end
    UIManager:show(InfoMessage:new{ text = text })
end

-- hold_awake(on): keeps the device from sleeping while lookups run (a pass
-- over a few hundred authors takes many minutes, with nobody touching the
-- screen), the way KOReader's Keep alive plugin does:
--   * KOReader's own auto-suspend waits (PluginShare.pause_auto_suspend),
--     and standby is prevented;
--   * on a Kindle, whose power daemon sleeps on its own after a while
--     without input, its screensaver is turned off, and
--     PluginShare.keepalive tells KOReader's auto-suspend to leave the
--     daemon's timer alone, as Keep alive does.
-- Holds nest; everything is put back when the last one is released. A Kindle
-- whose Keep alive is already on is left as it is.
local holds = 0
local saved = {}
local function hold_awake(on)
    local ok_share, PluginShare = pcall(require, "pluginshare")
    local ok_device, Device = pcall(require, "device")
    local kindle = ok_device and Device and type(Device.isKindle) == "function" and Device:isKindle()
    if on then
        holds = holds + 1
        if holds > 1 then return end
        if ok_share then
            saved.pause = PluginShare.pause_auto_suspend
            PluginShare.pause_auto_suspend = true
        end
        if kindle and ok_share and not PluginShare.keepalive then
            saved.kindle = true
            PluginShare.keepalive = true
            os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 1")
        end
        pcall(function() UIManager:preventStandby() end)
    else
        if holds == 0 then return end
        holds = holds - 1
        if holds > 0 then return end
        if ok_share then PluginShare.pause_auto_suspend = saved.pause end
        if saved.kindle then
            os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 0")
            if ok_share then PluginShare.keepalive = false end
        end
        saved = {}
        pcall(function() UIManager:allowStandby() end)
    end
end
M._hold_awake = hold_awake -- for specs

-- find(name, want, on_done): one author, with a message while it runs.
local function find(name, want, on_done)
    if type(name) ~= "string" or name == "" or images().isPlaceholder(name) then return end
    when_online(function()
        local Trapper = require("ui/trapper")
        local notice = InfoMessage:new{
            text = want.photo and T(_("Looking for a photo of %1…"), name)
                or T(_("Looking for information about %1…"), name),
        }
        UIManager:show(notice)
        UIManager:forceRePaint()
        hold_awake(true)
        local completed, result = lookup(Trapper, name, notice, want)
        hold_awake(false)
        UIManager:close(notice)
        if not completed then return end
        if result.photo or result.info then
            notify(on_done)
        else
            show_failure(result, name, want.photo and "photo" or "info")
        end
    end)
end

function M.findPhoto(name, on_done)
    find(name, { photo = true }, on_done)
end

function M.findInfo(name, on_done)
    find(name, { info = true }, on_done)
end

local running = false

-- plan(names, what) -> { {name, photo, info}, ... }: what each author is
-- missing, of the kinds asked for (what.photo, what.info).
function M.plan(names, what)
    what = what or { photo = true, info = true }
    local AuthorImages, AuthorInfo = images(), infos()
    local todo = {}
    for _i, name in ipairs(names or {}) do
        if type(name) == "string" and not AuthorImages.isPlaceholder(name) then
            local photo = what.photo and not AuthorImages.has(name) or false
            local info = what.info and not AuthorInfo.has(name) or false
            if photo or info then todo[#todo + 1] = { name = name, photo = photo, info = info } end
        end
    end
    return todo
end

-- run(todo, on_done) -- the bulk pass itself, once confirmed.
function M.run(todo, on_done)
    if #todo == 0 then return end
    if running then
        UIManager:show(InfoMessage:new{
            text = _("Author images are already being fetched."), timeout = 3 })
        return
    end
    when_online(function()
        local Trapper = require("ui/trapper")
        running = true
        hold_awake(true)
        local photos_found, photos_asked, infos_found, infos_asked = 0, 0, 0, 0
        local asked, unreachable_run = 0, 0
        local stopped, offline = false, false
        local notice
        local ok_run, err_run = xpcall(function()
            for index, entry in ipairs(todo) do
                local previous = notice
                notice = InfoMessage:new{
                    text = T(_("Looking up authors: %1 of %2"), index, #todo)
                        .. "\n" .. entry.name .. "\n\n" .. _("Tap to stop."),
                }
                UIManager:show(notice)
                if previous then UIManager:close(previous) end
                UIManager:forceRePaint()
                local completed, result = lookup(Trapper, entry.name, notice, entry)
                if not completed then stopped = true; break end
                asked = asked + 1
                if entry.photo then
                    photos_asked = photos_asked + 1
                    if result.photo then photos_found = photos_found + 1 end
                end
                if entry.info then
                    infos_asked = infos_asked + 1
                    if result.info then infos_found = infos_found + 1 end
                end
                if result.unreachable then
                    unreachable_run = unreachable_run + 1
                    if unreachable_run >= M.MAX_UNREACHABLE then offline = true; break end
                else
                    unreachable_run = 0
                end
                if result.no_storage then break end
            end
        end, debug.traceback)
        if notice then UIManager:close(notice) end
        hold_awake(false)
        running = false
        if not ok_run then logger.warn("authors: lookup pass failed", err_run) end
        if photos_found + infos_found > 0 then notify(on_done) end
        local lines = {}
        if photos_asked > 0 then
            lines[#lines + 1] = T(_("Found images for %1 of %2 authors."), photos_found, photos_asked)
        end
        if infos_asked > 0 then
            lines[#lines + 1] = T(_("Found information about %1 of %2 authors."), infos_found, infos_asked)
        end
        local text = table.concat(lines, "\n")
        if offline then
            text = text .. "\n\n" .. unreachable_text()
        elseif stopped and asked < #todo then
            text = text .. "\n\n" .. T(_("Stopped before %1 more."), #todo - asked)
        end
        UIManager:show(InfoMessage:new{ text = text })
    end)
end

function M.findMissing(names, on_done, what)
    what = what or { photo = true, info = true }
    local todo = M.plan(names, what)
    if #todo == 0 then
        local any_author = false
        for _i, name in ipairs(names or {}) do
            if not images().isPlaceholder(name) then any_author = true; break end
        end
        local done = (what.photo and what.info) and _("Every author already has an image and information.")
            or what.photo and _("Every author already has an image.")
            or _("Every author already has information.")
        UIManager:show(InfoMessage:new{
            text = any_author and done or _("No authors found."),
            timeout = 3,
        })
        return
    end
    local photos, info = 0, 0
    for _i, entry in ipairs(todo) do
        if entry.photo then photos = photos + 1 end
        if entry.info then info = info + 1 end
    end
    local lines = { T(_("Look up %1 authors online?"), #todo), "" }
    if what.photo then lines[#lines + 1] = T(_("Missing photos: %1"), photos) end
    if what.info then lines[#lines + 1] = T(_("Missing information: %1"), info) end
    lines[#lines + 1] = ""
    if what.photo then lines[#lines + 1] = _("Photos come from Open Library or Wikipedia.") end
    if what.info then lines[#lines + 1] = _("Information comes from Wikipedia, Open Library and Wikidata.") end
    lines[#lines + 1] = _("What you already have is kept.")
    UIManager:show(ConfirmBox:new{
        text = table.concat(lines, "\n"),
        ok_text = _("Look up"),
        ok_callback = function() M.run(todo, on_done) end,
    })
end

-- clear(names, on_done, what): deletes the saved photos (what.photo) and/or
-- information (what.info) of the given authors, after a confirm. Find
-- missing then looks them up afresh.
function M.clear(names, on_done, what)
    local photos, info, targets = 0, 0, {}
    for _i, name in ipairs(names or {}) do
        if type(name) == "string" then
            local photo = what.photo and images().has(name)
            local has_info = what.info and infos().has(name)
            if photo then photos = photos + 1 end
            if has_info then info = info + 1 end
            if photo or has_info then targets[#targets + 1] = name end
        end
    end
    if #targets == 0 then
        UIManager:show(InfoMessage:new{ text = _("There is nothing saved to clear."), timeout = 3 })
        return
    end
    local lines = { T(_("Delete what is saved for %1 authors?"), #targets), "" }
    if what.photo then lines[#lines + 1] = T(_("Photos: %1"), photos) end
    if what.info then lines[#lines + 1] = T(_("Information: %1"), info) end
    if what.photo then
        lines[#lines + 1] = ""
        lines[#lines + 1] = _("This includes photos you put in the folder yourself.")
    end
    UIManager:show(ConfirmBox:new{
        text = table.concat(lines, "\n"),
        ok_text = _("Delete"),
        ok_callback = function()
            for _i, name in ipairs(targets) do
                if what.photo then images().remove(name) end
                if what.info then infos().remove(name) end
            end
            notify(on_done)
        end,
    })
end

function M.remove(name, on_done)
    if images().remove(name) then notify(on_done) end
end

local function list(values)
    return type(values) == "table" and #values > 0 and table.concat(values, ", ") or nil
end

-- showDetails(name, book_count): "Author information", built like KOReader's
-- "Book information": a key/value page, the photo behind "Tap to display" as
-- the cover image is, and the bio opening in a text viewer as the
-- description does. Long values show in full when tapped.
function M.showDetails(name, book_count)
    local info = infos().load(name) or {}
    local photo = images().path(name)
    local n_a = _("N/A")
    local kv_pairs = {
        { _("Name:"), name },
        { _("Born:"), info.born or n_a },
        { _("Died:"), info.died or n_a },
        { _("Country:"), list(info.countries) or n_a },
        { _("Genres:"), list(info.genres) or n_a },
        { _("Notable works:"), list(info.works) or n_a },
        { _("Bio:"), info.bio or n_a,
            callback = info.bio and function()
                UIManager:show(require("ui/widget/textviewer"):new{
                    title = _("Bio"),
                    text = info.bio,
                    text_type = "book_info",
                })
            end or nil,
            separator = true,
        },
        -- The photo in a section of its own, as the cover image is in Book
        -- information.
        { _("Photo:"), photo and _("Tap to display") or n_a,
            callback = photo and function()
                UIManager:show(require("ui/widget/imageviewer"):new{
                    file = photo,
                    with_title_bar = false,
                    fullscreen = true,
                })
            end or nil,
            separator = true,
        },
    }
    if book_count then
        kv_pairs[#kv_pairs + 1] = { _("Books in library:"), tostring(book_count) }
    end
    kv_pairs[#kv_pairs + 1] = { _("Sources:"), infos().sourcesText(info) or n_a }
    UIManager:show(require("ui/widget/keyvaluepage"):new{
        title = _("Author information"),
        value_overflow_align = "right",
        kv_pairs = kv_pairs,
    })
end

-- holdButtons(name, close_dialog, on_done, book_count) -> ButtonDialog rows
-- for an author's hold menu.
function M.holdButtons(name, close_dialog, on_done, book_count)
    if type(name) ~= "string" or name == "" or images().isPlaceholder(name) then
        return {}
    end
    local rows = {{{
        text = _("Author information"),
        callback = function()
            close_dialog()
            M.showDetails(name, book_count)
        end,
    }}}
    -- The information's entries, then the photo's.
    rows[#rows + 1] = {{
        text = infos().has(name) and _("Replace author information online")
            or _("Find author information online"),
        callback = function()
            close_dialog()
            M.findInfo(name, on_done)
        end,
    }}
    local has_photo = images().has(name)
    rows[#rows + 1] = {{
        text = has_photo and _("Replace author image online") or _("Find author image online"),
        callback = function()
            close_dialog()
            M.findPhoto(name, on_done)
        end,
    }}
    if has_photo then
        rows[#rows + 1] = {{
            text = _("Remove author image"),
            callback = function()
                close_dialog()
                M.remove(name, on_done)
            end,
        }}
    end
    return rows
end

return M
