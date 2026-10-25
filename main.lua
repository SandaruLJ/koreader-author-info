-- Author Info: browse your library by author, with each author's photo and
-- a short bio.
--
-- Main menu > Authors (right after History), or the "Authors"
-- gesture action, opens a grid of authors in the file browser's display
-- style. Tap an author for their books; hold for their information and photo
-- options.

local Dispatcher = require("dispatcher")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

-- Lists "author_info" right after "history" in the main menu tab of the file
-- browser and the reader, as KOReader lists its own entries. (A plugin's entry
-- not in these lists goes at the end of the tab its sorting_hint names.)
local function place_after_history(order_module)
    local ok, order = pcall(require, order_module)
    local main = ok and type(order) == "table" and order.main
    if type(main) ~= "table" then return end
    for _i, id in ipairs(main) do
        if id == "author_info" then return end
    end
    for i, id in ipairs(main) do
        if id == "history" then
            table.insert(main, i + 1, "author_info")
            return
        end
    end
end
place_after_history("ui/elements/filemanager_menu_order")
place_after_history("ui/elements/reader_menu_order")

local AuthorInfo = WidgetContainer:extend{
    name = "author-info",
    is_doc_only = false,
}

function AuthorInfo:onDispatcherRegisterActions()
    Dispatcher:registerAction("author_info_show_authors", {
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
    menu_items.author_info = {
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
