local AlphaContainer = require("ui/widget/container/alphacontainer")
local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
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
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TopContainer = require("ui/widget/container/topcontainer")
local UnderlineContainer = require("ui/widget/container/underlinecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local util = require("util")
local _ = require("l10n.gettext")
local Screen = Device.screen
local T = require("ffi/util").template
local getMenuText = require("ui/widget/menu").getMenuText
local BookInfoManager = require("bookinfomanager")
local ptutil = require("ptutil")
local ptdbg = require("ptdbg")

-- Here is the specific UI implementation for "grid" display modes
-- (see covermenu.lua for the generic code)
local is_pathchooser = false
local plugin_dir = ptutil.getPluginDir()
local alpha_level = 0.84
local tag_width = 0.35
local margin_size = 10

-- We will show a rotated dogear at bottom right corner of cover widget for
-- opened files (the dogear will make it look like a "used book")
-- The ImageWidget will be created when we know the available height (and
-- recreated if height changes)
local corner_mark_size
local corner_mark
local abandoned_mark
local complete_mark
local progress_widget

-- We may find a better algorithm, or just a set of
-- nice looking combinations of 3 sizes to iterate thru
-- the rendering of the TextBoxWidget we're doing below
-- with decreasing font sizes till it fits is quite expensive.

local FakeCover = FrameContainer:extend {
    width = nil,
    height = nil,
    margin = 0,
    padding = 0,
    bordersize = Size.border.thin,
    dim = nil,
    bottom_right_compensate = false,
    -- Provided filename, title and authors should not be BD wrapped
    filename = nil,
    file_deleted = nil,
    title = nil,
    authors = nil,
    -- The *_add should be provided BD wrapped if needed
    filename_add = nil,
    title_add = nil,
    authors_add = nil,
    book_lang = nil,
    -- these font sizes will be scaleBySize'd by Font:getFace()
    authors_font_max = 20,
    authors_font_min = 14,
    series_font_max = 20,
    series_font_min = 14,
    title_font_max = 28,
    title_font_min = 16,
    top_pad = 0,
    bottom_pad = 0,
    sizedec_step = 2,
    initial_sizedec = 0,
    color = Blitbuffer.COLOR_GRAY_3,
    background = Blitbuffer.COLOR_GRAY_E,
}

function FakeCover:init()
    -- BookInfoManager:extractBookInfo() made sure
    -- to save as nil (NULL) metadata that were an empty string
    local authors = self.authors
    local title = self.title
    local filename = self.filename
    local series = nil
    local filesize = nil
    local inter_pad_1
    local inter_pad_2
    local authors_wg, series_wg, filesize_wg, title_wg, filename_wg
    local titlefont
    local width, height
    local title_text_color
    local title_background_color

    if is_pathchooser == false then
        width = self.width - 2 * (self.bordersize + self.margin + self.padding)
        height = self.height - 2 * (self.bordersize + self.margin + self.padding)
        local text_width = width - (Size.padding.small * 2)
        -- BookInfoManager:extractBookInfo() made sure
        -- to save as nil (NULL) metadata that were an empty string

        -- (some engines may have already given filename (without extension) as title)
        local bd_wrap_title_as_filename = false
        titlefont = ptutil.title_serif
        title_text_color = Blitbuffer.COLOR_WHITE
        title_background_color = Blitbuffer.COLOR_GRAY_3
        local bold_title = false
        if not title then -- use filename as title (big and centered)
            titlefont = ptutil.good_serif
            bold_title = true
            title = filename
            title_text_color = Blitbuffer.COLOR_BLACK
            title_background_color = self.background
            if not self.title_add and self.filename_add then
                -- filename_add ("…" or "(deleted)") always comes without any title_add
                self.title_add = self.filename_add
                self.filename_add = nil
            end
            bd_wrap_title_as_filename = true
        end

        -- If no authors, and title is filename without extension, it was
        -- probably made by an engine, and we can consider it a filename, and
        -- act according to common usage in naming files.
        if not authors and title and self.filename and self.filename:sub(1, title:len()) == title then
            bd_wrap_title_as_filename = true
            titlefont = ptutil.good_serif
            bold_title = true
            title_text_color = Blitbuffer.COLOR_BLACK
            title_background_color = self.background
            -- Replace a hyphen surrounded by spaces (which most probably was
            -- used to separate Authors/Title/Serie/Year/Categorie in the
            -- filename with a \n
            title = title:gsub(" %- ", "\n")
            -- Same with |
            title = title:gsub("|", "\n")
            -- Also replace underscores with spaces
            title = title:gsub("_", " ")
            -- Some filenames may also use dots as separators, but dots
            -- can also have some meaning, so we can't just remove them.
            -- But at least, make dots breakable (they wouldn't be if not
            -- followed by a space), by adding to them a zero-width-space,
            -- so the dots stay on the right of their preceeding word.
            title = title:gsub("%.", ".\u{200B}")
            -- Except for a last dot near end of title that might preceed
            -- a file extension: we'd rather want the dot and its suffix
            -- together on a last line: so, move the zero-width-space
            -- before it.
            title = title:gsub("%.\u{200B}(%w%w?%w?%w?%w?)$", "\u{200B}.%1")
            -- These substitutions will hopefully have no impact with the following BD wrapping
        end
        if title then
            title = bd_wrap_title_as_filename and BD.filename(title) or BD.auto(title)
        end

        authors = ptutil.formatAuthors(self.authors, 3)

        if self.title_add then
            title = (title and title or "") .. self.title_add
        end
        if self.authors_add then
            series = self.authors_add
        end

        -- We build the VerticalGroup widget with decreasing font sizes till
        -- the widget fits into available height
        local sizedec = self.initial_sizedec
        local loop2 = false -- we may do a second pass with modifier title and authors strings
        local texts_height
        local free_height
        local textboxes_ok

        while true do
            -- Free previously made widgets to avoid memory leaks
            if authors_wg then
                authors_wg:free(true)
                authors_wg = nil
            end
            if series_wg then
                series_wg:free(true)
                series_wg = nil
            end
            if title_wg then
                title_wg:free(true)
                title_wg = nil
            end
            if filename_wg then
                filename_wg:free(true)
                filename_wg = nil
            end
            -- Build new widgets
            texts_height = 0
            free_height = 0
            if authors then
                authors_wg = TextBoxWidget:new {
                    text = authors,
                    lang = self.book_lang,
                    face = Font:getFace(ptutil.good_serif, math.max(self.authors_font_max - sizedec, self.authors_font_min)),
                    width = text_width,
                    alignment = "center",
                    bgcolor = self.background,
                }
                texts_height = texts_height + authors_wg:getSize().h
            end
            if series then
                series_wg = TextBoxWidget:new {
                    text = series,
                    lang = self.book_lang,
                    face = Font:getFace(ptutil.good_serif, math.max(self.series_font_max - sizedec, self.series_font_min)),
                    width = text_width,
                    alignment = "center",
                    bgcolor = self.background,
                }
                texts_height = texts_height + series_wg:getSize().h
            end
            if title then
                title_wg = TextBoxWidget:new {
                    text = title,
                    lang = self.book_lang,
                    face = Font:getFace(titlefont, math.max(self.title_font_max - sizedec, self.title_font_min)),
                    bold = bold_title,
                    width = text_width,
                    alignment = "center",
                    fgcolor = title_text_color,
                    bgcolor = title_background_color,
                }
                texts_height = texts_height + title_wg:getSize().h
            end

            free_height = height - texts_height
            if series then
                inter_pad_1 = math.floor(free_height * 0.5)
            else
                inter_pad_1 = math.floor(free_height * 0.2)
            end
            inter_pad_2 = free_height - inter_pad_1

            textboxes_ok = true
            if (authors_wg and authors_wg.has_split_inside_word) or
                (title_wg and title_wg.has_split_inside_word)  or
                (series_wg and series_wg.has_split_inside_word) then
                -- We may get a nicer cover at next lower font size
                textboxes_ok = false
            end

            if textboxes_ok and free_height > 0.2 * height then -- enough free space to not look constrained
                break
            end
            -- (We may store the first widgets matching free space requirements but
            -- not textboxes_ok, so that if we never ever get textboxes_ok candidate,
            -- we can use them instead of the super-small strings-modified we'll have
            -- at the end that are worse than the firsts)

            sizedec = sizedec + self.sizedec_step
            if sizedec > 16 then -- break out of loop when too small
                -- but try a 2nd loop with some cleanup to strings (for filenames
                -- with no space but hyphen or underscore instead)
                if not loop2 then
                    loop2 = true
                    sizedec = self.initial_sizedec -- restart from initial big size
                    if G_reader_settings:nilOrTrue("use_xtext") then
                        -- With Unicode/libunibreak, a break after a hyphen is allowed,
                        -- but not around underscores and dots without any space around.
                        -- So, append a zero-width-space to allow text wrap after them.
                        if title then
                            title = title:gsub("_", "_\u{200B}"):gsub("%.", ".\u{200B}")
                        end
                        if authors then
                            authors = authors:gsub("_", "_\u{200B}"):gsub("%.", ".\u{200B}")
                        end
                        if series then
                            series = series:gsub("_", "_\u{200B}"):gsub("%.", ".\u{200B}")
                        end
                    else
                        -- Replace underscores and hyphens with spaces, to allow text wrap there.
                        if title then
                            title = title:gsub("-", " "):gsub("_", " ")
                        end
                        if authors then
                            authors = authors:gsub("-", " "):gsub("_", " ")
                        end
                        if series then
                            series = series:gsub("-", " "):gsub("_", " ")
                        end
                    end
                else -- 2nd loop done, no luck, give up
                    break
                end
            end
        end
    else -- pathchooser gets a plain style
        title = BD.filename(self.filename)
        filesize = self.filename_add
        local textboxes_ok
        local free_height
        local sizedec = 1
        self.background = Blitbuffer.COLOR_WHITE
        self.radius = Screen:scaleBySize(10)
        self.bordersize = Size.border.default
        self.padding = Screen:scaleBySize(5)
        width = self.width - 2 * (self.bordersize + self.margin + self.padding)
        height = self.height - 2 * (self.bordersize + self.margin + self.padding)
        local text_width = width - (Size.padding.small * 2)
        while true do
            if title_wg then
                title_wg:free(true)
                title_wg = nil
            end
            title_wg = TextBoxWidget:new {
                text = title,
                face = Font:getFace("cfont", math.max(20 - sizedec, 10)),
                bold = false,
                width = text_width,
                alignment = "center",
                fgcolor = Blitbuffer.COLOR_BLACK,
                bgcolor = Blitbuffer.COLOR_WHITE,
            }
            free_height = height - title_wg:getSize().h
            textboxes_ok = true
            if (title_wg and title_wg.has_split_inside_word) then
                -- We may get a nicer cover at next lower font size
                textboxes_ok = false
            end
            if textboxes_ok and free_height > 0.2 * height then -- enough free space to not look constrained
                break
            end
            sizedec = sizedec + 1
            if sizedec > 10 then break end
        end
        filesize_wg = TextBoxWidget:new {
            text = filesize,
            face = Font:getFace("infont", 15),
            bold = false,
            width = text_width,
            alignment = "center",
            fgcolor = Blitbuffer.COLOR_BLACK,
            bgcolor = Blitbuffer.COLOR_WHITE,
        }
        free_height = free_height - filesize_wg:getSize().h
        inter_pad_1 = Screen:scaleBySize(7)
        inter_pad_2 = free_height - inter_pad_1
    end

    local vgroup = VerticalGroup:new {}
    table.insert(vgroup, VerticalSpan:new { width = inter_pad_1 })
    if authors then
        table.insert(vgroup, authors_wg)
    end
    if title then
        table.insert(vgroup, FrameContainer:new {
            margin = 0,
            padding = 0,
            padding_left = Size.padding.small,
            padding_right = Size.padding.small,
            bordersize = 0,
            background = title_background_color,
            title_wg
        })
    end
    if series then
        table.insert(vgroup, series_wg)
    end
    table.insert(vgroup, VerticalSpan:new { width = inter_pad_2 })
    if filesize then
        table.insert(vgroup, filesize_wg)
    end

    if self.file_deleted then
        self.dim = true
        self.color = Blitbuffer.COLOR_DARK_GRAY
    end

    -- As we are a FrameContainer, a border will be painted around self[1]
    self[1] = CenterContainer:new {
        dimen = Geom:new {
            w = width,
            h = height,
        },
        vgroup,
    }
end

-- Based on menu.lua's MenuItem
local MosaicMenuItem = InputContainer:extend {
    entry = nil, -- table, mandatory
    text = nil,
    show_parent = nil,
    dimen = nil,
    _underline_container = nil,
    do_cover_image = false,
    do_hint_opened = false,
    been_opened = false,
    init_done = false,
    bookinfo_found = false,
    cover_specs = nil,
    has_description = false,
    pages = nil,
}

function MosaicMenuItem:init()
    -- filepath may be provided as 'file' (history) or 'path' (filechooser)
    -- store it as attribute so we can use it elsewhere
    self.filepath = self.entry.file or self.entry.path

    self.percent_finished = nil
    self.status = nil

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
    self._underline_container = UnderlineContainer:new {
        vertical_align = "top",
        bordersize = 0,
        padding = 0,
        margin = 0,
        linesize = Screen:scaleBySize(3),
        background = Blitbuffer.COLOR_WHITE,
        -- widget : will be filled in self:update()
    }
    self[1] = self._underline_container

    -- Remaining part of initialization is done in update(), because we may
    -- have to do it more than once if item not found in db
    self:update()
    self.init_done = true
end

function MosaicMenuItem:update()
    -- We will be a disctinctive widget whether we are a directory,
    -- a known file with image / without image, or a not yet known file
    local widget

    local dimen = Geom:new {
        w = self.width,
        h = self.height,
    }

    -- Set up thin border for around all types of cover images
    local border_size = Size.border.thin
    local max_img_w = dimen.w - 2 * border_size
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

    -- test to see what style to draw (pathchooser vs one of our fancy modes)
    is_pathchooser = ptutil.isPathChooser(self)

    self.is_directory = not (self.entry.is_file or self.entry.file)
    if self.is_directory then
        local directory_string = self.text
        if directory_string:match('/$') then
            directory_string = directory_string:sub(1, -2)
        end
        directory_string = BD.directory(directory_string)
        local nbitems_string = self.mandatory or ""
        if nbitems_string:match('^☆ ') then
            nbitems_string = nbitems_string:sub(5)
        end
        if is_pathchooser == false then
            local subfolder_cover_image
            -- check for folder image
            subfolder_cover_image = ptutil.getFolderCover(self.filepath, dimen.w, dimen.h)
            -- check for books with covers in the subfolder
            if subfolder_cover_image == nil and not BookInfoManager:getSetting("disable_auto_foldercovers") then
                subfolder_cover_image = ptutil.getSubfolderCoverImages(self.filepath, max_img_w, max_img_h)
            end
            -- use stock folder icon
            if subfolder_cover_image == nil then
                local stock_image = plugin_dir .. "/resources/folder.svg"
                local _, _, scale_factor = BookInfoManager.getCachedCoverSize(250, 500, max_img_w * 1.1, max_img_h * 1.1)
                subfolder_cover_image = FrameContainer:new {
                    width = dimen.w,
                    height = dimen.h,
                    margin = 0,
                    padding = 0,
                    color = Blitbuffer.COLOR_WHITE,
                    bordersize = 0,
                    dim = self.file_deleted,
                    ImageWidget:new({
                        file = stock_image,
                        alpha = true,
                        scale_factor = scale_factor,
                        width = max_img_w,
                        height = max_img_h,
                        original_in_nightmode = false,
                    }),
                }
            end

            -- build final widget with whatever we assembled from above
            local directory_text
            local function build_directory_text(font_size, height, baseline)
                directory_text = TextWidget:new {
                    text = " " .. directory_string .. " ",
                    face = Font:getFace(ptutil.good_serif, font_size),
                    max_width = dimen.w,
                    alignment = "center",
                    padding = 0,
                    forced_height = height,
                    forced_baseline = baseline,
                }
            end
            local dirtext_font_size = 22
            build_directory_text(dirtext_font_size)
            local directory_text_height = directory_text:getSize().h
            local directory_text_baseline = directory_text:getBaseline()
            while dirtext_font_size >= 18 do
                if directory_text:isTruncated() then
                    dirtext_font_size = dirtext_font_size - 1
                    build_directory_text(dirtext_font_size, directory_text_height, directory_text_baseline)
                else
                    break
                end
            end
            local directory_frame = UnderlineContainer:new {
                linesize = Screen:scaleBySize(1),
                color = Blitbuffer.COLOR_BLACK,
                bordersize = 0,
                padding = 0,
                margin = 0,
                HorizontalGroup:new {
                    directory_text,
                    LineWidget:new {
                        dimen = Geom:new { w = Screen:scaleBySize(1), h = directory_text:getSize().h, },
                        background = Blitbuffer.COLOR_BLACK,
                    },
                },
            }
            local directory = AlphaContainer:new {
                alpha = alpha_level,
                directory_frame,
            }

            -- use non-alpha styling when focus indicator is involved
            if not Device:isTouchDevice() or BookInfoManager:getSetting("force_focus_indicator") then
                directory = FrameContainer:new {
                    bordersize = 0,
                    padding = 0,
                    margin = 0,
                    background = Blitbuffer.COLOR_WHITE,
                    directory_frame,
                }
            end

            local nbitems_text = TextWidget:new {
                text = " " .. nbitems_string .. " ",
                face = Font:getFace("infont", 15),
                max_width = dimen.w,
                alignment = "center",
                padding = Size.padding.tiny,
            }
            local nbitems_frame = UnderlineContainer:new {
                linesize = Screen:scaleBySize(1),
                color = Blitbuffer.COLOR_BLACK,
                bordersize = 0,
                padding = 0,
                margin = 0,
                HorizontalGroup:new {
                    nbitems_text,
                    LineWidget:new {
                        dimen = Geom:new { w = Screen:scaleBySize(1), h = directory_text:getSize().h, },
                        background = Blitbuffer.COLOR_BLACK,
                    },
                },
            }
            local nbitems_frame_container = AlphaContainer:new {
                alpha = alpha_level,
                nbitems_frame,
            }

            -- use non-alpha styling when focus indicator is involved
            if not Device:isTouchDevice() or BookInfoManager:getSetting("force_focus_indicator") then
                nbitems_frame_container = FrameContainer:new {
                    bordersize = 0,
                    padding = 0,
                    margin = 0,
                    background = Blitbuffer.COLOR_WHITE,
                    nbitems_frame,
                }
            end

            local nbitems = HorizontalGroup:new {
                dimen = dimen,
                HorizontalSpan:new {
                    width = dimen.w - nbitems_frame:getSize().w - Size.padding.small
                },
                nbitems_frame_container
            }

            local widget_parts = OverlapGroup:new {
                dimen = dimen,
                CenterContainer:new { dimen = dimen, subfolder_cover_image },
            }
            if BookInfoManager:getSetting("show_name_grid_folders") then
                table.insert(widget_parts, TopContainer:new { dimen = dimen, directory })
                table.insert(widget_parts, BottomContainer:new { dimen = dimen, nbitems })
            end
            widget = FrameContainer:new {
                width = dimen.w,
                height = dimen.h,
                margin = 0,
                padding = 0,
                bordersize = 0,
                radius = nil,
                widget_parts,
            }
        else -- pathchooser gets a plain style
            local margin = Screen:scaleBySize(5) -- make directories less wide
            local padding = Screen:scaleBySize(5)
            border_size = Size.border.thick      -- make directories' borders larger
            local dimen_in = Geom:new {
                w = dimen.w - (margin + padding + border_size) * 2,
                h = dimen.h - (margin + padding + border_size) * 2
            }
            local nbitems = TextBoxWidget:new {
                text = nbitems_string,
                face = Font:getFace("infont", 15),
                width = dimen_in.w,
                alignment = "center",
            }
            local available_height = dimen_in.h - 3 * nbitems:getSize().h
            local dir_font_size = 20
            local directory
            while true do
                if directory then
                    directory:free(true)
                end
                directory = TextBoxWidget:new {
                    text = directory_string,
                    face = Font:getFace("cfont", dir_font_size),
                    width = dimen_in.w,
                    alignment = "center",
                    bold = true,
                }
                if directory:getSize().h <= available_height then
                    break
                end
                dir_font_size = dir_font_size - 1
                if dir_font_size < 10 then -- don't go too low
                    directory:free()
                    directory.height = available_height
                    directory.height_adjust = true
                    directory.height_overflow_show_ellipsis = true
                    directory:init()
                    break
                end
            end
            widget = FrameContainer:new {
                width = dimen.w,
                height = dimen.h,
                margin = margin,
                padding = padding,
                bordersize = border_size,
                radius = Screen:scaleBySize(10),
                OverlapGroup:new {
                    dimen = dimen_in,
                    TopContainer:new { dimen = dimen_in, directory },
                    BottomContainer:new { dimen = dimen_in, nbitems },
                },
            }
        end
    else  -- file
        self.file_deleted = self.entry.dim -- entry with deleted file from History or selected file from FM

        if self.do_hint_opened and DocSettings:hasSidecarFile(self.filepath) then
            self.been_opened = true
        end

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
        if bookinfo and is_pathchooser == false then -- This book is known
            -- Current page / pages are available or more accurate in .sdr/metadata.lua
            -- We use a cache (cleaned at end of this browsing session) to store
            -- page, percent read and book status from sidecar files, to avoid
            -- re-parsing them when re-rendering a visited page
            -- This cache is shared with ListMenu, so we need to fill it with the same
            -- info here than there, even if we don't need them all here.
            if not self.menu.cover_info_cache then
                self.menu.cover_info_cache = {}
            end

            local percent_finished = book_info.percent_finished
            self.percent_finished = percent_finished
            local status = book_info.status
            self.status = status
            self.pages, self.show_progress_bar = ptutil.showProgressBarGrid(bookinfo.pages)
            local cover_bb_used = false
            self.bookinfo_found = true
            -- For wikipedia saved as epub, we made a cover from the 1st pic of the page,
            -- which may not say much about the book. So, here, pretend we don't have
            -- a cover
            if bookinfo.authors and bookinfo.authors:match("^Wikipedia ") then
                bookinfo.has_cover = nil
            end
            if self.do_cover_image and bookinfo.has_cover and not bookinfo.ignore_cover then
                cover_bb_used = true
                -- Let ImageWidget do the scaling and give us a bb that fit
                local frame_radius = 0
                if self.show_progress_bar then
                    frame_radius = Size.radius.default
                end
                local border_total = Size.border.thin * 2
                local _, _, scale_factor = BookInfoManager.getCachedCoverSize(bookinfo.cover_w, bookinfo.cover_h,
                    max_img_w - border_total, max_img_h - border_total)
                local image = ImageWidget:new {
                    image = bookinfo.cover_bb,
                    scale_factor = scale_factor,
                }
                widget = CenterContainer:new {
                    dimen = dimen,
                    FrameContainer:new {
                        width = math.floor((bookinfo.cover_w * scale_factor) + border_total),
                        height = math.floor((bookinfo.cover_h * scale_factor) + border_total),
                        margin = 0,
                        padding = 0,
                        radius = frame_radius,
                        bordersize = Size.border.thin,
                        dim = self.file_deleted,
                        color = Blitbuffer.COLOR_GRAY_3,
                        image,
                    }
                }
                -- Let menu know it has some item with images
                self.menu._has_cover_images = true
                self._has_cover_image = true
            else
                -- add Series metadata if requested
                local title_add, authors_add
                if bookinfo.series and bookinfo.series_index and bookinfo.series_index ~= 0 then -- suppress series if index is "0"
                    authors_add = BD.auto(bookinfo.series)
                    bookinfo.series = "#" .. bookinfo.series_index .. " – " .. BD.auto(bookinfo.series)
                end
                local bottom_pad = Size.padding.default
                if self.show_progress_bar and self.do_hint_opened then
                    bottom_pad = corner_mark_size + Screen:scaleBySize(2)
                elseif self.show_progress_bar then
                    bottom_pad = corner_mark_size - Screen:scaleBySize(2)
                end
                widget = CenterContainer:new {
                    dimen = dimen,
                    FakeCover:new {
                        -- reduced width to make it look less squared, more like a book
                        width = math.floor(dimen.w * 0.8),
                        height = dimen.h,
                        bordersize = border_size,
                        filename = self.text,
                        title = not bookinfo.ignore_meta and bookinfo.title,
                        authors = not bookinfo.ignore_meta and bookinfo.authors,
                        title_add = not bookinfo.ignore_meta and title_add,
                        authors_add = not bookinfo.ignore_meta and authors_add,
                        book_lang = not bookinfo.ignore_meta and bookinfo.language,
                        file_deleted = self.file_deleted,
                        bottom_pad = bottom_pad,
                        bottom_right_compensate = not self.show_progress_bar and self.do_hint_opened,
                    }
                }
            end
            -- In case we got a blitbuffer and didnt use it (ignore_cover, wikipedia), free it
            if bookinfo.cover_bb and not cover_bb_used then
                bookinfo.cover_bb:free()
            end
            -- So we can draw an indicator if this book has a description
            if bookinfo.description then
                self.has_description = true
            end
        elseif is_pathchooser == false then -- bookinfo not found
            if self.init_done then
                -- Non-initial update(), but our widget is still not found:
                -- it does not need to change, so avoid making the same FakeCover
                return
            end
            -- If we're in no image mode, don't save images in DB : people
            -- who don't care about images will have a smaller DB, but
            -- a new extraction will have to be made when one switch to image mode
            if self.do_cover_image then
                -- Not in db, we're going to fetch some cover
                self.cover_specs = cover_specs
            end
            -- Same as real FakeCover, but let it be squared (like a file)
            local hint = "…" -- display hint it's being loaded
            if self.file_deleted then -- unless file was deleted (can happen with History)
                hint = _("(deleted)")
            end
            widget = CenterContainer:new {
                dimen = dimen,
                FakeCover:new {
                    width = dimen.w,
                    height = dimen.h,
                    bordersize = border_size,
                    filename = self.text,
                    filename_add = "\n" .. hint,
                    initial_sizedec = 4, -- start with a smaller font when filenames only
                    file_deleted = self.file_deleted,
                }
            }
        else -- we're in pathchooser mode
            local filesize = self.mandatory or ""
            widget = CenterContainer:new {
                dimen = dimen,
                FakeCover:new {
                    width = dimen.w,
                    height = dimen.h,
                    bordersize = border_size,
                    filename = self.text,
                    filename_add = "\n" .. filesize,
                    initial_sizedec = 4, -- start with a smaller font when filenames only
                    file_deleted = self.file_deleted,
                }
            }
        end
    end

    -- Fill container with our widget
    if self._underline_container[1] then
        -- There is a previous one, that we need to free()
        local previous_widget = self._underline_container[1]
        previous_widget:free()
    end
    self._underline_container[1] = widget
end

function MosaicMenuItem:paintTo(bb, x, y)
    -- We used to get non-integer x or y that would cause some mess with image
    -- inside FrameContainer were image would be drawn on top of the top border...
    -- Fixed by having TextWidget:updateSize() math.ceil()'ing its length and height
    -- But let us know if that happens again
    if x ~= math.floor(x) or y ~= math.floor(y) then
        logger.err(ptdbg.logprefix, "MosaicMenuItem:paintTo() got non-integer x/y :", x, y)
    end

    -- Original painting
    InputContainer.paintTo(self, bb, x, y)

    -- No further painting is required over directories
    self.is_directory = not (self.entry.is_file or self.entry.file)
    if self.is_directory then return end

    -- other paintings are anchored to the sub-widget (cover image)
    local target = self[1][1][1]

    if self.do_hint_opened and self.been_opened and is_pathchooser == false then
        if self.status == "complete" and not self.show_progress_bar then
            corner_mark = complete_mark
            local corner_mark_margin = math.floor((corner_mark_size - corner_mark:getSize().h) / 2)
            local ix = x
            local iy = y + self.height - math.ceil((self.height - target.height) / 2) - corner_mark_size + corner_mark_margin - (corner_mark:getSize().h / 3)
            corner_mark:paintTo(bb, ix, iy)
        elseif self.status == "abandoned" and not self.show_progress_bar then
            corner_mark = abandoned_mark
            local corner_mark_margin = math.floor((corner_mark_size - corner_mark:getSize().h) / 2)
            local ix = x
            local iy = y + self.height - math.ceil((self.height - target.height) / 2) - corner_mark_size + corner_mark_margin - (corner_mark:getSize().h / 3)
            corner_mark:paintTo(bb, ix, iy)
        end
    end

    local bookinfo = BookInfoManager:getBookInfo(self.filepath, false)
    if bookinfo and self.init_done then
        local series_mode = BookInfoManager:getSetting("series_mode")
        -- suppress showing series if index is "0"
        local show_series = bookinfo.series and bookinfo.series_index and bookinfo.series_index ~= 0
        if series_mode == "series_in_separate_line" and show_series and is_pathchooser == false then
            local series_index = " " .. bookinfo.series_index .. " "
            if string.len(series_index) == 3 then series_index = " " .. series_index .. " " end
            local series_widget_radius = 0
            local series_widget_background = Blitbuffer.COLOR_WHITE
            local xmult = 0.80
            if self.show_progress_bar then
                -- xmult = 1.25
                series_widget_radius = Size.radius.default
                -- series_widget_background = Blitbuffer.COLOR_GRAY_E
            end
            local series_widget_text = TextWidget:new {
                text = series_index,
                face = Font:getFace(ptutil.good_serif, 14),
                alignment = "left",
                padding = 0,
            }
            local series_widget = FrameContainer:new {
                linesize = Screen:scaleBySize(1),
                radius = series_widget_radius,
                color = Blitbuffer.COLOR_BLACK,
                bordersize = Size.line.thin,
                background = series_widget_background,
                padding = 0,
                margin = 0,
                series_widget_text,
            }
            local pos_x = x + self.width / 2 + target.width / 2 - series_widget:getSize().w * xmult
            local pos_y = y + series_widget:getSize().w * 0.33
            series_widget:paintTo(bb, pos_x, pos_y)
        end

        if self.show_progress_bar and is_pathchooser == false then
            local progress_widget_width_mult = 1.0
            local est_page_count = self.pages or nil
            local large_book = false
            if est_page_count then
                local fn_pages = tonumber(est_page_count)
                local max_progress_size = 235
                local pixels_per_page = 3
                local min_progress_size = 40
                local total_pixels = math.max(
                (math.min(math.floor((fn_pages / pixels_per_page) + 0.5), max_progress_size)), min_progress_size)
                progress_widget_width_mult = total_pixels / max_progress_size
                if fn_pages > (max_progress_size * pixels_per_page) then large_book = true end
            end
            local progress_widget_margin = math.floor((corner_mark_size - progress_widget.height) / 4)
            progress_widget.width = self.width * progress_widget_width_mult
            local percent_done = self.percent_finished or 0
            progress_widget:setPercentage(percent_done)
            if self.status == "complete" then progress_widget:setPercentage(1) end
            local pos_x = x
            local pos_y = y + self.height - math.ceil((self.height - target.height) / 2) - corner_mark_size +
            progress_widget_margin
            progress_widget:paintTo(bb, pos_x, pos_y)
            local status_widget = nil
            local status_icon_size = Screen:scaleBySize(17)
            if self.status == "complete" then
                status_widget = FrameContainer:new {
                    radius = Size.radius.default,
                    bordersize = Size.border.thin,
                    padding = Size.padding.small,
                    margin = 0,
                    background = Blitbuffer.COLOR_WHITE,
                    ImageWidget:new {
                        file = plugin_dir .. "/resources/trophy.svg",
                        alpha = true,
                        width = status_icon_size - (Size.border.thin * 2) - Size.padding.small,
                        height = status_icon_size - (Size.border.thin * 2) - Size.padding.small,
                        scale_factor = 0,
                        original_in_nightmode = false,
                    }
                }
            elseif self.status == "abandoned" then
                status_widget = FrameContainer:new {
                    radius = Size.radius.default,
                    bordersize = Size.border.thin,
                    padding = Size.padding.small,
                    margin = 0,
                    background = Blitbuffer.COLOR_WHITE,
                    ImageWidget:new {
                        file = plugin_dir .. "/resources/pause.svg",
                        alpha = true,
                        width = status_icon_size - (Size.border.thin * 2) - Size.padding.small,
                        height = status_icon_size - (Size.border.thin * 2) - Size.padding.small,
                        scale_factor = 0,
                        original_in_nightmode = false,
                    }
                }
            elseif not bookinfo._no_provider and percent_done == 0 then
                local unopened_widget = ImageWidget:new {
                    file = plugin_dir .. "/resources/new.svg",
                    alpha = true,
                    width = Screen:scaleBySize(8),
                    height = Screen:scaleBySize(8),
                    scale_factor = 0,
                    original_in_nightmode = false,
                }
                unopened_widget:paintTo(bb,
                    (pos_x + (progress_widget:getSize().w - (unopened_widget:getSize().w * 0.625))),
                    (pos_y - ((progress_widget:getSize().h / 2) - (unopened_widget:getSize().w * 0.50)))
                )
            end
            if status_widget ~= nil then
                local inset_mult = 1.25
                if (progress_widget:getSize().w / status_widget:getSize().w) < 2 then inset_mult = 0.1 end
                status_widget:paintTo(bb,
                    (pos_x + progress_widget:getSize().w - (status_widget:getSize().w * inset_mult)),
                    (pos_y - progress_widget:getSize().h / 2)
                )
            end
            if large_book then
                local large_book_icon_size = Screen:scaleBySize(19)
                local max_widget = ImageWidget:new({
                    file = plugin_dir .. "/resources/large_book.svg",
                    width = large_book_icon_size,
                    height = large_book_icon_size,
                    scale_factor = 0,
                    alpha = true,
                    original_in_nightmode = false,
                })
                max_widget:paintTo(bb,
                    (pos_x - large_book_icon_size / 2),
                    (pos_y - progress_widget:getSize().h / 3)
                )
            end
        elseif is_pathchooser == false then
            local progresstxt = nil
            if not BookInfoManager:getSetting("hide_file_info") then
                progresstxt = (" " .. self.mandatory .. " ") or " ??? "
            elseif self.status ~= "complete" and self.status ~= "abandoned" and self.percent_finished ~= nil then
                progresstxt = " " .. math.floor(100 * self.percent_finished) .. "% "
                if BookInfoManager:getSetting("show_pages_read_as_progress") then
                    local book_info = self.menu.getBookInfo(self.filepath)
                    local pages = book_info.pages or bookinfo.pages or nil -- default to those in bookinfo db
                    if pages ~= nil then
                        progresstxt = T(("%1/%2 "), Math.round(self.percent_finished * pages), pages)
                    end
                end
            end
            if progresstxt ~= nil then
                local txtprogress_widget_text = TextWidget:new {
                    text = progresstxt,
                    face = Font:getFace(ptutil.good_sans, 15),
                    alignment = "center",
                    padding = Size.padding.tiny,
                }
                local txtprogress_padding = math.max(0, ((self.width * tag_width) - txtprogress_widget_text:getSize().w))
                local txtprogress_widget_frame = UnderlineContainer:new {
                    linesize = Screen:scaleBySize(1),
                    color = Blitbuffer.COLOR_BLACK,
                    bordersize = 0,
                    padding = 0,
                    margin = 0,
                    HorizontalGroup:new {
                        HorizontalSpan:new { width = txtprogress_padding },
                        txtprogress_widget_text,
                        LineWidget:new {
                            dimen = Geom:new { w = Screen:scaleBySize(1), h = txtprogress_widget_text:getSize().h, },
                            background = Blitbuffer.COLOR_BLACK,
                        },
                    }
                }
                local txtprogress_widget = AlphaContainer:new {
                    alpha = 1.0,
                    txtprogress_widget_frame,
                }
                local progress_widget_margin = math.floor((corner_mark_size - txtprogress_widget:getSize().h) / 2)
                local pos_x = x
                local pos_y = y + self.height - math.ceil((self.height - target.height) / 2) - corner_mark_size +
                    progress_widget_margin - (txtprogress_widget:getSize().h / 3)
                txtprogress_widget:paintTo(bb, pos_x, pos_y)
            end
        end
    end
end

-- As done in MenuItem
function MosaicMenuItem:onFocus()
    ptutil.onFocus(self._underline_container)
    return true
end

function MosaicMenuItem:onUnfocus()
    ptutil.onUnfocus(self._underline_container)
    return true
end

-- The transient color inversions done in MenuItem:onTapSelect
-- and MenuItem:onHoldSelect are ugly when done on an image,
-- so let's not do it
-- Also, no need for 2nd arg 'pos' (only used in readertoc.lua)
function MosaicMenuItem:onTapSelect(arg)
    self.menu:onMenuSelect(self.entry)
    return true
end

function MosaicMenuItem:onHoldSelect(arg, ges)
    self.menu:onMenuHold(self.entry)
    return true
end

-- Simple holder of methods that will replace those
-- in the real Menu class or instance
local MosaicMenu = {}

function MosaicMenu:_recalculateDimen()
    self.portrait_mode = Screen:getWidth() <= Screen:getHeight()
    if self.portrait_mode then
        self.nb_cols = self.nb_cols_portrait
        self.nb_rows = self.nb_rows_portrait
    else
        self.nb_cols = self.nb_cols_landscape
        self.nb_rows = self.nb_rows_landscape
    end
    self.perpage = self.nb_rows * self.nb_cols
    self.page_num = math.ceil(#self.item_table / self.perpage)
    -- fix current page if out of range
    if self.page_num > 0 and self.page > self.page_num then self.page = self.page_num end

    -- test to see what style to draw (pathchooser vs one of our fancy modes)
    is_pathchooser = ptutil.isPathChooser(self)

    -- Find out available height from other UI elements made in Menu
    self.others_height = 0
    if self.title_bar then -- init() has been done
        if not self.is_borderless then
            self.others_height = self.others_height + 2
        end
        if not self.no_title then
            self.others_height = self.others_height + self.title_bar.dimen.h
        end
        if self.page_info then
            self.others_height = self.others_height + self.page_info:getSize().h
        end
    end

    self.item_margin = Screen:scaleBySize(margin_size)
    -- in meta mode, an extra line and margins are drawn between bottom row and footer to indicate read status
    local additional_padding = 0
    if self.meta_show_opened ~= nil then additional_padding = 1 end
    self.others_height = self.others_height + ((self.nb_rows + additional_padding) * Size.line.thin) -- lines between rows
    self.others_height = self.others_height + ((self.nb_rows + additional_padding) * self.item_margin) -- margins between rows

    -- Set our items target size
    self.item_height = math.floor(
        (self.inner_dimen.h - self.others_height)
        / self.nb_rows)
    self.item_width = math.floor(
        (self.inner_dimen.w - ((self.nb_cols + 1) * self.item_margin))
        / self.nb_cols)
    self.item_dimen = Geom:new {
        x = 0, y = 0,
        w = self.item_width,
        h = self.item_height
    }

    -- Create or replace corner_mark
    local mark_image_size = 21
    if self.show_progress_bar then
        mark_image_size = mark_image_size - (Size.border.thin * 2) - Size.padding.small
    else
        mark_image_size = mark_image_size - Size.padding.tiny
    end
    corner_mark_size = Screen:scaleBySize(mark_image_size)

    if corner_mark then
        complete_mark:free()
        abandoned_mark:free()
    end
    local complete_mark_image = FrameContainer:new {
        bordersize = 0,
        padding = Size.padding.small,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        ImageWidget:new {
            file = plugin_dir .. "/resources/trophy.svg",
            alpha = true,
            width = corner_mark_size,
            height = corner_mark_size,
            scale_factor = 0,
            original_in_nightmode = false,
        }
    }
    local complete_mark_frame = UnderlineContainer:new {
        linesize = Screen:scaleBySize(1),
        color = Blitbuffer.COLOR_BLACK,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        HorizontalGroup:new {
            HorizontalSpan:new { width = ((self.item_width * tag_width) - complete_mark_image:getSize().w) },
            complete_mark_image,
            LineWidget:new {
                dimen = Geom:new { w = Screen:scaleBySize(1), h = complete_mark_image:getSize().h, },
                background = Blitbuffer.COLOR_BLACK,
            },
        }
    }
    complete_mark = AlphaContainer:new {
        alpha = 1.0,
        complete_mark_frame,
    }

    local abandoned_mark_image = FrameContainer:new {
        bordersize = 0,
        padding = Size.padding.small,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        ImageWidget:new {
            file = plugin_dir .. "/resources/pause.svg",
            alpha = true,
            width = corner_mark_size,
            height = corner_mark_size,
            scale_factor = 0,
            original_in_nightmode = false,
        }
    }
    local abandoned_mark_frame = UnderlineContainer:new {
        linesize = Screen:scaleBySize(1),
        color = Blitbuffer.COLOR_BLACK,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        HorizontalGroup:new {
            HorizontalSpan:new { width = ((self.item_width * tag_width) - abandoned_mark_image:getSize().w) },
            abandoned_mark_image,
            LineWidget:new {
                dimen = Geom:new { w = Screen:scaleBySize(1), h = abandoned_mark_image:getSize().h, },
                background = Blitbuffer.COLOR_BLACK,
            },
        }
    }
    abandoned_mark = AlphaContainer:new {
        alpha = 1.0,
        abandoned_mark_frame,
    }

    -- Create progress_widget
    if not progress_widget then
        progress_widget = ProgressWidget:new {
            width = self.item_width,
            height = Screen:scaleBySize(11),
            margin_v = 0,
            margin_h = 0,
            bordersize = Screen:scaleBySize(0.5),
            bordercolor = Blitbuffer.COLOR_BLACK,
            bgcolor = Blitbuffer.COLOR_GRAY_E,
            fillcolor = Blitbuffer.COLOR_GRAY_6,
        }
    end
end

function MosaicMenu:_updateItemsBuildUI()
    -- Build our grid
    local grid_timer = ptdbg:new()
    local line_width = self.width or self.screen_w
    local half_margin_size = margin_size / 2
    table.insert(self.item_group, ptutil.mediumBlackLine(line_width))
    table.insert(self.item_group, VerticalSpan:new { width = Screen:scaleBySize(half_margin_size) })
    local cur_row = nil
    local idx_offset = (self.page - 1) * self.perpage
    local items_on_current_page = math.min(self.perpage, math.max(0, #self.item_table - idx_offset))
    local last_index  = idx_offset + items_on_current_page
    local line_layout = {}
    local select_number
    if self.recent_boundary_index == nil then self.recent_boundary_index = 0 end
    for idx = 1, self.perpage do
        local itm_timer = ptdbg:new()
        local index = idx_offset + idx
        local entry = self.item_table[index]
        if entry == nil then break end
        entry.idx = index
        if index == self.itemnumber then -- focused item
            select_number = idx
        end
        if idx % self.nb_cols == 1 then -- new row
            if idx > 1 then table.insert(self.layout, line_layout) end
            line_layout = {}
            cur_row = HorizontalGroup:new {}
            -- Have items on the possibly non-fully filled last row aligned to the left
            local container = self._do_center_partial_rows and CenterContainer or LeftContainer
            table.insert(self.item_group, container:new {
                dimen = Geom:new {
                    w = self.inner_dimen.w,
                    h = self.item_height
                },
                cur_row
            })
            table.insert(cur_row, HorizontalSpan:new({ width = self.item_margin }))
        end
        local item_tmp = MosaicMenuItem:new {
            height = self.item_height,
            width = self.item_width,
            entry = entry,
            text = getMenuText(entry),
            show_parent = self.show_parent,
            mandatory = entry.mandatory,
            dimen = self.item_dimen:copy(),
            menu = self,
            do_cover_image = self._do_cover_images,
            do_hint_opened = self._do_hint_opened,
        }
        table.insert(cur_row, item_tmp)
        table.insert(cur_row, HorizontalSpan:new({ width = self.item_margin }))

        -- Recent items that are sorted to top of the library are underlined in black (using the row separator line)
        -- If the current row ends before the boundary → full black line. If boundary falls within the current
        -- row → gray baseline + black overlay over recent columns, otherwise → thin gray.
        -- Special case: last line gets a white (invisible) line instead of gray. Logic for black lines is unchanged.
        if idx % self.nb_cols == 1 then -- new row
            local row_start = index
            local row_end   = math.min(index + (self.nb_cols - 1), last_index)
            local is_last_row = (row_end == last_index)
            local draw_line = ((not is_last_row) or (is_last_row and self.meta_show_opened ~= nil))
            if draw_line then
                table.insert(self.item_group, VerticalSpan:new { width = Screen:scaleBySize(half_margin_size) })
            end
            local baseline = is_last_row and ptutil.thinWhiteLine or ptutil.thinGrayLine
            if self.recent_boundary_index > 0 then
                if row_end <= self.recent_boundary_index then
                    table.insert(self.item_group, ptutil.thinBlackLine(line_width))
                elseif row_start <= self.recent_boundary_index and row_end >= self.recent_boundary_index then
                    local pad = Screen:scaleBySize(10)
                    local inner_total = math.max(0, line_width - 2 * pad)
                    local dark_cols = math.max(0, math.min(self.nb_cols, self.recent_boundary_index - row_start + 1))
                    local dark_inner = math.floor(inner_total * (dark_cols / self.nb_cols))

                    table.insert(self.item_group, OverlapGroup:new {
                        dimen = Geom:new { w = line_width, h = Size.line.thin },
                        baseline(line_width),
                        LeftContainer:new {
                            dimen = Geom:new { w = (2 * pad) + dark_inner, h = Size.line.thin },
                            ptutil.thinBlackLine((2 * pad) + dark_inner),
                        },
                    })
                else
                    if draw_line then table.insert(self.item_group, baseline(line_width)) end
                end
            else
                if draw_line then table.insert(self.item_group, baseline(line_width)) end
            end
            if draw_line then
                table.insert(self.item_group, VerticalSpan:new { width = Screen:scaleBySize(half_margin_size) })
            end
        end
        -- this is for focus manager
        table.insert(line_layout, item_tmp)
        if not item_tmp.bookinfo_found and not item_tmp.is_directory and not item_tmp.file_deleted then
            -- Register this item for update
            table.insert(self.items_to_update, item_tmp)
        end
        itm_timer:report("Draw grid item " .. getMenuText(entry))
    end
    if self.meta_show_opened == nil then
        table.insert(self.item_group, VerticalSpan:new { width = Screen:scaleBySize(half_margin_size) })
    end
    table.insert(self.layout, line_layout)
    grid_timer:report("Draw cover grid page " .. self.perpage)
    return select_number
end

return MosaicMenu
