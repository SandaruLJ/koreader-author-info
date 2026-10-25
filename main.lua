-- Author Info: browse your library by author, with each author's photo and
-- a short bio.
--
-- Main menu > Authors (next to History and Collections), or the "Authors"
-- gesture action, opens a grid of authors in the file browser's display
-- style. Tap an author for their books; hold for their information and photo
-- options.

local Dispatcher = require("dispatcher")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

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
