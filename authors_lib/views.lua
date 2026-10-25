-- The two screens, both built from KOReader's own widgets:
--
--   showAuthors(ui)  -- every author in the library. When the file browser
--                       shows covers (CoverBrowser's mosaic modes), it is the
--                       same grid, with each author's photo and name; in list
--                       or classic modes it is KOReader's standard list.
--   showBooks(...)   -- one author's books: a KOReader BookList (the widget
--                       Collections uses) in whatever display mode the file
--                       browser uses, with a back button to the authors.
--
-- The grid reuses CoverBrowser's layout and paging (CoverMenu.updateItems and
-- MosaicMenu._recalculateDimen); only the tile itself (AuthorTile) is ours.

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Menu = require("ui/widget/menu")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local T = ffiUtil.template
local _ = require("gettext")
local N_ = _.ngettext
local Screen = Device.screen

local AuthorIndex = require("authors_lib/author_index")
local AuthorImages = require("authors_lib/author_images")
local Actions = require("authors_lib/actions")

local M = {}

-- Photo frame shape (width / height): a portrait, like a book cover.
local PHOTO_RATIO = 3 / 4
local NAME_FONT_SIZE = 16
local NAME_FONT_MIN = 10 -- CoverBrowser's floor for folder names

-- CoverBrowser's modules, when that plugin is enabled.
local function coverbrowser()
    local ok, BookInfoManager = pcall(require, "bookinfomanager")
    if not ok or not BookInfoManager then return nil end
    return {
        BookInfoManager = BookInfoManager,
        CoverMenu = require("covermenu"),
        MosaicMenu = require("mosaicmenu"),
        ListMenu = require("listmenu"),
    }
end

-- displayMode() -> the file browser's display mode ("mosaic_image",
-- "list_image_meta", ...), or nil for classic.
local function display_mode(cb)
    return cb and cb.BookInfoManager:getSetting("filemanager_display_mode") or nil
end

-- grid_fields(cb, mode, extra) -> fields that turn a Menu into CoverBrowser's
-- grid or list, as CoverBrowser itself does for History and Collections.
local function grid_fields(cb, mode, fields)
    local settings = cb.BookInfoManager
    fields.nb_cols_portrait = settings:getSetting("nb_cols_portrait") or 3
    fields.nb_rows_portrait = settings:getSetting("nb_rows_portrait") or 3
    fields.nb_cols_landscape = settings:getSetting("nb_cols_landscape") or 4
    fields.nb_rows_landscape = settings:getSetting("nb_rows_landscape") or 2
    fields.files_per_page = settings:getSetting("files_per_page")
    fields.display_mode_type = mode:gsub("_.*", "")
    fields.updateItems = cb.CoverMenu.updateItems
    fields.onCloseWidget = cb.CoverMenu.onCloseWidget
    return fields
end

-- ---------------------------------------------------------------------
-- Author tile
-- ---------------------------------------------------------------------

