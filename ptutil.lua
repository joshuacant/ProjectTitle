local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local Device = require("device")
local Screen = Device.screen
local util = require("util")
local _ = require("l10n.gettext")
local ptdbg = require("ptdbg")
local BookInfoManager = require("bookinfomanager")

local ptutil = {}

ptutil.title_serif = "source/SourceSerif4-BoldIt.ttf"
ptutil.good_serif = "source/SourceSerif4-Regular.ttf"
ptutil.good_sans = "source/SourceSans3-Regular.ttf"

function ptutil.getSourceDir()
    local callerSource = debug.getinfo(2, "S").source
    if callerSource:find("^@") then
        return callerSource:gsub("^@(.*)/[^/]*", "%1")
    end
end

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

function ptutil.getFolderCover(filepath, max_img_w, max_img_h)
    local folder_image_file = findCover(filepath)
    if folder_image_file ~= nil then
        local success, folder_image = pcall(function()
            local temp_image = ImageWidget:new { file = folder_image_file, scale_factor = 1 }
            temp_image:_render()
            local orig_w = temp_image:getOriginalWidth()
            local orig_h = temp_image:getOriginalHeight()
            temp_image:free()
            local scale_to_fill = 0
            if orig_w and orig_h then
                local scale_x = max_img_w / orig_w
                local scale_y = max_img_h / orig_h
                scale_to_fill = math.max(scale_x, scale_y)
            end
            return ImageWidget:new {
                file = folder_image_file,
                width = max_img_w,
                height = max_img_h,
                scale_factor = scale_to_fill,
                center_x_ratio = 0.5,
                center_y_ratio = 0.5,
            }
        end)
        if success then
            return FrameContainer:new {
                width = max_img_w,
                height = max_img_h,
                margin = 0,
                padding = 0,
                bordersize = 0,
                folder_image
            }
        else
            logger.info(ptdbg.logprefix, "Folder cover found but failed to render, could be too large or broken:", folder_image_file)
            local size_mult = 1.25
            local _, _, scale_factor = BookInfoManager.getCachedCoverSize(250, 500, max_img_w * size_mult, max_img_h * size_mult)
            return FrameContainer:new {
                width = max_img_w * size_mult,
                height = max_img_h * size_mult,
                margin = 0,
                padding = 0,
                bordersize = 0,
                ImageWidget:new {
                    file = ptutil.getSourceDir() .. "/resources/file-unsupported.svg",
                    alpha = true,
                    scale_factor = scale_factor,
                    original_in_nightmode = false,
                }
            }
        end
    else
        return nil
    end
end

local function query_cover_paths(folder, include_subfolders)
    local SQ3 = require("lua-ljsqlite3/init")
    local DataStorage = require("datastorage")
    local db_conn = SQ3.open(DataStorage:getSettingsDir() .. "/PT_bookinfo_cache.sqlite3")
    db_conn:set_busy_timeout(5000)

    if not util.pathExists(folder) then return nil end

    local query
    if include_subfolders then
        query = string.format([[
                            SELECT directory, filename FROM bookinfo
                            WHERE directory LIKE '%s/%%' AND has_cover = 'Y'
                            ORDER BY RANDOM() LIMIT 16;
                        ]], folder:gsub("'", "''"))
    else
        query = string.format([[
                            SELECT directory, filename FROM bookinfo
                            WHERE directory = '%s/' AND has_cover = 'Y'
                            ORDER BY RANDOM() LIMIT 16;
                        ]], folder:gsub("'", "''"))
    end

    local res = db_conn:exec(query)
    db_conn:close()
    return res
end

local function build_cover_images(res, max_img_w, max_img_h)
    local covers = {}
    if res then
        local directories = res[1]
        local filenames = res[2]
        max_img_w = (max_img_h - (Size.border.thin * 4) - Size.padding.small) / 2
        max_img_h = (max_img_h - (Size.border.thin * 4) - Size.padding.small) / 2
        for i, filename in ipairs(filenames) do
            local fullpath = directories[i] .. filename
            if util.fileExists(fullpath) then
                local book = BookInfoManager:getBookInfo(fullpath, true)
                if book then
                    local _, _, scale_factor = BookInfoManager.getCachedCoverSize(
                        book.cover_w, book.cover_h, max_img_w, max_img_h
                    )
                    table.insert(covers, FrameContainer:new {
                        radius = Size.radius.default,
                        margin = 0,
                        padding = 0,
                        bordersize = Size.border.thin,
                        color = Blitbuffer.COLOR_DARK_GRAY,
                        ImageWidget:new {
                            image = book.cover_bb,
                            scale_factor = scale_factor,
                        }
                    })
                end
                if #covers == 4 then break end
            end
        end
    end
    return covers
