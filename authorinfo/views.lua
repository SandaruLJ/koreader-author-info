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
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local T = ffiUtil.template
local _ = require("gettext")
local N_ = _.ngettext
local Screen = Device.screen

local AuthorIndex = require("authorinfo/author_index")
local AuthorImages = require("authorinfo/author_images")
local Actions = require("authorinfo/actions")
local ViewOptions = require("authorinfo/view_options")

local M = {}

-- Photo frame shape (width / height): a portrait, like a book cover.
local PHOTO_RATIO = 3 / 4
local NAME_FONT_SIZE = 16
local NAME_FONT_MIN = 10 -- CoverBrowser's floor for folder names
-- With the name position "on_photo" (the menu's name_position), a grid tile
-- shows the author's name in white on a solid black band across the photo's
-- bottom, instead of below the photo: solid like KOReader's own overlays
-- (a sleep screen message's fill), and as legible on e-ink over any photo.
-- The band's padding:
local OVERLAY_PADDING = 4

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

-- fit_label(text, width, fgcolor) -> a one-line TextWidget. As CoverBrowser
-- does for folder names: decrease the font size until the name fits, down to
-- NAME_FONT_MIN; below that it is truncated with "…".
local function fit_label(text, width, fgcolor)
    local font_size = NAME_FONT_SIZE
    local label
    while true do
        if label then label:free() end
        local at_min = font_size <= NAME_FONT_MIN
        label = TextWidget:new{
            text = text,
            face = Font:getFace("cfont", font_size),
            fgcolor = fgcolor,
            -- Measure the whole name; only truncate once at the minimum size.
            max_width = at_min and width or nil,
        }
        if at_min or label:getSize().w <= width then return label end
        font_size = font_size - 1
    end
end

-- NamedPhoto: a framed photo with the name painted over its bottom, on a
-- black band.
local NamedPhoto = WidgetContainer:extend{
    label = nil,  -- TextWidget, in white
    band_h = nil,
    border = nil,
}

function NamedPhoto:paintTo(bb, x, y)
    self[1]:paintTo(bb, x, y)
    local size = self[1]:getSize()
    self.dimen = Geom:new{ x = x, y = y, w = size.w, h = size.h }
    local band_w = size.w - 2 * self.border
    local band_y = y + size.h - self.border - self.band_h
    bb:paintRect(x + self.border, band_y, band_w, self.band_h, Blitbuffer.COLOR_BLACK)
    local label_size = self.label:getSize()
    self.label:paintTo(bb, x + math.floor((size.w - label_size.w) / 2),
        band_y + math.floor((self.band_h - label_size.h) / 2))
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
    local overlay = self.menu.name_position == "on_photo"
    -- Every tile reserves the same one-line name area, so photos and names
    -- line up across a row whatever the name's length. On an overlay, the
    -- photo takes the whole tile instead.
    local name_h = TextWidget:new{
        text = "Ag", face = Font:getFace("cfont", NAME_FONT_SIZE),
    }:getSize().h
    local gap = Screen:scaleBySize(4)
    local frame_h = overlay and (self.height - 2 * border)
        or (self.height - name_h - gap - 2 * border)
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
    if overlay then
        local padding = Screen:scaleBySize(OVERLAY_PADDING)
        self[1] = CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.height },
            NamedPhoto:new{
                photo,
                label = fit_label(self.entry.text, frame_w - 2 * padding, Blitbuffer.COLOR_WHITE),
                band_h = name_h + 2 * padding,
                border = border,
            },
        }
        return
    end
    local name = CenterContainer:new{
        dimen = Geom:new{ w = self.width, h = name_h },
        fit_label(self.entry.text, self.width),
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
        -- Author information, as Book information is for a book.
        title_bar_left_icon = "info",
        onLeftButtonTap = function() Actions.showDetails(author, count) end,
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

local CHECK = " \u{2713}" -- as Collections marks a checked filter

-- showPropValues(entries, prop, on_pick, empty_text): the values one can
-- filter by ({value, count} entries), in a list like Collections' "filter
-- by" list. Picking one calls on_pick(value).
local function show_prop_values(entries, prop, on_pick, empty_text)
    local list
    local items = {}
    for _i, entry in ipairs(entries) do
        items[#items + 1] = {
            text = entry.value,
            mandatory = tostring(entry.count),
            callback = function()
                UIManager:close(list)
                on_pick(entry.value)
            end,
        }
    end
    if #items == 0 then
        UIManager:show(InfoMessage:new{ text = empty_text, timeout = 4 })
        return
    end
    list = Menu:new{
        title = T("%1 (%2)", ViewOptions.propText(prop), #items),
        item_table = items,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
    }
    UIManager:show(list)
end

function M.showAuthors(ui)
    local books = AuthorIndex.getBooks()
    if books == nil then
        UIManager:show(InfoMessage:new{
            text = _("Authors needs KOReader's Cover browser plugin, which reads your books' metadata."),
        })
        return
    end
    if #AuthorIndex.getAuthors(books) == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No authors found yet.\n\nKOReader learns your books' authors when it shows their covers in the file browser."),
        })
        return
    end

    local cb = coverbrowser()
    local mode = display_mode(cb)
    local options = ViewOptions.load()
    local menu, authors

    local function build_items()
        authors = ViewOptions.filterAuthors(books, options.filter)
        ViewOptions.sort(authors, options)
        return author_items(authors)
    end
    local function subtitle()
        local count = T(N_("1 author", "%1 authors", #authors), #authors)
        local filtered = ViewOptions.describe(options.filter)
        return filtered and (count .. " · " .. filtered) or count
    end
    -- Saves the options and redraws the list from the top.
    local function apply()
        ViewOptions.save(options)
        local items = build_items()
        menu:switchItemTable(nil, items, 1, nil, subtitle())
    end
    local function refresh()
        if menu then menu:updateItems(1, true) end
    end

    local function show_sort_dialog()
        local dialog
        local rows = {}
        local ids = {}
        for id in pairs(ViewOptions.SORTS) do ids[#ids + 1] = id end
        table.sort(ids, function(x, y) return ViewOptions.SORTS[x].order < ViewOptions.SORTS[y].order end)
        for _i, id in ipairs(ids) do
            rows[#rows + 1] = {{
                text = ViewOptions.SORTS[id].text .. (options.sort == id and CHECK or ""),
                callback = function()
                    UIManager:close(dialog)
                    options.sort = id
                    apply()
                end,
            }}
        end
        rows[#rows + 1] = {}
        rows[#rows + 1] = {{
            text = _("Reverse order") .. (options.reverse and CHECK or ""),
            callback = function()
                UIManager:close(dialog)
                options.reverse = not options.reverse
                apply()
            end,
        }}
        dialog = ButtonDialog:new{ title = _("Sort authors by"), buttons = rows }
        UIManager:show(dialog)
    end

    local function show_filter_dialog()
        local filter = options.filter
        local dialog
        local function status_button(status)
            local checked = filter.status and filter.status[status]
            return {
                text = ViewOptions.statusText(status) .. (checked and CHECK or ""),
                callback = function()
                    UIManager:close(dialog)
                    ViewOptions.toggleStatus(filter, status)
                    apply()
                end,
            }
        end
        local function prop_button(prop)
            return {
                text = ViewOptions.propText(prop) .. (filter[prop] and CHECK or ""),
                callback = function()
                    UIManager:close(dialog)
                    if filter[prop] then
                        filter[prop] = nil
                        apply()
                        return
                    end
                    local function pick(value)
                        filter[prop] = value
                        apply()
                    end
                    -- Offer the values among what the other filters keep.
                    if prop == "country" then
                        show_prop_values(
                            ViewOptions.authorValueCounts(ViewOptions.filterAuthors(books, filter), prop),
                            prop, pick,
                            T(_("None of these authors has a %1 yet. Look up author information from the menu first."),
                                ViewOptions.propText(prop):lower()))
                    else
                        show_prop_values(
                            ViewOptions.valueCounts(ViewOptions.keptBooks(books, filter), prop),
                            prop, pick,
                            T(_("None of these books has any %1."), ViewOptions.propText(prop):lower()))
                    end
                end,
            }
        end
        dialog = ButtonDialog:new{
            title = _("Filter authors"),
            buttons = {
                { status_button("new"), status_button("reading") },
                { status_button("unread"), status_button("read") },
                {},
                { prop_button("language"), prop_button("country") },
                { prop_button("keywords") },
                {},
                {{
                    text = _("Reset all filters"),
                    enabled = next(filter) ~= nil,
                    callback = function()
                        UIManager:close(dialog)
                        options.filter = {}
                        apply()
                    end,
                }},
            },
        }
        UIManager:show(dialog)
    end

    local function show_name_position_dialog()
        local dialog
        local rows = {}
        local ids = {}
        for id in pairs(ViewOptions.NAME_POSITIONS) do ids[#ids + 1] = id end
        table.sort(ids, function(x, y)
            return ViewOptions.NAME_POSITIONS[x].order < ViewOptions.NAME_POSITIONS[y].order
        end)
        for _i, id in ipairs(ids) do
            rows[#rows + 1] = {{
                text = ViewOptions.NAME_POSITIONS[id].text .. (options.name_position == id and CHECK or ""),
                callback = function()
                    UIManager:close(dialog)
                    options.name_position = id
                    menu.name_position = id
                    ViewOptions.save(options)
                    menu:updateItems(1, true)
                end,
            }}
        end
        dialog = ButtonDialog:new{ title = _("Name position"), buttons = rows }
        UIManager:show(dialog)
    end

    local function show_options_dialog()
        local dialog
        local function names()
            local list = {}
            for _i, author in ipairs(authors) do list[#list + 1] = author.name end
            return list
        end
        local buttons = {
            {{
                text = T(_("Sort by: %1"), ViewOptions.SORTS[options.sort].text:lower())
                    .. (options.reverse and " " .. _("(reversed)") or "") .. "  \u{25B8}",
                callback = function()
                    UIManager:close(dialog)
                    show_sort_dialog()
                end,
            }},
            {{
                text = (next(options.filter) and _("Filter (on)") or _("Filter")) .. "  \u{25B8}",
                callback = function()
                    UIManager:close(dialog)
                    show_filter_dialog()
                end,
            }},
        }
        if menu._authors_grid then
            buttons[#buttons + 1] = {{
                text = T(_("Name position: %1"),
                    ViewOptions.NAME_POSITIONS[options.name_position].text:lower()) .. "  \u{25B8}",
                callback = function()
                    UIManager:close(dialog)
                    show_name_position_dialog()
                end,
            }}
        end
        buttons[#buttons + 1] = {}
        buttons[#buttons + 1] = {{
            text = _("Find missing images and information"),
            callback = function()
                UIManager:close(dialog)
                Actions.findAll(names(), refresh)
            end,
        }}
        dialog = ButtonDialog:new{ buttons = buttons }
        UIManager:show(dialog)
    end

    local items = build_items()
    local fields = {
        name = "authors",
        title = _("Authors"),
        subtitle = subtitle(),
        item_table = items,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = show_options_dialog,
        onMenuSelect = function(_self, item)
            M.showBooks(ui, item.text, item.files, function() menu.close_callback() end)
        end,
        onMenuHold = function(_self, item)
            local dialog
            local rows = Actions.holdButtons(item.text, function() UIManager:close(dialog) end, refresh,
                #item.files)
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
        fields._authors_grid = true
        fields.name_position = options.name_position
    end
    menu = Menu:new(fields)
    menu.close_callback = function() UIManager:close(menu) end
    UIManager:show(menu)
    return menu
end

return M
