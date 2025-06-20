local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local DocSettings = require("docsettings")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local Math = require("optmath")
local OverlapGroup = require("ui/widget/overlapgroup")
local ProgressWidget = require("ui/widget/progresswidget")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TopContainer = require("ui/widget/container/topcontainer")
local UnderlineContainer = require("ui/widget/container/underlinecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local Screen = Device.screen
local T = require("ffi/util").template
local getMenuText = require("ui/widget/menu").getMenuText

local BookInfoManager = require("bookinfomanager")

-- Here is the specific UI implementation for "list" display modes
-- (see covermenu.lua for the generic code)

-- declare 3 fonts included with our plugin
local title_serif = "source/SourceSerif4-BoldIt.ttf"
local good_serif = "source/SourceSerif4-Regular.ttf"
local good_sans = "source/SourceSans3-Regular"

local is_pathchooser = false
local scale_by_size = Screen:scaleBySize(1000000) * (1 / 1000000)

-- ItemShortCutIcon (for keyboard navigation) is private to menu.lua and can't be accessed,
-- so we need to redefine it
local ItemShortCutIcon = WidgetContainer:extend {
    dimen = Geom:new { x = 0, y = 0, w = Screen:scaleBySize(22), h = Screen:scaleBySize(22) },
    key = nil,
    bordersize = Size.border.default,
    radius = 0,
    style = "square",
}

local function getSourceDir()
    local callerSource = debug.getinfo(2, "S").source
    if callerSource:find("^@") then
        return callerSource:gsub("^@(.*)/[^/]*", "%1")
    end
end

function ItemShortCutIcon:init()
    if not self.key then
        return
    end
    local radius = 0
    local background = Blitbuffer.COLOR_WHITE
    if self.style == "rounded_corner" then
        radius = math.floor(self.width / 2)
    elseif self.style == "grey_square" then
        background = Blitbuffer.COLOR_LIGHT_GRAY
    end
    local sc_face
    if self.key:len() > 1 then
        sc_face = Font:getFace("ffont", 14)
    else
        sc_face = Font:getFace("scfont", 22)
    end
    self[1] = FrameContainer:new {
        padding = 0,
        bordersize = self.bordersize,
        radius = radius,
        background = background,
        dimen = self.dimen:copy(),
        CenterContainer:new {
            dimen = self.dimen,
            TextWidget:new {
                text = self.key,
                face = sc_face,
            },
        },
    }
end

local function findLast(haystack, needle)
    local i = haystack:match(".*" .. needle .. "()")
    if i == nil then return nil else return i - 1 end
end

-- Based on menu.lua's MenuItem
local ListMenuItem = InputContainer:extend {
    entry = nil, -- hash, mandatory
    text = nil,
    show_parent = nil,
    dimen = nil,
    shortcut = nil,
    shortcut_style = "square",
    _underline_container = nil,
    do_cover_image = false,
    do_filename_only = false,
    do_hint_opened = false,
    been_opened = false,
    init_done = false,
    bookinfo_found = false,
    cover_specs = nil,
    has_description = false,
}

function ListMenuItem:init()
    -- filepath may be provided as 'file' (history, collection) or 'path' (filechooser)
    -- store it as attribute so we can use it elsewhere
    self.filepath = self.entry.file or self.entry.path

    -- As done in MenuItem
    -- Squared letter for keyboard navigation
    if self.shortcut then
        local icon_width = math.floor(self.dimen.h * 2 / 5)
        local shortcut_icon_dimen = Geom:new {
            x = 0,
            y = 0,
            w = icon_width,
            h = icon_width,
        }
        -- To keep a simpler widget structure, this shortcut icon will not
        -- be part of it, but will be painted over the widget in our paintTo
        self.shortcut_icon = ItemShortCutIcon:new {
            dimen = shortcut_icon_dimen,
            key = self.shortcut,
            style = self.shortcut_style,
        }
    end

    -- we need this table per-instance, so we declare it here
    self.ges_events = {
        TapSelect = {
            GestureRange:new {
                ges = "tap",
                range = self.dimen,
            },
        },
        HoldSelect = {
            GestureRange:new {
                ges = "hold",
                range = self.dimen,
            },
        },
    }

    -- We now build the minimal widget container that won't change after udpate()

    -- As done in MenuItem
    -- for compatibility with keyboard navigation
    -- (which does not seem to work well when multiple pages,
    -- even with classic menu)
    self.underline_h = 0 -- smaller than default (3) to not shift our vertical aligment
    self._underline_container = UnderlineContainer:new {
        vertical_align = "top",
        padding = 0,
        dimen = Geom:new {
            w = self.width,
            h = self.height
        },
        linesize = self.underline_h,
        -- widget : will be filled in self:update()
    }
    self[1] = self._underline_container

    -- Remaining part of initialization is done in update(), because we may
    -- have to do it more than once if item not found in db
    self:update()
    self.init_done = true
end

function ListMenuItem:update()
    -- We will be a disctinctive widget whether we are a directory,
    -- a known file with image / without image, or a not yet known file
    local widget

    -- we'll add a VerticalSpan of same size as underline container for balance
    local dimen = Geom:new {
        w = self.width,
        h = self.height - 2 * self.underline_h
    }

    local function _fontSize(nominal, max)
        -- Nominal font sizes are based on a theoretical 64px ListMenuItem height.
        -- Keep ratio of font size to item height based on that theoretical ideal,
        -- scaling it to match the actual item height.
        local font_size = math.floor(nominal * dimen.h * (1 / 64) / scale_by_size)
        -- But limit it to the provided max, to avoid huge font size when
        -- only a few items per page
        if max and font_size >= max then
            return max
        end
        return font_size
    end
    -- Will speed up a bit if we don't do all font sizes when
    -- looking for one that make text fit
    local fontsize_dec_step = math.ceil(_fontSize(100) * (1 / 100))
    -- calculate font used in all right widget text
    local wright_font_face = Font:getFace(good_sans, _fontSize(12, 18))
    -- and font sizes used for title and author/series
    local title_font_size = _fontSize(20, 26)   -- 22
    local authors_font_size = _fontSize(14, 18) -- 16

    -- We'll draw a border around cover images, it may not be
    -- needed with some covers, but it's nicer when cover is
    -- a pure white background (like rendered text page)
    local border_size = Screen:scaleBySize(4)
    local max_img_w = dimen.h - 2 * border_size -- width = height, squared
    local max_img_h = dimen.h - 2 * border_size
    local cover_specs = {
        max_cover_w = max_img_w,
        max_cover_h = max_img_h,
    }
    -- Make it available to our menu, for batch extraction
    -- to know what size is needed for current view
    if self.do_cover_image then
        self.menu.cover_specs = cover_specs
    else
        self.menu.cover_specs = false
    end

    -- test to see what style to draw (pathchooser vs "detailed list view mode")
    is_pathchooser = false
    if (self.title_bar and util.stringEndsWith(self.title_bar.title, "name to choose it")) or
        (self.menu and util.stringEndsWith(self.menu.title, "name to choose it")) then
        is_pathchooser = true
    end

    self.is_directory = not (self.entry.is_file or self.entry.file)
    if self.is_directory then
        -- nb items on the right, directory name on the left
        local wright
        local wright_width = 0
        local wright_items = { align = "right" }

        if is_pathchooser == false then
            -- replace the stock tiny file and folder glyphs with text
            local folder_count = string.match(self.mandatory, "(%d+) \u{F114}")
            local file_count = string.match(self.mandatory, "(%d+) \u{F016}")
            local folder_text = "Folder"
            local file_text = "Book"
            wright_font_face = Font:getFace(good_sans, _fontSize(15, 19))

            -- add file or folder counts as necessary with pluralization (english)
            if folder_count and tonumber(folder_count) > 0 then
                if tonumber(folder_count) > 1 then folder_text = folder_text .. "s" end
                local wfoldercount = TextWidget:new {
                    text = folder_count .. " " .. folder_text,
                    face = wright_font_face,
                }
                table.insert(wright_items, wfoldercount)
            end
            if file_count and tonumber(file_count) > 0 then
                if tonumber(file_count) > 1 then file_text = file_text .. "s" end
                local wfilecount = TextWidget:new {
                    text = file_count .. " " .. file_text,
                    face = wright_font_face,
                }
                table.insert(wright_items, wfilecount)
            end
        else
            local wmandatory = TextWidget:new {
                -- self.mandatory CAN be nil, usually in pathchooser
                text = self.mandatory or "",
                face = wright_font_face,
            }
            table.insert(wright_items, wmandatory)
        end

        if #wright_items > 0 then
            for i, w in ipairs(wright_items) do
                wright_width = math.max(wright_width, w:getSize().w)
            end
            wright = CenterContainer:new {
                dimen = Geom:new { w = wright_width, h = dimen.h },
                VerticalGroup:new(wright_items),
            }
        end

        local pad_width = Screen:scaleBySize(10) -- on the left, in between, and on the right
        local folder_cover
        -- add cover-art sized icon for folders
        if self.do_cover_image and is_pathchooser == false then
            local subfolder_cover_image

            -- check for folder image
            local function findCover(dir_path)
                local COVER_CANDIDATES = { "cover", "folder", ".cover", ".folder" }
                local COVER_EXTENSIONS = { ".jpg", ".jpeg", ".png", ".webp", ".gif" }
                if not dir_path or dir_path == "" or dir_path == ".." or dir_path:match("%.%.$") then
                    return nil
                end
                dir_path = dir_path:gsub("[/\\]+$", "")
                -- Try exact matches with lowercase and uppercase extensions
                for _, candidate in ipairs(COVER_CANDIDATES) do
                    for _, ext in ipairs(COVER_EXTENSIONS) do
                        local exact_path = dir_path .. "/" .. candidate .. ext
                        local f = io.open(exact_path, "rb")
                        if f then
                            f:close()
                            return exact_path
                        end
                        local upper_path = dir_path .. "/" .. candidate .. ext:upper()
                        if upper_path ~= exact_path then
                            f = io.open(upper_path, "rb")
                            if f then
                                f:close()
                                return upper_path
                            end
                        end
                    end
                end
                -- Fallback: scan directory for case-insensitive matches
                local success, handle = pcall(io.popen, 'ls -1 "' .. dir_path .. '" 2>/dev/null')
                if success and handle then
                    for file in handle:lines() do
                        if file and file ~= "." and file ~= ".." and file ~= "" then
                            local file_lower = file:lower()
                            for _, candidate in ipairs(COVER_CANDIDATES) do
                                for _, ext in ipairs(COVER_EXTENSIONS) do
                                    if file_lower == candidate .. ext then
                                        handle:close()
                                        return dir_path .. "/" .. file
                                    end
                                end
                            end
                        end
                    end
                    handle:close()
                end
                return nil
            end
            local folder_image_file = findCover(self.filepath)
            if folder_image_file ~= nil then
                local success, folder_image = pcall(function()
                    local temp_image = ImageWidget:new { file = folder_image_file, scale_factor = 1 }
                    temp_image:_render()
                    local orig_w = temp_image:getOriginalWidth()
                    local orig_h = temp_image:getOriginalHeight()
                    temp_image:free()
                    local _, _, scale_factor = BookInfoManager.getCachedCoverSize(orig_w, orig_h, max_img_w, max_img_h)
                    return ImageWidget:new {
                        file = folder_image_file,
                        width = max_img_w,
                        height = max_img_h,
                        scale_factor = scale_factor,
                        center_x_ratio = 0.5,
                        center_y_ratio = 0.5,
                    }
                end)
                if success then
                    subfolder_cover_image = FrameContainer:new {
                        width = max_img_w,
                        height = max_img_h,
                        margin = 0,
                        padding = 0,
                        bordersize = 0,
                        folder_image
                    }
                end
            end

            -- check for books with covers in the subfolder
            if subfolder_cover_image == nil and not BookInfoManager:getSetting("disable_auto_foldercovers") then
                local SQ3 = require("lua-ljsqlite3/init")
                local DataStorage = require("datastorage")
                self.db_location = DataStorage:getSettingsDir() .. "/PT_bookinfo_cache.sqlite3"
                self.db_conn = SQ3.open(self.db_location)
                self.db_conn:set_busy_timeout(5000)
                local res = self.db_conn:exec("SELECT directory, filename FROM bookinfo WHERE directory IS '" ..
                self.filepath .. "/' AND has_cover = 'Y' ORDER BY RANDOM() LIMIT 16;")
                local subfolder_images = {}
                if res then
                    local directories = res[1]
                    local filenames = res[2]
                    -- db query returned up to 16 rows, find 4 that are books that still exist on filesystem or give up
                    for i, filename in ipairs(filenames) do
                        local dirpath = directories[i]
                        local f = filename
                        local fullpath = dirpath .. f
                        local subfolder_book = BookInfoManager:getBookInfo(fullpath, self.do_cover_image)
                        if subfolder_book and lfs.attributes(fullpath, "mode") == "file" then
                            local _, _, scale_factor = BookInfoManager.getCachedCoverSize(subfolder_book.cover_w,
                                subfolder_book.cover_h,
                                max_img_w / 2.05, max_img_h / 2.05)
                            table.insert(subfolder_images, ImageWidget:new {
                                image = subfolder_book.cover_bb,
                                scale_factor = scale_factor,
                            })
                        end
                        if #subfolder_images == 4 then
                            break
                        end
                    end
                end
                self.db_conn:close()
                if #subfolder_images == 4 then
                    subfolder_cover_image = VerticalGroup:new {}
                    local subfolder_image_row1 = HorizontalGroup:new {}
                    local subfolder_image_row2 = HorizontalGroup:new {}
                    for i, subfolder_image in ipairs(subfolder_images) do
                        if i < 3 then
                            table.insert(subfolder_image_row1, subfolder_image)
                        else
                            table.insert(subfolder_image_row2, subfolder_image)
                        end
                        if i == 1 then
                            table.insert(subfolder_image_row1, HorizontalSpan:new { width = Size.padding.small, })
                        end
                        if i == 3 then
                            table.insert(subfolder_image_row2, HorizontalSpan:new { width = Size.padding.small, })
                        end
                    end
                    table.insert(subfolder_cover_image, subfolder_image_row1)
                    table.insert(subfolder_cover_image, VerticalSpan:new { width = Size.padding.small, })
                    table.insert(subfolder_cover_image, subfolder_image_row2)
                    subfolder_cover_image = CenterContainer:new {
                        dimen = Geom:new { w = max_img_w, h = max_img_h },
                        subfolder_cover_image,
                    }
                end
            end

            -- use stock folder icon
            if subfolder_cover_image == nil then
                local _, _, scale_factor = BookInfoManager.getCachedCoverSize(250, 500, max_img_w, max_img_h)
                subfolder_cover_image = ImageWidget:new {
                    file = getSourceDir() .. "/resources/folder.svg",
                    alpha = true,
                    scale_factor = scale_factor,
                    width = max_img_w,
                    height = max_img_h,
                    original_in_nightmode = false,
                }
            end

            folder_cover = FrameContainer:new {
                width = dimen.h, -- using h here to create a square dimen
                height = dimen.h,
                margin = 0,
                padding = 0,
                color = Blitbuffer.COLOR_WHITE,
                bordersize = border_size,
                dim = self.file_deleted,
                subfolder_cover_image,
            }
            self.menu._has_cover_images = true
            self._has_cover_image = true
        else
            folder_cover = HorizontalSpan:new { width = Screen:scaleBySize(5) }
        end

        local wleft_width = dimen.w - dimen.h - wright_width - 3 * pad_width
        local wlefttext = BD.directory(self.text:sub(1, -2))

        local folderfont = good_serif
        -- style folder names differently in pathchooser
        if is_pathchooser then
            wlefttext = BD.directory(self.text)
            folderfont = good_sans
        end

        local wleft = TextBoxWidget:new {
            text = wlefttext,
            face = Font:getFace(folderfont, title_font_size),
            width = wleft_width,
            alignment = "left",
            bold = false,
            height = dimen.h,
            height_adjust = true,
            height_overflow_show_ellipsis = true,
        }

        widget = OverlapGroup:new {
            LeftContainer:new {
                dimen = dimen:copy(),
                HorizontalGroup:new {
                    folder_cover,
                    HorizontalSpan:new { width = Screen:scaleBySize(5) },
                    wleft,
                }
            },
            RightContainer:new {
                dimen = dimen:copy(),
                HorizontalGroup:new {
                    wright,
                    HorizontalSpan:new { width = pad_width },
                },
            },
        }
    else                                   -- file
        self.file_deleted = self.entry.dim -- entry with deleted file from History or selected file from FM
        local fgcolor = self.file_deleted and Blitbuffer.COLOR_DARK_GRAY or nil

        local bookinfo = BookInfoManager:getBookInfo(self.filepath, self.do_cover_image)

        if bookinfo and self.do_cover_image and not bookinfo.ignore_cover and not self.file_deleted then
            if bookinfo.cover_fetched then
                if bookinfo.has_cover and not self.menu.no_refresh_covers then
                    --if BookInfoManager.isCachedCoverInvalid(bookinfo, cover_specs) then
                    -- skip this. we're storing a single thumbnail res and that's it.
                    --end
                end
                -- if not has_cover, book has no cover, no need to try again
            else
                -- cover was not fetched previously, do as if not found
                -- to force a new extraction
                bookinfo = nil
            end
        end

        local book_info = self.menu.getBookInfo(self.filepath)
        self.been_opened = book_info.been_opened
        if bookinfo and is_pathchooser == false then -- This book is known (and not in patchooser mode)
            self.bookinfo_found = true
            local cover_bb_used = false

            -- Build the left widget : image if wanted
            local wleft = nil
            local wleft_width = 0 -- if not do_cover_image
            local wleft_height
            if self.do_cover_image then
                if bookinfo.has_cover and not bookinfo.ignore_cover then
                    wleft_height = dimen.h
                    wleft_width = wleft_height -- make it squared
                    cover_bb_used = true
                    -- Let ImageWidget do the scaling and give us the final size
                    local _, _, scale_factor = BookInfoManager.getCachedCoverSize(bookinfo.cover_w, bookinfo.cover_h,
                        max_img_w, max_img_h)
                    local wimage = ImageWidget:new {
                        image = bookinfo.cover_bb,
                        scale_factor = scale_factor,
                    }
                    wimage:_render()
                    local image_size = wimage:getSize() -- get final widget size
                    wleft = CenterContainer:new {
                        dimen = Geom:new { w = wleft_width, h = wleft_height },
                        FrameContainer:new {
                            width = image_size.w + 2 * border_size,
                            height = image_size.h + 2 * border_size,
                            margin = 0,
                            padding = 0,
                            color = Blitbuffer.COLOR_WHITE,
                            bordersize = border_size,
                            dim = self.file_deleted,
                            wimage,
                        }
                    }
                    -- Let menu know it has some item with images
                    self.menu._has_cover_images = true
                    self._has_cover_image = true
                    -- add generic file icons, but not in pathchooser
                else
                    -- use generic file icon insteaed of cover image
                    wleft_height = dimen.h
                    wleft_width = wleft_height -- make it squared
                    cover_bb_used = true
                    local _, _, scale_factor = BookInfoManager.getCachedCoverSize(250, 500, max_img_w, max_img_h)
                    local wimage
                    if bookinfo._no_provider then
                        wimage = ImageWidget:new({
                            file = getSourceDir() .. "/resources/file-unsupported.svg",
                            alpha = true,
                            scale_factor = scale_factor,
                            original_in_nightmode = false,
                        })
                    else
                        wimage = ImageWidget:new({
                            file = getSourceDir() .. "/resources/file.svg",
                            alpha = true,
                            scale_factor = scale_factor,
                            original_in_nightmode = false,
                        })
                    end
                    wimage:_render()
                    local image_size = wimage:getSize() -- get final widget size
                    wleft = CenterContainer:new {
                        dimen = Geom:new { w = wleft_width, h = wleft_height },
                        FrameContainer:new {
                            -- add large white (transparent) border to cover art, which acts as "padding"
                            width = image_size.w + 2 * border_size,
                            height = image_size.h + 2 * border_size,
                            margin = 0,
                            padding = 0,
                            color = Blitbuffer.COLOR_WHITE,
                            bordersize = border_size,
                            dim = self.file_deleted,
                            wimage,
                        }
                    }
                    -- Let menu know it has some item with images
                    self.menu._has_cover_images = true
                    self._has_cover_image = true
                end
            end

            -- In case we got a blitbuffer and didnt use it (ignore_cover), free it
            if bookinfo.cover_bb and not cover_bb_used then
                bookinfo.cover_bb:free()
            end

            -- Gather some info, mostly for right widget:
            --   file size (self.mandatory) (not available with History)
            --   file type
            --   pages read / nb of pages (not available for crengine doc not opened)
            -- Current page / pages are available or more accurate in .sdr/metadata.lua
            -- We use a cache (cleaned at end of this browsing session) to store
            -- page, percent read and book status from sidecar files, to avoid
            -- re-parsing them when re-rendering a visited page

            if not self.menu.cover_info_cache then
                self.menu.cover_info_cache = {}
            end

            local finished_text = "Finished"
            local abandoned_string = "On Hold"
            local read_text = "Read"
            local unread_text = "New"
            local pages_str = ""
            local pages_left_str = ""
            local percent_str = ""
            local progress_str = ""

            local pages = book_info.pages or bookinfo.pages -- default to those in bookinfo db
            local percent_finished = book_info.percent_finished
            local status = book_info.status

            -- right widget, first line
            local directory, filename = util.splitFilePathName(self.filepath) -- luacheck: no unused
            local filename_without_suffix, filetype = filemanagerutil.splitFileNameType(filename)
            local fileinfo_str
            if bookinfo._no_provider then
                -- for unsupported files: don't show extension on the right,
                -- keep it in filename
                filename_without_suffix = filename
                fileinfo_str = self.mandatory
            else
                local mark = has_highlight and "\u{2592}  " or "" -- "medium shade"
                fileinfo_str = mark .. BD.wrap(filetype) .. "  " .. BD.wrap(self.mandatory)
            end
            -- right widget, second line
            local wright_right_padding = 0
            local wright_width = 0
            local wright_height = 0
            local wright_items = { align = "right" }

            local est_page_count = bookinfo.pages or nil
            if BookInfoManager:getSetting("force_max_progressbars") then est_page_count = 700 end -- override metadata
            if est_page_count and
                not BookInfoManager:getSetting("hide_page_info") and
                not BookInfoManager:getSetting("show_pages_read_as_progress") then
                local progressbar_items = { align = "center" }

                local fn_pages = tonumber(est_page_count)
                local max_progress_size = 235
                local pixels_per_page = 3
                local min_progress_size = 25
                local total_pixels = math.max(
                    (math.min(math.floor((fn_pages / pixels_per_page) + 0.5), max_progress_size)), min_progress_size)
                local progress_bar = ProgressWidget:new {
                    width = Screen:scaleBySize(total_pixels),
                    height = Screen:scaleBySize(15),
                    margin_v = 0,
                    margin_h = 0,
                    bordersize = Screen:scaleBySize(0.5),
                    bordercolor = Blitbuffer.COLOR_BLACK,
                    bgcolor = Blitbuffer.COLOR_GRAY_E,
                    fillcolor = Blitbuffer.COLOR_GRAY_6,
                    percentage = 0,
                }

                local progress_width = progress_bar:getSize().w
                local progress_dimen
                local bar_and_icons
                local bar_icon_size = Screen:scaleBySize(23)        -- size for icons used with progress bar
                if status == "complete" and fn_pages > (max_progress_size * pixels_per_page) then
                    progress_width = progress_width + bar_icon_size -- both icons need 2x half-width (1 full width) added
                    progress_dimen = Geom:new {
                        x = 0, y = 0,
                        w = progress_width,
                        h = bar_icon_size,
                    }
                    bar_and_icons = CenterContainer:new {
                        dimen = progress_dimen,
                        progress_bar,
                    }
                elseif status == "complete" then
                    progress_width = progress_width + math.floor(bar_icon_size / 2) -- one icon needs 1x half-width added
                    progress_dimen = Geom:new {
                        x = 0, y = 0,
                        w = progress_width,
                        h = bar_icon_size,
                    }
                    bar_and_icons = LeftContainer:new {
                        dimen = progress_dimen,
                        progress_bar,
                    }
                elseif fn_pages > (max_progress_size * pixels_per_page) then
                    progress_width = progress_width + math.floor(bar_icon_size / 2) -- one icon needs 1x half-width added
                    progress_dimen = Geom:new {
                        x = 0, y = 0,
                        w = progress_width,
                        h = bar_icon_size,
                    }
                    bar_and_icons = RightContainer:new {
                        dimen = progress_dimen,
                        progress_bar,
                    }
                else
                    progress_dimen = Geom:new {
                        x = 0, y = 0,
                        w = progress_width, -- no icons needs no width added
                        h = bar_icon_size,
                    }
                    bar_and_icons = CenterContainer:new {
                        dimen = progress_dimen,
                        progress_bar,
                    }
                end
                local progress_block = OverlapGroup:new {
                    dimen = progress_dimen,
                }
                table.insert(progress_block, bar_and_icons)

                -- books with fn_page_count larger than the max get an indicator at the left edge of the progress bar
                if fn_pages > (max_progress_size * pixels_per_page) then
                    local max_widget = ImageWidget:new({
                        file = getSourceDir() .. "/resources/large_book.svg",
                        width = bar_icon_size,
                        height = bar_icon_size,
                        scale_factor = 0,
                        alpha = true,
                        original_in_nightmode = false,
                    })
                    table.insert(progress_block, LeftContainer:new {
                        dimen = progress_dimen,
                        max_widget,
                    })
                end

                if status == "complete" then
                    progress_bar.percentage = 1
                    -- books marked as "Finished" get a little trophy at the right edge of the progress bar
                    local trophy_widget = ImageWidget:new({
                        file = getSourceDir() .. "/resources/trophy.svg",
                        width = bar_icon_size,
                        height = bar_icon_size,
                        scale_factor = 0,
                        alpha = true,
                        original_in_nightmode = false,
                    })
                    table.insert(progress_block, RightContainer:new {
                        dimen = progress_dimen,
                        trophy_widget,
                    })
                    table.insert(progressbar_items, progress_block)
                elseif status == "abandoned" then
                    progress_bar.percentage = 1
                    table.insert(progressbar_items, progress_block)
                elseif percent_finished then
                    progress_bar.percentage = percent_finished
                    table.insert(progressbar_items, progress_block)
                else
                    table.insert(progressbar_items, progress_block)
                end

                for i, w in ipairs(progressbar_items) do
                    wright_width = wright_width + w:getSize().w
                end
                local progress = RightContainer:new {
                    dimen = Geom:new { w = wright_width, h = 50 },
                    HorizontalGroup:new(progressbar_items),
                }
                table.insert(wright_items, progress)
            end

            -- show progress text, page text, and/or file info text
            if status == "complete" then
                progress_str = finished_text
            elseif status == "abandoned" then
                progress_str = abandoned_string
            elseif percent_finished then
                progress_str = ""
                percent_str = math.floor(100 * percent_finished) .. "% " .. read_text
                if pages then
                    if BookInfoManager:getSetting("show_pages_read_as_progress") then
                        pages_str = T(_("Page %1 of %2"), Math.round(percent_finished * pages), pages)
                    end
                    if BookInfoManager:getSetting("show_pages_left_in_progress") then
                        pages_left_str = T(_("%1 pages left"), Math.round(pages - percent_finished * pages), pages)
                    end
                end
            elseif not bookinfo._no_provider then
                progress_str = unread_text
            end

            if not BookInfoManager:getSetting("hide_page_info") then
                if progress_str ~= "" then
                    local wprogressinfo = TextWidget:new {
                        text = progress_str,
                        face = wright_font_face,
                        fgcolor = fgcolor,
                        padding = 0,
                    }
                    table.insert(wright_items, 1, wprogressinfo)
                end
                if BookInfoManager:getSetting("show_pages_read_as_progress") then
                    if pages_str ~= "" then
                        local wpageinfo = TextWidget:new {
                            text = pages_str,
                            face = wright_font_face,
                            fgcolor = fgcolor,
                            padding = 0,
                        }
                        table.insert(wright_items, 1, wpageinfo)
                    end
                else
                    if percent_str ~= "" then
                        local wpercentinfo = TextWidget:new {
                            text = percent_str,
                            face = wright_font_face,
                            fgcolor = fgcolor,
                            padding = 0,
                        }
                        table.insert(wright_items, 1, wpercentinfo)
                    end
                end
                if BookInfoManager:getSetting("show_pages_left_in_progress") then
                    if pages_left_str ~= "" then
                        local wpagesleftinfo = TextWidget:new {
                            text = pages_left_str,
                            face = wright_font_face,
                            fgcolor = fgcolor,
                            padding = 0,
                        }
                        table.insert(wright_items, 1, wpagesleftinfo)
                    end
                end
            end
            if not BookInfoManager:getSetting("hide_file_info") then
                local wfileinfo = TextWidget:new {
                    text = fileinfo_str,
                    face = wright_font_face,
                    fgcolor = fgcolor,
                    padding = 0,
                }
                table.insert(wright_items, 1, wfileinfo)
            end

            if #wright_items > 0 then
                for i, w in ipairs(wright_items) do
                    wright_width = math.max(wright_width, w:getSize().w)
                    wright_height = wright_height + w:getSize().h
                end
                wright_right_padding = Screen:scaleBySize(10)
            end

            -- Build the middle main widget, in the space available
            local wmain_left_padding = Screen:scaleBySize(10)
            if self.do_cover_image then
                -- we need less padding, as cover image, most often in
                -- portrait mode, will provide some padding
                wmain_left_padding = Screen:scaleBySize(5)
            end

            local wmain_width = dimen.w - wleft_width - wmain_left_padding
            local fontname_title = title_serif
            local fontname_authors = good_serif
            local bold_title = false
            local fontsize_title = title_font_size
            local fontsize_authors = authors_font_size
            local wtitle, wauthors
            local title, authors
            local series_mode = BookInfoManager:getSetting("series_mode")
            local show_series = bookinfo.series and bookinfo.series_index and
                bookinfo.series_index ~=
                0                      -- suppress series if index is "0"

            -- whether to use or not title and authors
            -- (We wrap each metadata text with BD.auto() to get for each of them
            -- the text direction from the first strong character - which should
            -- individually be the best thing, and additionnaly prevent shuffling
            -- if concatenated.)
            if self.do_filename_only or bookinfo.ignore_meta then
                title = filename_without_suffix -- made out above
                title = BD.auto(title)
                authors = nil
            else
                title = bookinfo.title and bookinfo.title or filename_without_suffix
                title = BD.auto(title)
                authors = bookinfo.authors
                -- If multiple authors (crengine separates them with \n), we
                -- can display them on multiple lines, but limit to 2, and
                -- append "et al." to the 2nd if there are more
                if authors and authors:find("\n") then
                    authors = util.splitToArray(authors, "\n")
                    for i = 1, #authors do
                        authors[i] = BD.auto(authors[i])
                    end
                    if #authors > 1 and show_series and series_mode == "series_in_separate_line" then
                        authors = { T(_("%1 et al."), authors[1]) }
                    elseif #authors > 2 then
                        authors = { authors[1], T(_("%1 et al."), authors[2]) }
                    end
                    authors = table.concat(authors, "\n")
                elseif authors then
                    authors = BD.auto(authors)
                end
            end
            -- series name and position (if available, if requested)
            if show_series then
                if string.match(bookinfo.series, ": ") then
                    bookinfo.series = string.sub(bookinfo.series, findLast(bookinfo.series, ": ") + 1, -1)
                end
                if bookinfo.series_index then
                    -- bookinfo.series = "\u{FFF1}#" .. bookinfo.series_index .. " – " .. "\u{FFF2}" .. BD.auto(bookinfo.series) .. "\u{FFF3}"
                    bookinfo.series = "#" .. bookinfo.series_index .. " – " .. BD.auto(bookinfo.series)
                else
                    bookinfo.series = BD.auto(bookinfo.series)
                end
                local series = bookinfo.series
                if not authors then
                    if series_mode == "series_in_separate_line" then
                        authors = series
                    end
                else
                    if series_mode == "series_in_separate_line" then
                        authors = series .. "\n" .. authors
                    end
                end
            end
            if bookinfo.unsupported then
                -- Let's show this fact in place of the anyway empty authors slot
                authors = T(_("(no book information: %1)"), _(bookinfo.unsupported))
            end

            -- Build title and authors texts with decreasing font size
            -- till it fits in the space available
            local build_title = function()
                if wtitle then
                    wtitle:free(true)
                    wtitle = nil
                end
                -- BookInfoManager:extractBookInfo() made sure
                -- to save as nil (NULL) metadata that were an empty string
                -- We provide the book language to get a chance to render title
                -- and authors with alternate glyphs for that language.

                -- call this style for items like txt files
                if bookinfo.unsupported or bookinfo._no_provider or not bookinfo.authors then
                    fontname_title = good_serif
                    bold_title = true
                end

                wtitle = TextWidget:new {
                    text = title,
                    lang = bookinfo.language,
                    face = Font:getFace(fontname_title, fontsize_title),
                    max_width = wmain_width - wright_right_padding,
                    padding = 0,
                    truncate_with_ellipsis = true,
                    alignment = "left",
                    bold = bold_title,
                    fgcolor = fgcolor,
                }
            end

            local build_multiline_title = function()
                if wtitle then
                    wtitle:free(true)
                    wtitle = nil
                end

                wtitle = TextBoxWidget:new {
                    text = title,
                    lang = bookinfo.language,
                    face = Font:getFace(fontname_title, fontsize_title),
                    width = wmain_width - wright_right_padding,
                    height_adjust = true,
                    height_overflow_show_ellipsis = true,
                    alignment = "left",
                    bold = bold_title,
                    fgcolor = fgcolor,
                }
            end

            local build_authors = function(width)
                if wauthors then
                    wauthors:free(true)
                    wauthors = nil
                end
                wauthors = TextBoxWidget:new {
                    text = authors,
                    lang = bookinfo.language,
                    face = Font:getFace(fontname_authors, fontsize_authors),
                    width = width,
                    height_adjust = true,
                    alignment = "left",
                    fgcolor = Blitbuffer.COLOR_GRAY_2,
                }
            end

            -- make title and author/wright fit within the line height
            local authors_width = wmain_width - wright_right_padding
            local avail_dimen_h = dimen.h
            while true do
                build_title()
                build_authors(authors_width)

                -- if the single-line title is ... then reduce font to try fitting it
                while wtitle:isTruncated() do
                    if fontsize_title <= 20 then
                        break
                    end
                    fontsize_title = fontsize_title - fontsize_dec_step
                    build_title()
                end

                local height = wtitle:getSize().h
                height = height + wauthors:getSize().h
                if height <= avail_dimen_h then -- We fit!
                    break
                end
                -- Don't go too low, and get out of this loop.
                if fontsize_title <= 12 or fontsize_authors <= 10 then
                    local title_height = wtitle:getSize().h
                    local title_line_height = wtitle:getLineHeight()
                    local title_min_height = 2 * title_line_height -- unscaled_size_check: ignore
                    local authors_height = authors and wauthors:getSize().h or 0
                    authors_height = math.max(authors_height, wright_height)
                    local authors_line_height = authors and wauthors:getLineHeight() or 0
                    local authors_min_height = 2 * authors_line_height -- unscaled_size_check: ignore
                    -- Chop lines, starting with authors, until
                    -- both labels fit in the allocated space.
                    while title_height + authors_height > dimen.h do
                        if authors_height > authors_min_height then
                            authors_height = authors_height - authors_line_height
                        elseif title_height > title_min_height then
                            title_height = title_height - title_line_height
                        else
                            break
                        end
                    end
                    if title_height < wtitle:getSize().h then
                        build_title()
                    end
                    if authors and authors_height < wauthors:getSize().h then
                        build_authors(authors_width)
                    end
                    break
                end
                -- If we don't fit, decrease both font sizes
                fontsize_title = fontsize_title - fontsize_dec_step
                fontsize_authors = fontsize_authors - fontsize_dec_step
            end

            -- if there is room for a 2+ line title, do it and max out the font size
            local title_ismultiline = false
            if wtitle:getSize().h * 2 < avail_dimen_h - math.max(wauthors:getSize().h, wright_height) then
                title_ismultiline = true
                build_multiline_title()
                -- if the multiline title doesn't fit even with the smallest font size, give up
                if wtitle:getSize().h + math.max(wauthors:getSize().h, wright_height) > avail_dimen_h then
                    build_title()
                    title_ismultiline = false
                else
                    while wtitle:getSize().h + math.max(wauthors:getSize().h, wright_height) < avail_dimen_h do
                        if fontsize_title >= 26 then
                            break
                        end
                        fontsize_title = fontsize_title + fontsize_dec_step
                        build_multiline_title()
                        -- if we overshoot, go back a step
                        if wtitle:getSize().h + math.max(wauthors:getSize().h, wright_height) > avail_dimen_h then
                            fontsize_title = fontsize_title - fontsize_dec_step
                            build_multiline_title()
                            break
                        end
                    end
                end
            end

            -- if the wider wauthors+wright doesn't fit, go back to a reduced width and reduce font sizes
            local wauthors_iswider = true
            if dimen.h - wtitle:getSize().h <= wauthors:getSize().h + wright_height then
                wauthors_iswider = false
                authors_width = wmain_width - (wright_width + wright_right_padding)
                build_authors(authors_width)
                while wauthors:getSize().h > avail_dimen_h - wtitle:getSize().h do
                    if fontsize_authors <= 10 then
                        break
                    end
                    fontsize_authors = fontsize_authors - fontsize_dec_step
                    fontsize_title = fontsize_title - fontsize_dec_step
                    if title_ismultiline then
                        build_multiline_title()
                    else
                        build_title()
                    end
                    build_authors(authors_width)
                end
            else
                -- it did fit, so now pad wright vertically
                table.insert(wright_items, 1, VerticalSpan:new { width = wauthors:getSize().h })
            end

            local title_padding = wtitle:getSize().h
            local wauthors_padding = wmain_width - wright_width - wright_right_padding

            -- enable this to debug "flow mode"
            -- if wtitle:getSize().h + math.max(wauthors:getSize().h, wright_height) > avail_dimen_h then
            --     logger.info("BUFFER UNDERRUN")
            --     logger.info("dimen.h ", dimen.h )
            --     logger.info("avail_dimen_h ", avail_dimen_h)
            --     logger.info("title ", title)
            --     logger.info("title_ismultiline ", title_ismultiline)
            --     logger.info("wtitle:getSize().h ", wtitle:getSize().h)
            --     logger.info("fontsize_title ", fontsize_title)
            --     logger.info("authors ", authors)
            --     logger.info("wauthors_iswider ", wauthors_iswider)
            --     logger.info("wauthors:getSize().h ", wauthors:getSize().h)
            --     logger.info("wauthors:getSize().w ", wauthors:getSize().w)
            --     logger.info("wauthors_padding ", wauthors_padding)
            --     logger.info("authors_width ", authors_width)
            --     logger.info("fontsize_authors ", fontsize_authors)
            --     logger.info("wright_height ", wright_height)
            --     logger.info("wright_width ", wright_width)
            -- end

            -- style files differently in pathchooser
            local wtitle_container = TopContainer:new {
                dimen = Geom:new { w = wmain_width - wright_width - wright_right_padding, h = wtitle:getSize().h },
                wtitle,
            }

            -- build the main widget which holds wtitle, wauthors, and wright
            local wmain = LeftContainer:new {
                dimen = dimen:copy(),
                OverlapGroup:new {
                    TopContainer:new {
                        dimen = dimen:copy(),
                        VerticalGroup:new {
                            VerticalSpan:new { width = title_padding },
                            OverlapGroup:new {
                                TopContainer:new {
                                    dimen = dimen:copy(),
                                    wauthors,
                                },
                                TopContainer:new {
                                    dimen = dimen:copy(),
                                    HorizontalGroup:new {
                                        HorizontalSpan:new { width = wauthors_padding },
                                        TopContainer:new {
                                            dimen = dimen:copy(),
                                            VerticalGroup:new(wright_items),
                                        },
                                        HorizontalSpan:new { width = wright_right_padding },
                                    },
                                },
                            },
                        },
                    },
                    wtitle_container
                }
            }

            -- Build the final widget
            widget = OverlapGroup:new {
                dimen = dimen:copy(),
            }
            if self.do_cover_image then
                -- add left widget
                if wleft then
                    -- no need for left padding, as cover image, most often in
                    -- portrait mode, will have some padding - the rare landscape
                    -- mode cover image will be stuck to screen side thus
                    table.insert(widget, wleft)
                end
                -- pad main widget on the left with size of left widget
                wmain = HorizontalGroup:new {
                    HorizontalSpan:new { width = wleft_width },
                    HorizontalSpan:new { width = wmain_left_padding },
                    wmain
                }
            else
                -- pad main widget on the left
                wmain = HorizontalGroup:new {
                    HorizontalSpan:new { width = wmain_left_padding },
                    wmain
                }
            end
            -- add padded main widget
            table.insert(widget, LeftContainer:new {
                dimen = dimen:copy(),
                wmain
            })
        elseif is_pathchooser == true then -- pathchooser mode
            local wright
            local wright_width = 0
            local wright_items = { align = "right" }
            local pad_width = Screen:scaleBySize(10) -- on the left, in between, and on the right

            local wmandatory = TextWidget:new {
                text = self.mandatory or "",
                face = wright_font_face,
            }
            table.insert(wright_items, wmandatory)

            if #wright_items > 0 then
                for i, w in ipairs(wright_items) do
                    wright_width = math.max(wright_width, w:getSize().w)
                end
                wright = CenterContainer:new {
                    dimen = Geom:new { w = wright_width, h = dimen.h },
                    VerticalGroup:new(wright_items),
                }
            end

            local wleft_width = dimen.w - dimen.h - wright_width - 3 * pad_width
            local wlefttext = BD.filename(self.text)
            local filefont = good_sans
            local wleft = TextBoxWidget:new {
                text = wlefttext,
                face = Font:getFace(filefont, title_font_size),
                width = wleft_width,
                alignment = "left",
                bold = false,
                height = dimen.h,
                height_adjust = true,
                height_overflow_show_ellipsis = true,
            }

            widget = OverlapGroup:new {
                LeftContainer:new {
                    dimen = dimen:copy(),
                    HorizontalGroup:new {
                        HorizontalSpan:new { width = Screen:scaleBySize(5) },
                        wleft,
                    }
                },
                RightContainer:new {
                    dimen = dimen:copy(),
                    HorizontalGroup:new {
                        wright,
                        HorizontalSpan:new { width = pad_width },
                    },
                },
            }
        else -- bookinfo not found
            if self.init_done then
                -- Non-initial update(), but our widget is still not found:
                -- it does not need to change, so avoid remaking the same widget
                return
            end
            -- If we're in no image mode, don't save images in DB : people
            -- who don't care about images will have a smaller DB, but
            -- a new extraction will have to be made when one switch to image mode
            if self.do_cover_image then
                -- Not in db, we're going to fetch some cover
                self.cover_specs = cover_specs
            end
            --
            if self.do_hint_opened and DocSettings:hasSidecarFile(self.filepath) then
                self.been_opened = true
            end
            -- No right widget by default, except in History
            local wright
            local wright_width = 0
            local wright_right_padding = 0
            if self.mandatory then
                -- Currently only provided by History, giving the last time read.
                -- If we have it, we need to build a more complex widget with
                -- this date on the right
                local fileinfo_str = self.mandatory
                local wfileinfo = TextWidget:new {
                    text = fileinfo_str,
                    face = wright_font_face,
                    fgcolor = fgcolor,
                }
                local wpageinfo = TextWidget:new { -- Empty but needed for similar positionning
                    text = "",
                    face = wright_font_face,
                }
                wright_width = wfileinfo:getSize().w
                wright = CenterContainer:new {
                    dimen = Geom:new { w = wright_width, h = dimen.h },
                    VerticalGroup:new {
                        align = "right",
                        VerticalSpan:new { width = Screen:scaleBySize(2) },
                        wfileinfo,
                        wpageinfo,
                    }
                }
                wright_right_padding = Screen:scaleBySize(10)
            end
            -- A real simple widget, nothing fancy
            local hint = "…" -- display hint it's being loaded
            if self.file_deleted then -- unless file was deleted (can happen with History)
                hint = " " .. _("(deleted)")
            end
            local text = BD.filename(self.text)
            local text_widget
            local fontsize_no_bookinfo = title_font_size
            repeat
                if text_widget then
                    text_widget:free(true)
                end
                text_widget = TextBoxWidget:new {
                    text = text .. hint,
                    face = Font:getFace(good_sans, fontsize_no_bookinfo),
                    width = dimen.w - 2 * Screen:scaleBySize(10) - wright_width - wright_right_padding,
                    alignment = "left",
                    fgcolor = fgcolor,
                }
                -- reduce font size for next loop, in case text widget is too large to fit into ListMenuItem
                fontsize_no_bookinfo = fontsize_no_bookinfo - fontsize_dec_step
            until text_widget:getSize().h <= dimen.h
            widget = LeftContainer:new {
                dimen = dimen:copy(),
                HorizontalGroup:new {
                    HorizontalSpan:new { width = Screen:scaleBySize(10) },
                    text_widget
                },
            }
            if wright then -- last read date, in History, even for deleted files
                widget = OverlapGroup:new {
                    dimen = dimen:copy(),
                    widget,
                    RightContainer:new {
                        dimen = dimen:copy(),
                        HorizontalGroup:new {
                            wright,
                            HorizontalSpan:new { width = wright_right_padding },
                        },
                    },
                }
            end
        end
    end

    -- Fill container with our widget
    if self._underline_container[1] then
        -- There is a previous one, that we need to free()
        local previous_widget = self._underline_container[1]
        previous_widget:free()
    end
    -- Add some pad at top to balance with hidden underline line at bottom
    self._underline_container[1] = VerticalGroup:new {
        VerticalSpan:new { width = self.underline_h },
        widget
    }
end

function ListMenuItem:paintTo(bb, x, y)
    -- We used to get non-integer x or y that would cause some mess with image
    -- inside FrameContainer were image would be drawn on top of the top border...
    -- Fixed by having TextWidget:updateSize() math.ceil()'ing its length and height
    -- But let us know if that happens again
    if x ~= math.floor(x) or y ~= math.floor(y) then
        logger.err("ListMenuItem:paintTo() got non-integer x/y :", x, y)
    end

    -- Original painting
    InputContainer.paintTo(self, bb, x, y)

    -- to which we paint over the shortcut icon
    if self.shortcut_icon then
        -- align it on bottom left corner of sub-widget
        local target = self[1][1][2]
        local ix
        if BD.mirroredUILayout() then
            ix = target.dimen.w - self.shortcut_icon.dimen.w
        else
            ix = 0
        end
        local iy = target.dimen.h - self.shortcut_icon.dimen.h
        self.shortcut_icon:paintTo(bb, x + ix, y + iy)
    end
end

-- As done in MenuItem
function ListMenuItem:onFocus()
    -- do nothing to indicate focus
    return true
end

function ListMenuItem:onUnfocus()
    -- do nothing to indicate focus
    return true
end

-- The transient color inversions done in MenuItem:onTapSelect
-- and MenuItem:onHoldSelect are ugly when done on an image,
-- so let's not do it
-- Also, no need for 2nd arg 'pos' (only used in readertoc.lua)
function ListMenuItem:onTapSelect(arg)
    self.menu:onMenuSelect(self.entry)
    return true
end

function ListMenuItem:onHoldSelect(arg, ges)
    self.menu:onMenuHold(self.entry)
    return true
end

-- Simple holder of methods that will replace those
-- in the real Menu class or instance
local ListMenu = {}

function ListMenu:_recalculateDimen()
    local Menu = require("ui/widget/menu")
    local perpage = self.items_per_page or G_reader_settings:readSetting("items_per_page") or self
        .items_per_page_default
    local font_size = self.items_font_size or G_reader_settings:readSetting("items_font_size") or
        Menu.getItemFontSize(perpage)
    if self.perpage ~= perpage or self.font_size ~= font_size then
        self.perpage = perpage
        self.font_size = font_size
    end

    self.portrait_mode = Screen:getWidth() <= Screen:getHeight()
    -- Find out available height from other UI elements made in Menu
    self.others_height = 0

    -- test to see what style to draw (pathchooser vs "detailed list view mode")
    is_pathchooser = false
    if self.title_bar and util.stringEndsWith(self.title_bar.title, "name to choose it") then
        is_pathchooser = true
    end

    if self.title_bar then -- Menu:init() has been done
        if not self.is_borderless then
            self.others_height = self.others_height + 2
        end
        if not self.no_title then
            self.others_height = self.others_height -- + self.header_padding
            self.others_height = self.others_height + self.title_bar.dimen.h
        end
        if self.page_info then
            self.others_height = self.others_height + self.page_info:getSize().h
        end
    else
        -- Menu:init() not yet done: other elements used to calculate self.others_heights
        -- are not yet defined, so next calculations will be wrong, and we may get
        -- a self.perpage higher than it should be: Menu:init() will set a wrong self.page.
        -- We'll have to update it, if we want FileManager to get back to the original page.
        self.page_recalc_needed_next_time = true
        -- Also remember original position (and focused_path), which will be changed by
        -- Menu/FileChooser to a probably wrong value
        self.itemnum_orig = self.path_items[self.path]
        self.focused_path_orig = self.focused_path
    end
    local available_height = self.inner_dimen.h - self.others_height - Size.line.thin

    if self.files_per_page == nil then -- first drawing
        -- Default perpage is computed from a base of 90px per ListMenuItem,
        -- which gives 7 items on kobo aura one/glo hd/sage
        self.files_per_page = math.floor(available_height / scale_by_size / 90)
        BookInfoManager:saveSetting("files_per_page", self.files_per_page)
    end
    self.perpage = self.files_per_page
    if not self.portrait_mode then
        -- When in landscape mode, adjust perpage so items get a chance
        -- to have about the same height as when in portrait mode.
        -- This computation is not strictly correct, as "others_height" would
        -- have a different value in portrait mode. But let's go with that.
        local portrait_available_height = Screen:getWidth() - self.others_height - Size.line.thin
        local portrait_item_height = math.floor(portrait_available_height / self.perpage) - Size.line.thin
        self.perpage = Math.round(available_height / portrait_item_height)
    end

    self.page_num = math.ceil(#self.item_table / self.perpage)
    -- fix current page if out of range
    if self.page_num > 0 and self.page > self.page_num
    then
        self.page = self.page_num
    end

    -- menu item height based on number of items per page
    -- add space for the separator
    self.item_height = math.floor(available_height / self.perpage) - Size.line.thin
    self.item_width = self.inner_dimen.w
    self.item_dimen = Geom:new {
        x = 0, y = 0,
        w = self.item_width,
        h = self.item_height
    }

    if self.page_recalc_needed then
        -- self.page has probably been set to a wrong value, we recalculate
        -- it here as done in Menu:init() or Menu:switchItemTable()
        if #self.item_table > 0 then
            self.page = math.ceil((self.itemnum_orig or 1) / self.perpage)
        end
        if self.focused_path_orig then
            for num, item in ipairs(self.item_table) do
                if item.path == self.focused_path_orig then
                    self.page = math.floor((num - 1) / self.perpage) + 1
                    break
                end
            end
        end
        if self.page_num > 0 and self.page > self.page_num then self.page = self.page_num end
        self.page_recalc_needed = nil
        self.itemnum_orig = nil
        self.focused_path_orig = nil
    end
    if self.page_recalc_needed_next_time then
        self.page_recalc_needed = true
        self.page_recalc_needed_next_time = nil
    end
end

function ListMenu:_updateItemsBuildUI()
    -- Build our list
    local line_width = self.width or self.screen_w
    -- create and draw the top-most line at 94% screen width (acts like bottom line for titlebar)
    local line_widget = HorizontalGroup:new {
        HorizontalSpan:new { width = line_width * 0.03 },
        LineWidget:new {
            dimen = Geom:new { w = line_width * 0.94, h = Size.line.medium },
            background = Blitbuffer.COLOR_BLACK,
        },
        HorizontalSpan:new { width = line_width * 0.03 },
    }
    table.insert(self.item_group, line_widget)
    local idx_offset = (self.page - 1) * self.perpage
    for idx = 1, self.perpage do
        local index = idx_offset + idx
        local entry = self.item_table[index]
        if entry == nil then break end
        entry.idx = index
        -- Keyboard shortcuts, as done in Menu
        local item_shortcut, shortcut_style
        if self.is_enable_shortcut then
            item_shortcut = self.item_shortcuts[idx]
            shortcut_style = (idx < 11 or idx > 20) and "square" or "grey_square"
        end

        local item_tmp = ListMenuItem:new {
            height = self.item_height,
            width = self.item_width,
            entry = entry,
            text = getMenuText(entry),
            show_parent = self.show_parent,
            mandatory = entry.mandatory,
            dimen = self.item_dimen:copy(),
            shortcut = item_shortcut,
            shortcut_style = shortcut_style,
            menu = self,
            do_cover_image = self._do_cover_images,
            do_hint_opened = self._do_hint_opened,
            do_filename_only = self._do_filename_only,
        }
        table.insert(self.item_group, item_tmp)
        -- draw smaller, lighter lines under each item except the final item (footer draws its own line)
        if idx < self.perpage then
            local small_line_width = line_width * 0.60
            local small_line_widget = LineWidget:new {
                dimen = Geom:new { w = small_line_width, h = Size.line.thin },
                background = Blitbuffer.COLOR_GRAY,
            }
            table.insert(self.item_group, small_line_widget)
        end

        -- this is for focus manager
        table.insert(self.layout, { item_tmp })

        if not item_tmp.bookinfo_found and not item_tmp.is_directory and not item_tmp.file_deleted then
            -- Register this item for update
            table.insert(self.items_to_update, item_tmp)
        end
    end
end

return ListMenu
