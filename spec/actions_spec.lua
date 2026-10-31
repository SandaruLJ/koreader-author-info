describe("actions", function()
    local Actions, PluginShare, executed, standby, kindle, has_photo, has_info

    before_each(function()
        executed, standby, kindle = {}, 0, false
        has_photo, has_info = {}, {}
        PluginShare = {}
        package.loaded["pluginshare"] = PluginShare
        package.loaded["device"] = { isKindle = function() return kindle end }
        package.loaded["ui/uimanager"] = {
            preventStandby = function() standby = standby + 1 end,
            allowStandby = function() standby = standby - 1 end,
        }
        package.loaded["ui/widget/confirmbox"] = {}
        package.loaded["ui/widget/infomessage"] = {}
        package.loaded["authorinfo/author_images"] = {
            isPlaceholder = function(name) return name == "Anonymous" end,
            has = function(name) return has_photo[name] == true end,
            fileStem = function(name) return (name:gsub(",", "-")) end,
            savedStems = function()
                local stems = {}
                for name in pairs(has_photo) do stems[#stems + 1] = name end
                return stems
            end,
        }
        package.loaded["authorinfo/author_info"] = {
            has = function(name) return has_info[name] == true end,
            savedStems = function()
                local stems = {}
                for name in pairs(has_info) do stems[#stems + 1] = name end
                return stems
            end,
        }
        _G.os_execute_orig = _G.os_execute_orig or os.execute
        os.execute = function(command) executed[#executed + 1] = command end
        package.loaded["authorinfo/actions"] = nil
        Actions = require("authorinfo/actions")
    end)

    after_each(function()
        os.execute = _G.os_execute_orig
    end)

    it("plans only the kinds asked for, skipping placeholders and what is there", function()
        has_photo["Saki"], has_info["Terry Pratchett"] = true, true
        local names = { "Saki", "Terry Pratchett", "Anonymous" }
        assert.are.same({ { name = "Terry Pratchett", photo = true, info = false } },
            Actions.plan(names, { photo = true }))
        assert.are.same({ { name = "Saki", photo = false, info = true } },
            Actions.plan(names, { info = true }))
        assert.are.same({
            { name = "Saki", photo = false, info = true },
            { name = "Terry Pratchett", photo = true, info = false },
        }, Actions.plan(names, { photo = true, info = true }))
    end)

    it("finds what is saved for authors no longer in the library, by file stem and any case", function()
        has_photo["Saki"], has_photo["saki"], has_photo["Le Guin- Ursula"], has_photo["Gone"] = true, true, true, true
        has_info["Saki"], has_info["Also Gone"] = true, true
        assert.are.same({ photos = { "Gone" }, infos = { "Also Gone" } },
            Actions.orphans({ "Saki", "Le Guin, Ursula" }))
        assert.are.same({ photos = {}, infos = {} },
            Actions.orphans({ "Saki", "saki", "Le Guin, Ursula", "Gone", "Also Gone" }))
    end)

    it("lays out view, find or replace, and remove, greying out what has nothing to act on", function()
        local function grid(rows)
            local list = {}
            for _i, row in ipairs(rows) do
                local texts = {}
                for _j, button in ipairs(row) do
                    texts[#texts + 1] = button.enabled and button.text or "(" .. button.text .. ")"
                end
                list[#list + 1] = texts
            end
            return list
        end
        local noop = function() end
        assert.are.same({
            { "View information", "(View image)" },
            { "Find information", "Find image" },
            { "(Remove information)", "(Remove image)" },
        }, grid(Actions.holdButtons("Saki", noop, noop, { "/a" })))
        has_photo["Saki"], has_info["Saki"] = true, true
        assert.are.same({
            { "View information", "View image" },
            { "Replace information", "Replace image" },
            { "Remove information", "Remove image" },
        }, grid(Actions.holdButtons("Saki", noop, noop, { "/a" })))
        assert.are.same({}, Actions.holdButtons("Anonymous", noop, noop, { "/a" }))
    end)

    it("keeps KOReader awake while held, and puts everything back after the last release", function()
        PluginShare.pause_auto_suspend = false
        Actions._hold_awake(true)
        assert.is_true(PluginShare.pause_auto_suspend)
        assert.are.equal(1, standby)
        Actions._hold_awake(true) -- a single lookup during a pass
        Actions._hold_awake(false)
        assert.is_true(PluginShare.pause_auto_suspend, "still held by the pass")
        Actions._hold_awake(false)
        assert.is_false(PluginShare.pause_auto_suspend)
        assert.are.equal(0, standby)
        assert.are.same({}, executed, "no Kindle commands elsewhere")
        Actions._hold_awake(false) -- an extra release changes nothing
        assert.are.equal(0, standby)
    end)

    it("turns a Kindle's screensaver off while held, as Keep alive does", function()
        kindle = true
        Actions._hold_awake(true)
        assert.is_true(PluginShare.keepalive)
        assert.are.same({ "lipc-set-prop com.lab126.powerd preventScreenSaver 1" }, executed)
        Actions._hold_awake(false)
        assert.is_false(PluginShare.keepalive)
        assert.are.same({ "lipc-set-prop com.lab126.powerd preventScreenSaver 1",
            "lipc-set-prop com.lab126.powerd preventScreenSaver 0" }, executed)
    end)

    it("leaves a Kindle alone when Keep alive is already on", function()
        kindle = true
        PluginShare.keepalive = true
        Actions._hold_awake(true)
        Actions._hold_awake(false)
        assert.are.same({}, executed)
        assert.is_true(PluginShare.keepalive)
    end)
end)