local function initials(name)
    local words = {}
    for word in AuthorImages.queryName(name):gmatch("%S+") do words[#words + 1] = word end
    local first = words[1] and util.splitToChars(words[1])[1] or "?"
    local last = #words > 1 and util.splitToChars(words[#words])[1] or ""
    return first .. last
end

-- photo_widget(path, w, h) -> the photo cropped to fill w x h, or nil.
local function photo_widget(path, w, h)
    local ok, bb = pcall(function()
        return require("ui/renderimage"):renderImageFile(path, false)
    end)
    if not ok or not bb then return nil end
    local scale = math.max(w / bb:getWidth(), h / bb:getHeight())
    return ImageWidget:new{
        image = bb,
        image_disposable = true,
        width = w,
        height = h,
        scale_factor = scale,
    }
end

local AuthorTile = InputContainer:extend{
    entry = nil,
    menu = nil,
    width = nil,
    height = nil,
}

function AuthorTile:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = self.dimen } },
        HoldSelect = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }

    local border = Size.border.thin
    -- Every tile reserves the same one-line name area, so photos and names
    -- line up across a row whatever the name's length.
    local name_h = TextWidget:new{
        text = "Ag", face = Font:getFace("cfont", NAME_FONT_SIZE),
    }:getSize().h
    local gap = Screen:scaleBySize(4)
    local frame_h = self.height - name_h - gap - 2 * border
    local frame_w = math.min(self.width - 2 * border, math.floor(frame_h * PHOTO_RATIO))

    local path = AuthorImages.path(self.entry.text)
    local inner = path and photo_widget(path, frame_w, frame_h)
    if not inner then
        inner = CenterContainer:new{
            dimen = Geom:new{ w = frame_w, h = frame_h },
            TextWidget:new{
                text = initials(self.entry.text),
                face = Font:getFace("cfont", math.max(14, math.floor(NAME_FONT_SIZE * 2))),
                bold = true,
            },
        }
    end
    local photo = FrameContainer:new{
        padding = 0,
        margin = 0,
        bordersize = border,
        background = Blitbuffer.COLOR_WHITE,
        inner,
    }
    -- As CoverBrowser does for folder names: decrease the font size until the
    -- name fits, down to NAME_FONT_MIN; below that it is truncated with "…".
    local font_size = NAME_FONT_SIZE
    local label
    while true do
        if label then label:free() end
        local at_min = font_size <= NAME_FONT_MIN
        label = TextWidget:new{
            text = self.entry.text,
            face = Font:getFace("cfont", font_size),
            -- Measure the whole name; only truncate once at the minimum size.
            max_width = at_min and self.width or nil,
        }
        if at_min or label:getSize().w <= self.width then break end
        font_size = font_size - 1
    end
    local name = CenterContainer:new{
        dimen = Geom:new{ w = self.width, h = name_h },
        label,
    }
    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = self.width, h = self.height },
        VerticalGroup:new{
            align = "center",
            photo,
            VerticalSpan:new{ width = gap },
            name,
        },
    }
end

function AuthorTile:onTapSelect()
    self.menu:onMenuSelect(self.entry)
    return true
end

function AuthorTile:onHoldSelect()
    self.menu:onMenuHold(self.entry)
    return true
end

-- buildAuthorGrid: MosaicMenu._updateItemsBuildUI with AuthorTile items.
local function build_author_grid(self)
    local cur_row
    local idx_offset = (self.page - 1) * self.perpage
    local line_layout = {}
    for idx = 1, self.perpage do
        local entry = self.item_table[idx_offset + idx]
        if entry == nil then break end
        entry.idx = idx_offset + idx
        if idx % self.nb_cols == 1 or self.nb_cols == 1 then
            if idx > 1 then table.insert(self.layout, line_layout) end
            line_layout = {}
            table.insert(self.item_group, VerticalSpan:new{ width = self.item_margin })
            cur_row = HorizontalGroup:new{}
            table.insert(self.item_group, LeftContainer:new{
                dimen = Geom:new{ w = self.inner_dimen.w, h = self.item_height },
                cur_row,
            })
            table.insert(cur_row, HorizontalSpan:new{ width = self.item_margin })
        end
        local tile = AuthorTile:new{
            entry = entry,
            menu = self,
            width = self.item_width,
            height = self.item_height,
            show_parent = self.show_parent,
        }
        table.insert(cur_row, tile)
        table.insert(cur_row, HorizontalSpan:new{ width = self.item_margin })
        table.insert(line_layout, tile)
    end
    table.insert(self.layout, line_layout)
    table.insert(self.item_group, VerticalSpan:new{ width = self.item_margin })
end

-- ---------------------------------------------------------------------
-- Books of one author
-- ---------------------------------------------------------------------

local function book_items(files, cb)
    local items = {}
    for _i, path in ipairs(files) do
        local attr = lfs.attributes(path) or {}
        local info = cb and cb.BookInfoManager:getBookInfo(path, false)
        items[#items + 1] = {
            file = path,
            text = path:match("([^/]+)$"),
            attr = attr,
            mandatory = util.getFriendlySize(attr.size or 0),
            sort_key = info and info.title or path:match("([^/]+)$"),
        }
    end
    table.sort(items, function(a, b) return ffiUtil.strcoll(a.sort_key, b.sort_key) end)
    return items
end

