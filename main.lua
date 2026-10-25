-- Author Info: browse your library by author, with each author's photo and
-- a short bio.
--
-- Main menu > Authors (above Favorites), or the "Authors"
-- gesture action, opens a grid of authors in the file browser's display
-- style. Tap an author for their books; hold for their information and photo
-- options.

local Dispatcher = require("dispatcher")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

-- Lists "authorinfo" right before "favorites" in the main menu tab of the
-- file browser and the reader, as KOReader lists its own entries. (A plugin's
-- entry not in these lists goes at the end of the tab its sorting_hint names.)
local function place_before_favorites(order_module)
    local ok, order = pcall(require, order_module)
    local main = ok and type(order) == "table" and order.main
    if type(main) ~= "table" then return end
    for _i, id in ipairs(main) do
        if id == "authorinfo" then return end
    end
    for i, id in ipairs(main) do
        if id == "favorites" then
            table.insert(main, i, "authorinfo")
            return
        end
    end
end
place_before_favorites("ui/elements/filemanager_menu_order")
place_before_favorites("ui/elements/reader_menu_order")

local AuthorInfo = WidgetContainer:extend{
    name = "authorinfo",
    is_doc_only = false,
}

function AuthorInfo:onDispatcherRegisterActions()
    Dispatcher:registerAction("authorinfo_show_authors", {
        category = "none",
        event = "AuthorInfoShowAuthors",
        title = _("Authors"),
        general = true,
    })
end

function AuthorInfo:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function AuthorInfo:addToMainMenu(menu_items)
    menu_items.authorinfo = {
        text = _("Authors"),
        sorting_hint = "main",
        callback = function() self:onAuthorInfoShowAuthors() end,
    }
end

function AuthorInfo:onAuthorInfoShowAuthors()
    require("authorinfo/views").showAuthors(self.ui)
    return true
end

return AuthorInfo
