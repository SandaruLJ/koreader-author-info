-- Authors: browse your library by author, with each author's photo.
--
-- Main menu > Authors (next to History and Collections), or the "Authors"
-- gesture action, opens a grid of authors in the file browser's display
-- style. Tap an author for their books; hold for photo options.

local Dispatcher = require("dispatcher")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local Authors = WidgetContainer:extend{
    name = "authors",
    is_doc_only = false,
}

function Authors:onDispatcherRegisterActions()
    Dispatcher:registerAction("show_authors", {
        category = "none",
        event = "ShowAuthors",
        title = _("Authors"),
        general = true,
    })
end

function Authors:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Authors:addToMainMenu(menu_items)
    menu_items.authors = {
        text = _("Authors"),
        sorting_hint = "main",
        callback = function() self:onShowAuthors() end,
    }
end

function Authors:onShowAuthors()
    require("authors_lib/views").showAuthors(self.ui)
    return true
end

return Authors
