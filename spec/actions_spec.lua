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
        }
        package.loaded["authorinfo/author_info"] = {
            has = function(name) return has_info[name] == true end,
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