function M.showBooks(ui, author, files, on_open)
    local BookList = require("ui/widget/booklist")
    local filemanagerutil = require("apps/filemanager/filemanagerutil")
    local cb = coverbrowser()
    local mode = display_mode(cb)
    local count = #files
    local books
    local fields = {
        name = "authors_books",
        title = author,
        subtitle = T(N_("1 book", "%1 books", count), count),
        item_table = book_items(files, cb),
        ui = ui,
        onReturn = function() books.close_callback() end,
        onMenuSelect = function(_self, item)
            filemanagerutil.openFile(ui, item.file, function()
                books.close_callback()
                if on_open then on_open() end
            end)
        end,
        onMenuHold = function(_self, item)
            if ui.bookinfo then ui.bookinfo:show(item.file) end
            return true
        end,
    }
    if mode then
        grid_fields(cb, mode, fields)
        if fields.display_mode_type == "mosaic" then
            fields._recalculateDimen = cb.MosaicMenu._recalculateDimen
            fields._updateItemsBuildUI = cb.MosaicMenu._updateItemsBuildUI
            fields._do_cover_images = mode ~= "mosaic_text"
            fields._do_center_partial_rows = false
        else
            fields._recalculateDimen = cb.ListMenu._recalculateDimen
            fields._updateItemsBuildUI = cb.ListMenu._updateItemsBuildUI
            fields._do_cover_images = mode ~= "list_only_meta"
            fields._do_filename_only = mode == "list_image_filename"
        end
        fields._do_hint_opened = true
    end
    books = BookList:new(fields)
    table.insert(books.paths, true) -- shows the back button, as Collections does
    books.close_callback = function() UIManager:close(books) end
    UIManager:show(books)
    return books
end

-- ---------------------------------------------------------------------
-- Authors
-- ---------------------------------------------------------------------

local function author_items(authors)
    local items = {}
    for _i, author in ipairs(authors) do
        local count = #author.files
        items[#items + 1] = {
            text = author.name,
            files = author.files,
            mandatory = tostring(count),
        }
    end
    return items
end

function M.showAuthors(ui)
    local authors = AuthorIndex.getAuthors()
    if authors == nil then
        UIManager:show(InfoMessage:new{
            text = _("Authors needs KOReader's Cover browser plugin, which reads your books' metadata."),
        })
        return
    end
    if #authors == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No authors found yet.\n\nKOReader learns your books' authors when it shows their covers in the file browser."),
        })
        return
    end

    local cb = coverbrowser()
    local mode = display_mode(cb)
    local menu
    local function refresh()
        if menu then menu:updateItems(1, true) end
    end
    local function names()
        local list = {}
        for _i, author in ipairs(authors) do list[#list + 1] = author.name end
        return list
    end
    local fields = {
        name = "authors",
        title = _("Authors"),
        subtitle = T(N_("1 author", "%1 authors", #authors), #authors),
        item_table = author_items(authors),
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function()
            local dialog
            dialog = ButtonDialog:new{
                buttons = {{{
                    text = _("Find missing author images"),
                    callback = function()
                        UIManager:close(dialog)
                        Actions.findAll(names(), refresh)
                    end,
                }}},
            }
            UIManager:show(dialog)
        end,
        onMenuSelect = function(_self, item)
            M.showBooks(ui, item.text, item.files, function() menu.close_callback() end)
        end,
        onMenuHold = function(_self, item)
            local dialog
            local rows = Actions.holdButtons(item.text, function() UIManager:close(dialog) end, refresh)
            if #rows == 0 then return true end
            dialog = ButtonDialog:new{ title = item.text, buttons = rows }
            UIManager:show(dialog)
            return true
        end,
    }
    if mode and mode:match("^mosaic") then
        grid_fields(cb, mode, fields)
        fields.onCloseWidget = nil -- no covers or background jobs to clean up
        fields._recalculateDimen = cb.MosaicMenu._recalculateDimen
        fields._updateItemsBuildUI = build_author_grid
    end
    menu = Menu:new(fields)
    menu.close_callback = function() UIManager:close(menu) end
    UIManager:show(menu)
    return menu
end

return M
