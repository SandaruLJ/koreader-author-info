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
--   prune(names, on_done)     -- deletes the saved photos and information of
--                                authors not among names (the library's),
--                                after a confirm.
--   remove(name, on_done, what) -- an author's hold menu: deletes their
--                                photo or information (what.photo,
--                                what.info), after a confirm.
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
local N_ = _.ngettext
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

local function busy_text()
    return _("Open Library or Wikipedia is busy. Try again in a few minutes.")
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
        if why == "rate_limited" then result.limited = true end
        if why == "incomplete" then result.incomplete = true end
    end
    result.unreachable = asked > 0 and unreachable == asked
    return true, result
end

local function show_failure(result, name, what)
    local text
    if result.unreachable then
        text = unreachable_text()
    elseif result.limited then
        text = busy_text()
    elseif result.incomplete then
        text = T(_("Couldn't get a complete answer about %1. Try again later."), name)
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

-- How long a pass waits when a source is still rate limiting, before
-- trying that step once more.
M.RATE_LIMIT_PAUSE = 60

-- The bulk pass goes in three phases (see author_info's stages), each step a
-- forked child:
--   1. per author: the photo, and the start of the information lookup
--      (Open Library, Wikipedia's page) as a job;
--   2. Wikidata for the jobs, AuthorInfo's batch size at a time;
--   3. per author: the bio, and saving the information.
-- A step a source is still rate limiting is tried once more after a pause;
-- if it is limited again, the pass stops.

-- progress(state, text): shows the progress message, replacing the one before.
local function progress(state, text)
    local previous = state.notice
    state.notice = InfoMessage:new{ text = text .. "\n\n" .. _("Tap to stop.") }
    UIManager:show(state.notice)
    if previous then UIManager:close(previous) end
    UIManager:forceRePaint()
end

-- pause(Trapper, state) -> false when stopped during the wait.
local function pause(Trapper, state)
    progress(state, T(_("Open Library or Wikipedia asked to slow down. Waiting %1 seconds…"),
        M.RATE_LIMIT_PAUSE))
    local completed = Trapper:dismissableRunInSubprocess(function()
        require("ffi/util").sleep(M.RATE_LIMIT_PAUSE)
        return "done"
    end, state.notice, true)
    return completed
end

-- attempt(Trapper, state, text, step) -> completed, result. Shows text,
-- then step() runs one step and returns completed, result; result.limited
-- asks for another try.
local function attempt(Trapper, state, text, step)
    progress(state, text)
    local completed, result = step()
    if completed and result.limited then
        if not pause(Trapper, state) then return false end
        progress(state, text)
        completed, result = step()
    end
    return completed, result
end

-- Phase 1: photo and job of one author.
local function begin_step(Trapper, entry, trap)
    local completed, out = Trapper:dismissableRunInSubprocess(function()
        local session = {}
        local lines = {}
        if entry.photo then
            local path, why = require("authorinfo/author_images").fetch(entry.name, { session = session })
            lines[#lines + 1] = "photo " .. (path and "found" or "missed") .. " " .. tostring(why or "")
        end
        if entry.info then
            local job, why = require("authorinfo/author_info").begin(entry.name, { session = session })
            lines[#lines + 1] = job and ("job " .. require("json").encode(job))
                or ("info missed " .. tostring(why or ""))
        end
        return table.concat(lines, "\n")
    end, trap, true)
    if not completed then return false end
    local result = {}
    out = tostring(out or "")
    local photo_why = out:match("photo %a+ ([^\n]*)")
    if out:match("photo found") then result.photo = true end
    local encoded = out:match("job ([^\n]*)")
    if encoded then
        local ok, job = pcall(require("json").decode, encoded)
        if ok and type(job) == "table" and type(job.state) == "table" then result.job = job end
    end
    local job_state = result.job and result.job.state
    result.info_why = out:match("info missed ([^\n]*)")
        or (entry.info and not result.job and "malformed") or nil
    result.limited = photo_why == "rate_limited" or (job_state and job_state.limited) or false
    result.no_storage = photo_why == "no storage"
    local photo_unreachable = not entry.photo or photo_why == "unreachable"
    local info_unreachable = not entry.info or (job_state and not job_state.answered)
        or result.info_why == "unreachable"
    result.unreachable = photo_unreachable and info_unreachable and true or false
    return true, result
end

-- Phase 2: Wikidata for some jobs, which come back with it added.
local function wikidata_step(Trapper, jobs, trap)
    local completed, out = Trapper:dismissableRunInSubprocess(function()
        local state = require("authorinfo/author_info").addWikidata(jobs, {})
        return require("json").encode({ jobs = jobs, limited = state and state.limited or false })
    end, trap, true)
    if not completed then return false end
    local ok, decoded = pcall(require("json").decode, tostring(out or ""))
    if not ok or type(decoded) ~= "table" or type(decoded.jobs) ~= "table" then
        return true, { jobs = jobs } -- as they were: finish still finds the rest
    end
    return true, { jobs = decoded.jobs, limited = decoded.limited == true }
end

-- Phase 3: the bio, and the information saved.
local function finish_step(Trapper, job, trap)
    local completed, out = Trapper:dismissableRunInSubprocess(function()
        local info, why = require("authorinfo/author_info").finish(job, {})
        return info and "found" or ("missed " .. tostring(why or ""))
    end, trap, true)
    if not completed then return false end
    out = tostring(out or "")
    local why = out:match("^missed (.*)$")
    return true, {
        info = out == "found",
        limited = why == "rate_limited",
        unreachable = why == "unreachable",
        no_storage = why == "no storage",
    }
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
        local state = {}
        local photos_found, photos_asked, infos_found, infos_asked = 0, 0, 0, 0
        local unreachable_run = 0
        local stopped, offline, busy, no_storage = false, false, false, false
        local done = 0 -- authors through phase 1
        local jobs = {}

        -- A step's outcome: false when the pass should stop.
        local function outcome(completed, result)
            if not completed then stopped = true; return false end
            if result.limited then busy = true; return false end
            if result.no_storage then no_storage = true; return false end
            if result.unreachable then
                unreachable_run = unreachable_run + 1
                if unreachable_run >= M.MAX_UNREACHABLE then offline = true; return false end
            else
                unreachable_run = 0
            end
            return true
        end

        local ok_run, err_run = xpcall(function()
            for index, entry in ipairs(todo) do
                local completed, result = attempt(Trapper, state,
                        T(_("Looking up authors: %1 of %2"), index, #todo) .. "\n" .. entry.name, function()
                    return begin_step(Trapper, entry, state.notice)
                end)
                if completed and entry.photo then
                    photos_asked = photos_asked + 1
                    if result.photo then photos_found = photos_found + 1 end
                end
                if completed and not result.limited then
                    if entry.info then
                        infos_asked = infos_asked + 1
                        if result.job then jobs[#jobs + 1] = result.job end
                    end
                    done = index
                end
                if not outcome(completed, result) then return end
            end

            local batch_size = require("authorinfo/author_info").WD_BATCH
            for start = 1, #jobs, batch_size do
                local batch = {}
                for i = start, math.min(#jobs, start + batch_size - 1) do batch[#batch + 1] = jobs[i] end
                local completed, result = attempt(Trapper, state, _("Looking up authors on Wikidata…"), function()
                    return wikidata_step(Trapper, batch, state.notice)
                end)
                if not outcome(completed, result) then return end
                for i, job in ipairs(result.jobs) do jobs[start + i - 1] = job end
            end

            unreachable_run = 0
            for index, job in ipairs(jobs) do
                local completed, result = attempt(Trapper, state,
                        T(_("Looking up bios: %1 of %2"), index, #jobs) .. "\n" .. job.name, function()
                    return finish_step(Trapper, job, state.notice)
                end)
                if completed and result.info then infos_found = infos_found + 1 end
                if not outcome(completed, result) then return end
            end
        end, debug.traceback)
        if state.notice then UIManager:close(state.notice) end
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
        local parts = { #lines > 0 and table.concat(lines, "\n") or nil }
        local unfinished = stopped or busy or offline or no_storage or not ok_run
        if offline then
            parts[#parts + 1] = unreachable_text()
        elseif busy then
            parts[#parts + 1] = busy_text()
        elseif no_storage then
            parts[#parts + 1] = _("Couldn't save to the author images or information folder.")
        end
        if unfinished and done < #todo then
            parts[#parts + 1] = T(_("Stopped before %1 more."), #todo - done)
        elseif unfinished and infos_asked > infos_found then
            parts[#parts + 1] = _("Stopped before saving all the information.")
        end
        UIManager:show(InfoMessage:new{ text = #parts > 0 and table.concat(parts, "\n\n") or _("Stopped.") })
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

-- orphans(names) -> { photos = {stems}, infos = {stems} }: what is saved for
-- authors not among names. Files are matched by stem, as path() finds them.
function M.orphans(names)
    local keep = {}
    for _i, name in ipairs(names or {}) do
        local stem = images().fileStem(name)
        if stem then keep[stem:lower()] = true end
    end
    local function stray(stems)
        local list = {}
        for _i, stem in ipairs(stems) do
            if not keep[stem:lower()] then list[#list + 1] = stem end
        end
        table.sort(list)
        return list
    end
    return { photos = stray(images().savedStems()), infos = stray(infos().savedStems()) }
end

-- prune(names, on_done): as Cover browser's "Prune cache of removed books",
-- for authors who no longer have books in the library.
function M.prune(names, on_done)
    local orphans = M.orphans(names)
    local authors, count = {}, 0
    for _i, list in ipairs({ orphans.photos, orphans.infos }) do
        for _j, stem in ipairs(list) do
            if not authors[stem:lower()] then
                authors[stem:lower()] = true
                count = count + 1
            end
        end
    end
    if count == 0 then
        UIManager:show(InfoMessage:new{ text = _("There is nothing to prune."), timeout = 3 })
        return
    end
    local lines = {
        T(N_("Prune the saved images and information of 1 author who no longer has books in the library?",
            "Prune the saved images and information of %1 authors who no longer have books in the library?",
            count), count),
        "",
        T(_("Images: %1"), #orphans.photos),
        T(_("Information: %1"), #orphans.infos),
    }
    if #orphans.photos > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = _("This includes images you put in the folder yourself.")
    end
    UIManager:show(ConfirmBox:new{
        text = table.concat(lines, "\n"),
        ok_text = _("Prune"),
        ok_callback = function()
            for _i, stem in ipairs(orphans.photos) do images().remove(stem) end
            for _i, stem in ipairs(orphans.infos) do infos().remove(stem) end
            notify(on_done)
        end,
    })
end

function M.remove(name, on_done, what)
    local text = what.photo
        and T(_("Remove the image of %1?\n\nAn image you put in the folder yourself can't be found again online."),
            name)
        or T(_("Remove the information about %1?"), name)
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = _("Remove"),
        ok_callback = function()
            local removed = what.photo and images().remove(name) or what.info and infos().remove(name)
            if removed then notify(on_done) end
        end,
    })
end

-- The photo full screen, as Book information's cover image.
local function show_photo(path)
    UIManager:show(require("ui/widget/imageviewer"):new{
        file = path,
        with_title_bar = false,
        fullscreen = true,
    })
end

local function list(values)
    return type(values) == "table" and #values > 0 and table.concat(values, ", ") or nil
end

-- showDetails(name, book_count): "Author information", built like KOReader's
-- "Book information": a key/value page, the photo behind "Tap to display" as
-- the cover image is, and the bio opening in a text viewer as the
-- description does. Tapping Sources opens the author's full Wikipedia page in
-- KOReader's Wikipedia viewer. Long values show in full when tapped.
function M.showDetails(name, book_count)
    local info = infos().load(name) or {}
    local photo = images().path(name)
    local n_a = _("N/A")
    local kv_pairs = {
        { _("Name:"), name },
        { _("Born:"), info.born or n_a },
        { _("Died:"), info.died or n_a },
        { _("Country:"), list(info.countries) or n_a },
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
            callback = photo and function() show_photo(photo) end or nil,
            separator = true,
        },
    }
    if book_count then
        kv_pairs[#kv_pairs + 1] = { _("Books in library:"), tostring(book_count) }
    end
    local page = type(info.wikipedia) == "table" and info.wikipedia.title and info.wikipedia
    kv_pairs[#kv_pairs + 1] = { _("Sources:"), infos().sourcesText(info) or n_a,
        callback = page and function()
            local ui = require("apps/reader/readerui").instance or require("apps/filemanager/filemanager").instance
            if ui and ui.wikipedia then ui.wikipedia:onLookupWikipedia(page.title, true, nil, true, page.lang) end
        end or nil,
    }
    UIManager:show(require("ui/widget/keyvaluepage"):new{
        title = _("Author information"),
        value_overflow_align = "right",
        kv_pairs = kv_pairs,
    })
end

-- holdButtons(name, close_dialog, on_done, book_count) -> ButtonDialog rows
-- for an author's hold menu: view, find or replace, and remove, each with the
-- information beside the image. Buttons with nothing to act on are greyed
-- out, as KOReader's book hold menu does with Book cover.
function M.holdButtons(name, close_dialog, on_done, book_count)
    if type(name) ~= "string" or name == "" or images().isPlaceholder(name) then
        return {}
    end
    local has_info, has_photo = infos().has(name), images().has(name)
    local function button(text, enabled, fn)
        return {
            text = text,
            enabled = enabled,
            callback = function()
                close_dialog()
                fn()
            end,
        }
    end
    return {
        {
            button(_("View information"), true, function() M.showDetails(name, book_count) end),
            button(_("View image"), has_photo, function() show_photo(images().path(name)) end),
        },
        {
            button(has_info and _("Replace information") or _("Find information"), true,
                function() M.findInfo(name, on_done) end),
            button(has_photo and _("Replace image") or _("Find image"), true,
                function() M.findPhoto(name, on_done) end),
        },
        {
            button(_("Remove information"), has_info, function() M.remove(name, on_done, { info = true }) end),
            button(_("Remove image"), has_photo, function() M.remove(name, on_done, { photo = true }) end),
        },
    }
end

return M