end

function ptutil.getSubfolderCoverImages(filepath, max_img_w, max_img_h)
    local res = query_cover_paths(filepath, false)
    local subfolder_images = build_cover_images(res, max_img_w, max_img_h)

    if #subfolder_images < 4 then
        res = query_cover_paths(filepath, true)
        subfolder_images = build_cover_images(res, max_img_w, max_img_h)
    end

    -- Continue if we found at least one cover
    if #subfolder_images >= 1 then
        local backgrounds = {
            Blitbuffer.COLOR_LIGHT_GRAY,
            Blitbuffer.COLOR_GRAY_D,
            Blitbuffer.COLOR_GRAY_E,
        }
        local function create_blank_cover(w, h, b)
            local w_minus = w - (Size.border.thin * 2)
            local h_minus = h - (Size.border.thin * 2)
            return FrameContainer:new {
                width = w,
                height = h,
                radius = Size.radius.default,
                margin = 0,
                padding = 0,
                bordersize = Size.border.thin,
                color = Blitbuffer.COLOR_DARK_GRAY,
                background = backgrounds[b],
                CenterContainer:new {
                    dimen = Geom:new { w = w_minus, h = h_minus },
                    HorizontalSpan:new { width = w_minus, height = h_minus }
                }
            }
        end

        if #subfolder_images == 3 then
            local w = subfolder_images[3]:getSize().w
            local h = subfolder_images[3]:getSize().h
            table.insert(subfolder_images, 2, create_blank_cover(w, h, 3))
        elseif #subfolder_images == 2 then
            local w1 = subfolder_images[1]:getSize().w
            local h1 = subfolder_images[1]:getSize().h
            local w2 = subfolder_images[2]:getSize().w
            local h2 = subfolder_images[2]:getSize().h
            table.insert(subfolder_images, 2, create_blank_cover(w1, h1, 3))
            table.insert(subfolder_images, 3, create_blank_cover(w2, h2, 2))
        elseif #subfolder_images == 1 then
            local w = subfolder_images[1]:getSize().w
            local h = subfolder_images[1]:getSize().h
            table.insert(subfolder_images, 1, create_blank_cover(w, h, 3))
            table.insert(subfolder_images, 2, create_blank_cover(w, h, 2))
            table.insert(subfolder_images, 4, create_blank_cover(w, h, 3))
        end

        local subfolder_image_row1 = HorizontalGroup:new {}
        local subfolder_image_row2 = HorizontalGroup:new {}
        local subfolder_cover_image = VerticalGroup:new {}

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

        return subfolder_cover_image
    else
        return nil
    end
end

function ptutil.darkLine(width)
    return HorizontalGroup:new {
        HorizontalSpan:new { width = Screen:scaleBySize(10) },
        LineWidget:new {
            dimen = Geom:new { w = width - Screen:scaleBySize(20), h = Size.line.medium },
            background = Blitbuffer.COLOR_BLACK,
        },
        HorizontalSpan:new { width = Screen:scaleBySize(10) },
    }
end

function ptutil.lightLine(width)
    return HorizontalGroup:new {
        HorizontalSpan:new { width = Screen:scaleBySize(10) },
        LineWidget:new {
            dimen = Geom:new { w = width - Screen:scaleBySize(20), h = Size.line.thin },
            background = Blitbuffer.COLOR_GRAY,
        },
        HorizontalSpan:new { width = Screen:scaleBySize(10) },
    }
end

function ptutil.onFocus(_underline_container)
    if not Device:isTouchDevice() or BookInfoManager:getSetting("force_focus_indicator") then
        _underline_container.color = Blitbuffer.COLOR_BLACK
    end
end

function ptutil.onUnfocus(_underline_container)
    if not Device:isTouchDevice() or BookInfoManager:getSetting("force_focus_indicator") then
        _underline_container.color = Blitbuffer.COLOR_WHITE
    end
end

function ptutil.showProgressBar(pages)
    local show_progress_bar = false
    local est_page_count = pages or nil
    if BookInfoManager:getSetting("force_max_progressbars") then est_page_count = "700" end
    show_progress_bar = est_page_count ~= nil and
        BookInfoManager:getSetting("hide_file_info") and                    -- "show file info"
        not BookInfoManager:getSetting("show_pages_read_as_progress") and   -- "show pages read"
        not BookInfoManager:getSetting("force_no_progressbars")             -- "show progress %"
    return est_page_count, show_progress_bar
end

function ptutil.isPathChooser(self)
    local is_pathchooser = false
    if (self.title_bar and self.title_bar.title ~= "") or (self.menu and self.menu.title ~= "") then
        is_pathchooser = true
    end
    return is_pathchooser
end

return ptutil
