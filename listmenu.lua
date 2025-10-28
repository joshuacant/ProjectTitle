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
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local logger = require("logger")
local util = require("util")
local _ = require("l10n.gettext")
local Screen = Device.screen
local T = require("ffi/util").template
local getMenuText = require("ui/widget/menu").getMenuText
local BookInfoManager = require("bookinfomanager")
local ptutil = require("ptutil")
local ptdbg = require("ptdbg")

-- Here is the specific UI implementation for "list" display modes
-- (see covermenu.lua for the generic code)
local is_pathchooser = false
local plugin_dir = ptutil.getPluginDir()
local scale_by_size = Screen:scaleBySize(1000000) * (1 / 1000000)

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
    pages = nil,
}

function ListMenuItem:init()
    -- filepath may be provided as 'file' (history, collection) or 'path' (filechooser)
    -- store it as attribute so we can use it elsewhere
    self.filepath = self.entry.file or self.entry.path

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
        dimen = Geom:new {
            w = self.width,
            h = self.height
        },
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
        h = self.height,
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
    local fontsize_dec_step = 2 -- math.ceil(_fontSize(100) * (1 / 100))
    -- calculate font used in all right widget text
    local wright_font_size = _fontSize(12, 18)
    local wright_font_face = Font:getFace(ptutil.good_sans, wright_font_size)
    -- and font sizes used for title and author/series
    local title_font_size = _fontSize(20, 26)   -- 22
    local authors_font_size = _fontSize(14, 18) -- 16

    -- We'll draw some padding around cover images so they don't run up against
    -- other parts of the list item or decorations
    local padding_size = Screen:scaleBySize(4)
    local max_img_w = dimen.h - 2 * padding_size -- width = height, squared
    local max_img_h = dimen.h - 2 * padding_size
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
        -- nb items on the right, directory name on the left
        local wright
        local wright_width = 0
        local wright_items = { align = "right" }

        if is_pathchooser == false then
            -- replace the stock tiny file and folder glyphs with text
            local folder_text = _("Folder")
            local file_text = _("Book")
            local mandatory_str = self.mandatory or ""
            local folder_count = string.match(mandatory_str, "(%d+) \u{F114}")
            local file_count = string.match(mandatory_str, "(%d+) \u{F016}")
            wright_font_face = Font:getFace(ptutil.good_sans, _fontSize(15, 19))

            -- add file or folder counts as necessary with pluralization
            if folder_count and tonumber(folder_count) > 0 then
                if tonumber(folder_count) > 1 then folder_text =  _("Folders") end
                local wfoldercount = TextWidget:new {
                    text = folder_count .. " " .. folder_text,
                    face = wright_font_face,
                }
                table.insert(wright_items, wfoldercount)
            end
            if file_count and tonumber(file_count) > 0 then
                if tonumber(file_count) > 1 then file_text = _("Books") end
                local wfilecount = TextWidget:new {
                    text = file_count .. " " .. file_text,
                    face = wright_font_face,
                }
                table.insert(wright_items, wfilecount)
            end
        else
            local wmandatory = TextWidget:new {
                text = self.mandatory or "",
                face = wright_font_face,
            }
            table.insert(wright_items, wmandatory)
        end

        if #wright_items > 0 then
            for _, w in ipairs(wright_items) do
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
            subfolder_cover_image = ptutil.getFolderCover(self.filepath, max_img_w * 0.82, max_img_h)
            -- check for books with covers in the subfolder
            if subfolder_cover_image == nil and not BookInfoManager:getSetting("disable_auto_foldercovers") then
                subfolder_cover_image = ptutil.getSubfolderCoverImages(self.filepath, max_img_w, max_img_h)
            end
            -- use stock folder icon
            local stock_image = plugin_dir .. "/resources/folder.svg"
            if subfolder_cover_image == nil then
                local _, _, scale_factor = BookInfoManager.getCachedCoverSize(250, 500, max_img_w, max_img_h)
                subfolder_cover_image = ImageWidget:new {
                    file = stock_image,
                    alpha = true,
                    scale_factor = scale_factor,
                    width = max_img_w,
                    height = max_img_h,
                    original_in_nightmode = false,
                }
            end

            folder_cover = CenterContainer:new {
                dimen = Geom:new { w = dimen.h, h = dimen.h },
                margin = 0,
                padding = padding_size,
                color = Blitbuffer.COLOR_WHITE,
                dim = self.file_deleted,
                subfolder_cover_image,
            }
            self.menu._has_cover_images = true
            self._has_cover_image = true
        else
            local no_folder_width = 5
            -- extra padding in filename only mode, but not in pathchooser
            if self.do_filename_only then no_folder_width = 15 end
            folder_cover = HorizontalSpan:new { width = Screen:scaleBySize(no_folder_width) }
        end

        local wleft_width = dimen.w - dimen.h - wright_width - 3 * pad_width
        local wlefttext = self.text
        if wlefttext:match('/$') then
            wlefttext = wlefttext:sub(1, -2)
        end
        wlefttext = BD.directory(wlefttext)

        local folderfont = ptutil.good_serif
        -- style folder names differently in pathchooser
        if is_pathchooser or self.do_filename_only then
            wlefttext = BD.directory(self.text)
            folderfont = ptutil.good_sans
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

        -- extra right side padding in filename only mode
        if self.do_filename_only then pad_width = Screen:scaleBySize(20) end

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
                    local border_total = Size.border.thin * 2
                    local _, _, scale_factor = BookInfoManager.getCachedCoverSize(bookinfo.cover_w, bookinfo.cover_h,
                        max_img_w - border_total, max_img_h - border_total)
                    local wimage = ImageWidget:new {
                        image = bookinfo.cover_bb,
                        scale_factor = scale_factor,
                    }
                    wleft = CenterContainer:new {
                        dimen = Geom:new { w = wleft_width, h = wleft_height },
                        FrameContainer:new {
                            width = math.floor((bookinfo.cover_w * scale_factor) + border_total),
                            height = math.floor((bookinfo.cover_h * scale_factor) + border_total),
                            margin = 0,
                            padding = 0,
                            radius = Size.radius.default,
                            bordersize = Size.border.thin,
                            dim = self.file_deleted,
                            color = Blitbuffer.COLOR_GRAY_3,
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
                            file = plugin_dir .. "/resources/file-unsupported.svg",
                            alpha = true,
                            scale_factor = scale_factor,
                            original_in_nightmode = false,
                        })
                    else
                        wimage = ImageWidget:new({
                            file = plugin_dir .. "/resources/file.svg",
                            alpha = true,
                            scale_factor = scale_factor,
                            original_in_nightmode = false,
                        })
                    end
                    wleft = CenterContainer:new {
                        dimen = Geom:new { w = wleft_width, h = wleft_height },
                        FrameContainer:new {
                            width = math.floor((250 * scale_factor) + (2 * padding_size)),
                            height = math.floor((500 * scale_factor) + (2 * padding_size)),
                            margin = 0,
                            padding = padding_size,
                            bordersize = 0,
                            color = Blitbuffer.COLOR_WHITE,
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

            local finished_text = _("Finished")
            local abandoned_string = _("On hold")
            local read_text = _("Reading")
            local unread_text = _("New")
            local status_str = ""
            local pages_str = ""
            local pages_left_str = ""
            local percent_str = ""
            local progress_str = ""

            -- right widget, first line
            local status = book_info.status
            local directory, filename = util.splitFilePathName(self.filepath) -- luacheck: no unused
            local filename_without_suffix, filetype = filemanagerutil.splitFileNameType(filename)
            local fileinfo_str = self.mandatory or ""
            if bookinfo._no_provider then
                -- for unsupported files: don't show extension on the right,
                -- keep it in filename
                filename_without_suffix = filename
            end

            -- right widget, second line
            local percent_finished = book_info.percent_finished
            local wright_right_padding = 0
            local wright_width = 0
            local wright_height = 0
            local wright_items = { align = "right" }
            local est_page_count, draw_progressbar = ptutil.showProgressBar(bookinfo.pages)
            self.pages = est_page_count
            bookinfo.pages = est_page_count
            local pages = bookinfo.pages -- limit to value in database

            if draw_progressbar then
                local progressbar_items = { align = "center" }

                local fn_pages = BookInfoManager:getSetting("force_max_progressbars") and 700 or tonumber(est_page_count)
                local max_progress_size = 235
                local pixels_per_page = 3
                local min_progress_size = 25
                local progress_bar_height = wright_font_size -- progress bar same height as progress text
                local total_pixels = math.max(
                    (math.min(math.floor((fn_pages / pixels_per_page) + 0.5), max_progress_size)), min_progress_size)
                local progress_bar = ProgressWidget:new {
                    width = Screen:scaleBySize(total_pixels),
                    height = Screen:scaleBySize(progress_bar_height),
                    margin_v = 0,
                    margin_h = 0,
                    bordersize = Screen:scaleBySize(0.5),
                    bordercolor = Blitbuffer.COLOR_BLACK,
                    bgcolor = Blitbuffer.COLOR_GRAY_E,
                    fillcolor = Blitbuffer.COLOR_GRAY_8, -- changed to make sure percentage text is more visible
                    percentage = 0,
                }

                local progress_width = progress_bar:getSize().w
                local progress_dimen
                local bar_and_icons
                local bar_icon_size = Screen:scaleBySize(progress_bar_height * 1.5333)  -- size for icons used with progress bar

                if fn_pages > (max_progress_size * pixels_per_page) then
                    progress_width = progress_width + math.floor(bar_icon_size / 2) -- add extra width for max size indicator
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
                        file = plugin_dir .. "/resources/large_book.svg",
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

                if status == "complete" or status == "abandoned" then
                    -- books marked as "On Hold" get a little pause icon
                    -- books marked as "Finished" get a little trophy
                    filename = plugin_dir .. "/resources/pause.svg"
                    progress_bar.percentage = percent_finished or 0
                    if status == "complete" then
                        progress_bar.percentage = 1
                        filename = plugin_dir .. "/resources/trophy.svg"
                    end
                    local progress_statusicon_widget = ImageWidget:new({
                        file = filename,
                        width = bar_icon_size,
                        height = bar_icon_size,
                        scale_factor = 0,
                        alpha = true,
                        original_in_nightmode = false,
                    })
                    local right_padding = Size.padding.default
                    table.insert(progress_block, RightContainer:new {
                        dimen = progress_dimen,
                        HorizontalGroup:new {
                            progress_statusicon_widget,
                            HorizontalSpan:new { width = right_padding },
                        }
                    })
                    table.insert(progressbar_items, progress_block)
                elseif percent_finished then
                    progress_bar.percentage = percent_finished
                    table.insert(progressbar_items, progress_block)
                else
                    table.insert(progressbar_items, progress_block)
                end
                 -- Add percentage text to progress bar if drawing progress bar
                 -- Not showing for new (0%) or finished (100%) books
                if BookInfoManager:getSetting("list_show_percentage") and (status == "reading" or status == "abandoned") and percent_finished then
                    local progress_statuspercent_widget = TextWidget:new({
                        text = math.floor(100 * percent_finished) .. "%",
                        face = Font:getFace(ptutil.good_sans, _fontSize(10, 16)),
                        fgcolor = fgcolor,
                        padding = 0,
                    })
                    table.insert(progress_block, CenterContainer:new {
                        dimen = progress_dimen,
                        HorizontalGroup:new {
                            progress_statuspercent_widget,
                            HorizontalSpan:new { width = progress_statuspercent_widget._length}, -- adjust position by the width of the text itself
                        }
                    })
                end

                for _, w in ipairs(progressbar_items) do
                    wright_width = wright_width + w:getSize().w
                end
                local progress_block_height = progress_block:getSize().h
                local progress = RightContainer:new {
                    dimen = Geom:new { w = wright_width, h = progress_block_height },
                    HorizontalGroup:new(progressbar_items),
                }
                table.insert(wright_items, progress)
            else
                if status == "complete" or status == "abandoned" then
                    -- books marked as "On Hold" get a little pause icon
                    -- books marked as "Finished" get a little trophy
                    local bar_icon_size = Screen:scaleBySize(wright_font_size)
                    local bar_icon_padding = Size.padding.small
                    filename = plugin_dir .. "/resources/pause.svg"
                    if status == "complete" then
                        filename = plugin_dir .. "/resources/trophy.svg"
                    end
                    table.insert(wright_items, RightContainer:new {
                        dimen =  Geom:new {
                            x = 0, y = 0, w = bar_icon_size + bar_icon_padding, h = bar_icon_size,
                        },
                        HorizontalGroup:new {
                            ImageWidget:new({
                                file = filename,
                                width = bar_icon_size,
                                height = bar_icon_size,
                                scale_factor = 0,
                                alpha = true,
                                original_in_nightmode = false,
                            }),
                            HorizontalSpan:new { width = bar_icon_padding },
                        }
                    })
                end
            end

            -- Show status text (only for new)
            if status == "complete" then
                status_str = "" --finished_text
            elseif status == "abandoned" then
                status_str = "" --abandoned_string
            elseif status == "reading" then
                status_str = "" --read_text
            elseif not bookinfo._no_provider then
                status = "new"
                status_str = unread_text
            end

            -- Add percentage text when no bar present (onto status text)
            if BookInfoManager:getSetting("list_show_percentage") and (status == "reading" or status == "abandoned") and not draw_progressbar then
                status_str = math.floor(100 * percent_finished) .. "%"
            end

            
            -- Add pages text
            local pages_str_ending = " pages"
            local pages_left_str_ending = " pages left"
            if pages == 1 then
                pages_str_ending = " page"
            end
            if BookInfoManager:getSetting("list_show_pages") then
                if status == "complete" then
                    pages_str = tonumber(pages) .. pages_str_ending
                elseif status == "abandoned" and percent_finished then
                    local pages_left = Math.round(pages - percent_finished * pages)
                    if pages_left == 1 then
                        pages_left_str_ending = " page left"
                    end
                    pages_str = tostring(pages_left) .. pages_left_str_ending
                elseif status == "abandoned" and not percent_finished then
                    pages_str = " 1 pages left"    
                elseif status == "reading" and pages and percent_finished then
                    pages_str = T(_("Page %1 of %2"), Math.round(percent_finished * pages), pages)
                elseif not bookinfo._no_provider then
                    pages_str = tonumber(pages) .. pages_str_ending
                end

                -- Edge cases
                -- If book is on hold and no progress bar is shown
                -- put pages left and percentage on one line to avoid 4 lines
                if BookInfoManager:getSetting("list_show_percentage") and status == "abandoned" and not draw_progressbar then
                    pages_str = status_str .. " ⋅ " .. pages_str
                    status_str = "" -- clear string to avoid duplicate
                end
                -- If book is new and progress bar is shown
                -- put no of pages and status text on one line to avoid 4 lines
                if BookInfoManager:getSetting("list_show_percentage") and status == "new" and draw_progressbar then
                    pages_str = pages_str .. " ⋅ " .. status_str
                    status_str = "" -- clear string to avoid duplicate
                end
               
                local wpages = TextWidget:new {
                    text = pages_str,
                    face = wright_font_face,
                    fgcolor = fgcolor,
                    padding = 0,
                }
                -- Positional shenanigans to make it look better
                -- If progressbar is shown - then put it above it, 
                -- otherwise make the pause/trophy icon be on the top
                if draw_progressbar then
                    table.insert(wright_items, 1, wpages)
                else
                    table.insert(wright_items, wpages)
                end
            end
            
            local wstatus = TextWidget:new {
                text = status_str,
                face = wright_font_face,
                fgcolor = fgcolor,
                padding = 0,
            }
            if status_str ~= "" then
                table.insert(wright_items, 1, wstatus)
            end

            -- Show fileinfo text, always on bottom
            if BookInfoManager:getSetting("list_show_fileinfo") then
                fileinfo_str = filetype:upper() .. " ⋅ " .. fileinfo_str
                local wfileinfo = TextWidget:new {
                    text = fileinfo_str,
                    face = wright_font_face,
                    fgcolor = fgcolor,
                    height_adjust = true,
                    padding = 0,
                }
                table.insert(wright_items, wfileinfo)
            end

            if #wright_items > 0 and not self.do_filename_only then
                for _, w in ipairs(wright_items) do
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

            -- If in filenames list, add extra padding and empty wright of all items
            if self.do_filename_only then
                wright_right_padding = Screen:scaleBySize(20)
                wmain_left_padding = Screen:scaleBySize(20)
                wright_items = { align = "right" }
            end

            local wmain_width = dimen.w - wleft_width - wmain_left_padding
            local fontname_title = ptutil.title_serif
            local fontname_authors = ptutil.good_serif
            local bold_title = false
            local fontsize_title = title_font_size
            local fontsize_authors = authors_font_size
            local wtitle, wauthors
            local title, authors
            local series_mode = BookInfoManager:getSetting("series_mode")
            local show_series = bookinfo.series and bookinfo.series_index and bookinfo.series_index ~= 0 -- suppress series if index is "0"

            -- whether to use or not title and authors
            -- (We wrap each metadata text with BD.auto() to get for each of them
            -- the text direction from the first strong character - which should
            -- individually be the best thing, and additionnaly prevent shuffling
            -- if concatenated.)
            if self.do_filename_only or bookinfo.ignore_meta then
                title = filename_without_suffix -- made out above
                title = BD.auto(title)
                fontname_title = ptutil.good_sans
                authors = nil
            else
                title = bookinfo.title and bookinfo.title or filename_without_suffix
                title = BD.auto(title)
                local authors_limit = 2
                if (show_series and series_mode == "series_in_separate_line") then authors_limit = 1 end
                authors = ptutil.formatAuthors(bookinfo.authors, authors_limit)
            end
            -- series name and position (if available, if requested)
            if show_series then
                if string.match(bookinfo.series, ": ") then
                    bookinfo.series = string.sub(bookinfo.series, util.lastIndexOf(bookinfo.series, ": ") + 1, -1)
                end
                if bookinfo.series_index then
                    -- bookinfo.series = "\u{FFF1}#" .. bookinfo.series_index .. " – " .. "\u{FFF2}" .. BD.auto(bookinfo.series) .. "\u{FFF3}"
                    bookinfo.series = "Book " .. bookinfo.series_index .. " of " .. BD.auto(bookinfo.series)
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
                    fontname_title = ptutil.good_serif
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
            local height
            local title_height
            local title_line_height
            local title_min_height
            local authors_height
            local authors_line_height
            local authors_min_height

            while true do
                build_title()
                -- blank out the authors and series text for filenames only
                if self.do_filename_only then authors = "" end
                build_authors(authors_width)

                -- if the single-line title is ... then reduce font to try fitting it
                while wtitle:isTruncated() do
                    if fontsize_title <= 20 then
                        break
                    end
                    fontsize_title = fontsize_title - fontsize_dec_step
                    build_title()
                end

                height = wtitle:getSize().h
                height = height + wauthors:getSize().h
                if height <= avail_dimen_h then -- We fit!
                    break
                end
                -- Don't go too low, and get out of this loop.
                if fontsize_title <= 12 or fontsize_authors <= 10 then
                    title_height = wtitle:getSize().h
                    title_line_height = wtitle:getLineHeight()
                    title_min_height = 2 * title_line_height -- unscaled_size_check: ignore
                    authors_height = authors and wauthors:getSize().h or 0
                    authors_height = math.max(authors_height, wright_height)
                    authors_line_height = authors and wauthors:getLineHeight() or 0
                    authors_min_height = 2 * authors_line_height -- unscaled_size_check: ignore
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
            end

            -- align to top normally, align to center in filename only list
            local wtitle_container_style = self.do_filename_only and LeftContainer or TopContainer
            local wtitle_container = wtitle_container_style:new {
                dimen = dimen:copy(),
                wtitle,
            }

            local title_padding = wtitle:getSize().h
            local wauthors_padding = wmain_width - wright_width - wright_right_padding
            -- affix wright to bottom of vertical space
            local wright_vertical_padding = avail_dimen_h - wright_height - title_padding - Size.padding.default
            table.insert(wright_items, 1, VerticalSpan:new { width = (wright_vertical_padding) })

            -- The combined size of the elements in a listbox should not exceed the available
            -- height of that listbox. Log if they do.
            if wtitle:getSize().h + math.max(wauthors:getSize().h, wright_height) > avail_dimen_h then
                logger.info(ptdbg.logprefix, "Listbox height exceeded")
                logger.info(ptdbg.logprefix, "dimen.h ", dimen.h)
                logger.info(ptdbg.logprefix, "avail_dimen_h ", avail_dimen_h)
                logger.info(ptdbg.logprefix, "title ", title)
                logger.info(ptdbg.logprefix, "title_ismultiline ", title_ismultiline)
                logger.info(ptdbg.logprefix, "wtitle:getSize().h ", wtitle:getSize().h)
                logger.info(ptdbg.logprefix, "fontsize_title ", fontsize_title)
                logger.info(ptdbg.logprefix, "authors ", authors)
                logger.info(ptdbg.logprefix, "wauthors_iswider ", wauthors_iswider)
                logger.info(ptdbg.logprefix, "wauthors:getSize().h ", wauthors:getSize().h)
                logger.info(ptdbg.logprefix, "wauthors:getSize().w ", wauthors:getSize().w)
                logger.info(ptdbg.logprefix, "wauthors_padding ", wauthors_padding)
                logger.info(ptdbg.logprefix, "authors_width ", authors_width)
                logger.info(ptdbg.logprefix, "fontsize_authors ", fontsize_authors)
                logger.info(ptdbg.logprefix, "wright_height ", wright_height)
                logger.info(ptdbg.logprefix, "wright_width ", wright_width)
                logger.info(ptdbg.logprefix, "wright_vertical_padding ", wright_vertical_padding)
            end

            -- build the main widget which holds wtitle, wauthors, and wright
            local wmain = LeftContainer:new {
                dimen = dimen:copy(),
                OverlapGroup:new {
                    dimen = dimen:copy(),
                    TopContainer:new {
                        VerticalGroup:new {
                            VerticalSpan:new { width = title_padding },
                            OverlapGroup:new {
                                TopContainer:new {
                                    wauthors,
                                },
                                TopContainer:new {
                                    HorizontalGroup:new {
                                        HorizontalSpan:new { width = wauthors_padding },
                                        TopContainer:new {
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
                for _, w in ipairs(wright_items) do
                    wright_width = math.max(wright_width, w:getSize().w)
                end
                wright = CenterContainer:new {
                    dimen = Geom:new { w = wright_width, h = dimen.h },
                    VerticalGroup:new(wright_items),
                }
            end

            local wleft_width = dimen.w - dimen.h - wright_width - 3 * pad_width
            local wlefttext = BD.filename(self.text)
            local filefont = ptutil.good_sans
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
                    face = Font:getFace(ptutil.good_sans, fontsize_no_bookinfo),
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
    self._underline_container[1] = widget
end

function ListMenuItem:paintTo(bb, x, y)
    -- We used to get non-integer x or y that would cause some mess with image
    -- inside FrameContainer were image would be drawn on top of the top border...
    -- Fixed by having TextWidget:updateSize() math.ceil()'ing its length and height
    -- But let us know if that happens again
    if x ~= math.floor(x) or y ~= math.floor(y) then
        logger.err(ptdbg.logprefix, "ListMenuItem:paintTo() got non-integer x/y :", x, y)
    end

    -- Original painting
    InputContainer.paintTo(self, bb, x, y)
end

-- As done in MenuItem
function ListMenuItem:onFocus()
    ptutil.onFocus(self._underline_container)
    return true
end

function ListMenuItem:onUnfocus()
    ptutil.onUnfocus(self._underline_container)
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
    local perpage = self.files_per_page or 7 -- fallback value for very first run, never used again
    local font_size = self.items_font_size or G_reader_settings:readSetting("items_font_size") or
        Menu.getItemFontSize(perpage)
    if self.perpage ~= perpage or self.font_size ~= font_size then
        self.perpage = perpage
        self.font_size = font_size
    end

    self.portrait_mode = Screen:getWidth() <= Screen:getHeight()
    -- Find out available height from other UI elements made in Menu
    self.others_height = 0

    -- test to see what style to draw (pathchooser vs one of our fancy modes)
    is_pathchooser = ptutil.isPathChooser(self)

    if self.title_bar then -- Menu:init() has been done
        if not self.is_borderless then
            self.others_height = self.others_height + 2
        end
        if not self.no_title then
            -- self.others_height = self.others_height + self.header_padding
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

    self.others_height = self.others_height + (Size.line.thin * self.perpage) -- lines between items
    -- account for extra margins on devices with focus indicator enabled
    if not Device:isTouchDevice() or BookInfoManager:getSetting("force_focus_indicator") then
        self.others_height = self.others_height + (Screen:scaleBySize(3) * self.perpage)
    end
    self.others_height = self.others_height + Screen:scaleBySize(3) -- bottom padding

    local available_height = self.inner_dimen.h - self.others_height

    if not self.portrait_mode then
        -- When in landscape mode, adjust perpage so items get a chance
        -- to have about the same height as when in portrait mode.
        -- This computation is not strictly correct, as "others_height" would
        -- have a different value in portrait mode. But let's go with that.
        local portrait_available_height = Screen:getWidth() - self.others_height
        local portrait_item_height = math.floor(portrait_available_height / self.perpage)
        self.perpage = Math.round(available_height / portrait_item_height)
    end

    self.page_num = math.ceil(#self.item_table / self.perpage)
    -- fix current page if out of range
    if self.page_num > 0 and self.page > self.page_num
    then
        self.page = self.page_num
    end

    -- menu item height based on number of items per page
    self.item_height = math.floor(available_height / self.perpage)
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
    local list_timer = ptdbg:new()
    local line_width = self.width or self.screen_w
    table.insert(self.item_group, ptutil.mediumBlackLine(line_width))
    local idx_offset = (self.page - 1) * self.perpage
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
        local is_boundary_crossed = true
        if idx > 1 then
            -- add focus indicator padding only for devices that need it
            if not Device:isTouchDevice() or BookInfoManager:getSetting("force_focus_indicator") then
                table.insert(self.item_group, VerticalSpan:new { width = Screen:scaleBySize(3) })
            end
            is_boundary_crossed = (index - 1 >= self.recent_boundary_index + 1)
            if is_boundary_crossed then
                table.insert(self.item_group, ptutil.thinGrayLine(line_width))
            else
                table.insert(self.item_group, ptutil.thinBlackLine(line_width))
            end
        end
        local item_tmp = ListMenuItem:new {
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
            do_filename_only = self._do_filename_only,
        }
        table.insert(self.item_group, item_tmp)
        -- this is for focus manager
        table.insert(self.layout, { item_tmp })

        if not item_tmp.bookinfo_found and not item_tmp.is_directory and not item_tmp.file_deleted then
            -- Register this item for update
            table.insert(self.items_to_update, item_tmp)
        end
        itm_timer:report("Draw list item " .. getMenuText(entry))
    end
    list_timer:report("Draw cover list page " .. self.perpage)
    table.insert(self.item_group, VerticalSpan:new { width = Screen:scaleBySize(3) }) -- bottom padding
    return select_number
end

return ListMenu
