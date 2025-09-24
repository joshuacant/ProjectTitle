local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local FileManager = require("apps/filemanager/filemanager")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local OverlapGroup = require("ui/widget/overlapgroup")
local logger = require("logger")
local Device = require("device")
local Screen = Device.screen
local BD = require("ui/bidi")
local T = require("ffi/util").template
local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local ffiUtil = require("ffi/util")
local util = require("util")
local _ = require("l10n.gettext")
local ptdbg = require("ptdbg")
local BookInfoManager = require("bookinfomanager")

local ptutil = {}

ptutil.title_serif = "SourceSerif4-BoldIt.ttf"
ptutil.good_serif = "SourceSerif4-Regular.ttf"
ptutil.good_sans = "SourceSans3-Regular.ttf"

ptutil.koreader_dir = DataStorage:getDataDir()

function ptutil.getPluginDir()
	local callerSource = debug.getinfo(2, "S").source
	if callerSource:find("^@") then
		return callerSource:gsub("^@(.*)/[^/]*", "%1")
	end
end

local function copyRecursive(from, to)
	-- from: koreader/frontend/apps/filemanager/filemanager.lua
	local cp_bin = Device:isAndroid() and "/system/bin/cp" or "/bin/cp"
	return ffiUtil.execute(cp_bin, "-r", from, to) == 0
end

function ptutil.installFonts()
	local fonts_path = ptutil.koreader_dir .. "/fonts"
	local function checkfonts()
		logger.info(ptdbg.logprefix, "Checking for fonts")
		if
			util.fileExists(fonts_path .. "/SourceSans3-Regular.ttf")
			and util.fileExists(fonts_path .. "/SourceSerif4-Regular.ttf")
			and util.fileExists(fonts_path .. "/SourceSerif4-BoldIt.ttf")
		then
			logger.info(ptdbg.logprefix, "Fonts found")
			return true
		else
			return false
		end
	end

	if checkfonts() then
		return true
	end

	local result
	if not util.directoryExists(fonts_path) then
		result = util.makePath(ptutil.koreader_dir .. "/fonts/")
		logger.info(ptdbg.logprefix, "Creating fonts folder")
		if not result then
			return false
		end
	end
	if util.directoryExists(fonts_path) then
		-- copy the entire "source"
		result = copyRecursive(ptutil.getPluginDir() .. "/fonts/source", fonts_path)
		logger.info(ptdbg.logprefix, "Copying fonts")
		if not result then
			return false
		end
		package.loaded["ui/font"] = nil
	end

	if checkfonts() then
		return true
	end
	return false
end

function ptutil.installIcons()
	local icons_path = ptutil.koreader_dir .. "/icons"
	local icons_list = {
		"favorites",
		"go_up",
		"hero",
		"history",
		"last_document",
		"plus",
	}
	local function checkicons()
		logger.info(ptdbg.logprefix, "Checking for icons")
		local icons_found = true
		for _, icon in ipairs(icons_list) do
			local icon_file = icons_path .. "/" .. icon .. ".svg"
			if not util.fileExists(icon_file) then
				icons_found = false
			end
		end
		if icons_found then
			logger.info(ptdbg.logprefix, "All icons found")
			return true
		else
			return false
		end
	end

	if checkicons() then
		return true
	end

	local result
	if not util.directoryExists(icons_path) then
		result = util.makePath(ptutil.koreader_dir .. "/icons/")
		logger.info(ptdbg.logprefix, "Creating icons folder")
		if not result then
			return false
		end
	end

	if util.directoryExists(icons_path) then
		for _, icon in ipairs(icons_list) do
			-- check icon files one at a time, and only copy when missing
			-- this will preserve custom icons set by the user
			local icon_file = icons_path .. "/" .. icon .. ".svg"
			if not util.fileExists(icon_file) then
				local bundled_icon_file = ptutil.getPluginDir() .. "/icons/" .. icon .. ".svg"
				logger.info(ptdbg.logprefix, "Copying icon")
				ffiUtil.copyFile(bundled_icon_file, icon_file)
			end
		end
		package.loaded["ui/widget/iconwidget"] = nil
		package.loaded["ui/widget/iconbutton"] = nil
	end

	if checkicons() then
		return true
	end
	return false
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
			local temp_image = ImageWidget:new({ file = folder_image_file, scale_factor = 1 })
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
			return ImageWidget:new({
				file = folder_image_file,
				width = max_img_w,
				height = max_img_h,
				scale_factor = scale_to_fill,
				center_x_ratio = 0.5,
				center_y_ratio = 0.5,
			})
		end)
		if success then
			return FrameContainer:new({
				width = max_img_w,
				height = max_img_h,
				margin = 0,
				padding = 0,
				bordersize = 0,
				folder_image,
			})
		else
			logger.info(
				ptdbg.logprefix,
				"Folder cover found but failed to render, could be too large or broken:",
				folder_image_file
			)
			local size_mult = 1.25
			local _, _, scale_factor =
				BookInfoManager.getCachedCoverSize(250, 500, max_img_w * size_mult, max_img_h * size_mult)
			return FrameContainer:new({
				width = max_img_w * size_mult,
				height = max_img_h * size_mult,
				margin = 0,
				padding = 0,
				bordersize = 0,
				ImageWidget:new({
					file = ptutil.getPluginDir() .. "/resources/file-unsupported.svg",
					alpha = true,
					scale_factor = scale_factor,
					original_in_nightmode = false,
				}),
			})
		end
	else
		return nil
	end
end

local function query_cover_paths(folder, include_subfolders)
	local db_conn = SQ3.open(DataStorage:getSettingsDir() .. "/PT_bookinfo_cache.sqlite3")
	db_conn:set_busy_timeout(5000)

	if not util.pathExists(folder) then
		return nil
	end

	local query
	if include_subfolders then
		query = string.format(
			[[
                            SELECT directory, filename FROM bookinfo
                            WHERE directory LIKE '%s/%%' AND has_cover = 'Y'
                            ORDER BY RANDOM() LIMIT 16;
                        ]],
			folder:gsub("'", "''")
		)
	else
		query = string.format(
			[[
                            SELECT directory, filename FROM bookinfo
                            WHERE directory = '%s/' AND has_cover = 'Y'
                            ORDER BY RANDOM() LIMIT 16;
                        ]],
			folder:gsub("'", "''")
		)
	end

	local res = db_conn:exec(query)
	db_conn:close()
	return res
end

local function get_thumbnail_size(max_w, max_h)
	local max_img_w = 0
	local max_img_h = 0
	if BookInfoManager:getSetting("use_stacked_foldercovers") then
		max_img_w = (max_w * 0.75) - (Size.border.thin * 2) - Size.padding.default
		max_img_h = (max_h * 0.75) - (Size.border.thin * 2) - Size.padding.default
	else
		max_img_w = (max_w - (Size.border.thin * 4) - Size.padding.small) / 2
		max_img_h = (max_h - (Size.border.thin * 4) - Size.padding.small) / 2
	end
	return max_img_w, max_img_h
end

local function build_cover_images(db_res, max_w, max_h)
	local covers = {}
	if db_res then
		local directories = db_res[1]
		local filenames = db_res[2]
		local max_img_w, max_img_h = get_thumbnail_size(max_w, max_h)
		for i, filename in ipairs(filenames) do
			local fullpath = directories[i] .. filename
			if util.fileExists(fullpath) then
				local bookinfo = BookInfoManager:getBookInfo(fullpath, true)
				if bookinfo then
					local border_total = (Size.border.thin * 2)
					local _, _, scale_factor =
						BookInfoManager.getCachedCoverSize(bookinfo.cover_w, bookinfo.cover_h, max_img_w, max_img_h)
					local wimage = ImageWidget:new({
						image = bookinfo.cover_bb,
						scale_factor = scale_factor,
					})
					table.insert(
						covers,
						FrameContainer:new({
							width = math.floor((bookinfo.cover_w * scale_factor) + border_total),
							height = math.floor((bookinfo.cover_h * scale_factor) + border_total),
							margin = 0,
							padding = 0,
							radius = Size.radius.default,
							bordersize = Size.border.thin,
							color = Blitbuffer.COLOR_GRAY_3,
							background = Blitbuffer.COLOR_GRAY_3,
							wimage,
						})
					)
				end
				if #covers == 4 then
					break
				end
			end
		end
	end
	return covers
end

-- Helper to create a blank frame-style cover with background
local function create_blank_cover(width, height, background_idx)
	local backgrounds = {
		Blitbuffer.COLOR_LIGHT_GRAY,
		Blitbuffer.COLOR_GRAY_D,
		Blitbuffer.COLOR_GRAY_E,
	}
	local max_img_w = width - (Size.border.thin * 2)
	local max_img_h = height - (Size.border.thin * 2)
	return FrameContainer:new({
		width = width,
		height = height,
		radius = Size.radius.default,
		margin = 0,
		padding = 0,
		bordersize = Size.border.thin,
		color = Blitbuffer.COLOR_DARK_GRAY,
		background = backgrounds[background_idx],
		CenterContainer:new({
			dimen = Geom:new({ w = max_img_w, h = max_img_h }),
			HorizontalSpan:new({ width = max_img_w, height = max_img_h }),
		}),
	})
end

-- Build the diagonal stack layout using OverlapGroup
local function build_diagonal_stack(images, max_w, max_h)
	local top_image_size = images[#images]:getSize()
	local nb_fakes = (4 - #images)
	for i = 1, nb_fakes do
		table.insert(images, 1, create_blank_cover(top_image_size.w, top_image_size.h, (i % 2 + 2)))
	end

	local stack_items = {}
	local stack_width = 0
	local stack_height = 0
	local inset_left = 0
	local inset_top = 0
	for _, img in ipairs(images) do
		local frame = FrameContainer:new({
			margin = 0,
			bordersize = 0,
			padding = nil,
			padding_left = inset_left,
			padding_top = inset_top,
			img,
		})
		stack_width = math.max(stack_width, frame:getSize().w)
		stack_height = math.max(stack_height, frame:getSize().h)
		inset_left = inset_left + (max_w * 0.08)
		inset_top = inset_top + (max_h * 0.08)
		table.insert(stack_items, frame)
	end

	local stack = OverlapGroup:new({
		dimen = Geom:new({ w = stack_width, h = stack_height }),
	})
	table.move(stack_items, 1, #stack_items, #stack + 1, stack)
	local centered_stack = CenterContainer:new({
		dimen = Geom:new({ w = max_w, h = max_h }),
		stack,
	})
	return centered_stack
end

-- Build a 2x2 grid layout using nested horizontal & vertical groups
local function build_grid(images, max_w, max_h)
	local row1 = HorizontalGroup:new({})
	local row2 = HorizontalGroup:new({})
	local layout = VerticalGroup:new({})

	-- Create blank covers if needed
	if #images == 3 then
		local w3, h3 = images[3]:getSize().w, images[3]:getSize().h
		table.insert(images, 2, create_blank_cover(w3, h3, 3))
	elseif #images == 2 then
		local w1, h1 = images[1]:getSize().w, images[1]:getSize().h
		local w2, h2 = images[2]:getSize().w, images[2]:getSize().h
		table.insert(images, 2, create_blank_cover(w1, h1, 3))
		table.insert(images, 3, create_blank_cover(w2, h2, 2))
	elseif #images == 1 then
		local w1, h1 = images[1]:getSize().w, images[1]:getSize().h
		table.insert(images, 1, create_blank_cover(w1, h1, 3))
		table.insert(images, 2, create_blank_cover(w1, h1, 2))
		table.insert(images, 4, create_blank_cover(w1, h1, 3))
	end

	for i, img in ipairs(images) do
		if i < 3 then
			table.insert(row1, img)
		else
			table.insert(row2, img)
		end
		if i == 1 then
			table.insert(row1, HorizontalSpan:new({ width = Size.padding.small }))
		elseif i == 3 then
			table.insert(row2, HorizontalSpan:new({ width = Size.padding.small }))
		end
	end

	table.insert(layout, row1)
	table.insert(layout, VerticalSpan:new({ width = Size.padding.small }))
	table.insert(layout, row2)
	return layout
end

function ptutil.getSubfolderCoverImages(filepath, max_w, max_h)
	local db_res = query_cover_paths(filepath, false)
	local images = build_cover_images(db_res, max_w, max_h)

	if #images < 4 then
		db_res = query_cover_paths(filepath, true)
		images = build_cover_images(db_res, max_w, max_h)
	end

	-- Return nil if no images found
	if #images == 0 then
		return nil
	end

	if BookInfoManager:getSetting("use_stacked_foldercovers") then
		return build_diagonal_stack(images, max_w, max_h)
	else
		return build_grid(images, max_w, max_h)
	end
end

function ptutil.line(width, color, thickness)
	return HorizontalGroup:new({
		HorizontalSpan:new({ width = Screen:scaleBySize(10) }),
		LineWidget:new({
			dimen = Geom:new({ w = width - Screen:scaleBySize(20), h = thickness }),
			background = color,
		}),
		HorizontalSpan:new({ width = Screen:scaleBySize(10) }),
	})
end

ptutil.thinWhiteLine = function(w)
	return ptutil.line(w, Blitbuffer.COLOR_WHITE, Size.line.thin)
end
ptutil.thinGrayLine = function(w)
	return ptutil.line(w, Blitbuffer.COLOR_GRAY, Size.line.thin)
end
ptutil.thinBlackLine = function(w)
	return ptutil.line(w, Blitbuffer.COLOR_BLACK, Size.line.thin)
end
ptutil.mediumBlackLine = function(w)
	return ptutil.line(w, Blitbuffer.COLOR_BLACK, Size.line.medium)
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
	if
		BookInfoManager:getSetting("force_max_progressbars")
		and not BookInfoManager:getSetting("show_pages_read_as_progress")
	then
		est_page_count = "700"
	end
	show_progress_bar = est_page_count ~= nil
		and BookInfoManager:getSetting("hide_file_info") -- "show file info"
		and not BookInfoManager:getSetting("show_pages_read_as_progress") -- "show pages read"
		and not BookInfoManager:getSetting("force_no_progressbars") -- "show progress %"
	return est_page_count, show_progress_bar
end

function ptutil.isPathChooser(self)
	local is_pathchooser = false
	if (self.title_bar and self.title_bar.title ~= "") or (self.menu and self.menu.title ~= "") then
		is_pathchooser = true
	end
	return is_pathchooser
end

function ptutil.formatAuthors(authors, authors_limit)
	local formatted_authors
	if authors and authors:find("\n") then
		local full_authors_list = util.splitToArray(authors, "\n")
		local nb_authors = #full_authors_list
		local final_authors_list = {}
		for i = 1, nb_authors do
			full_authors_list[i] = BD.auto(full_authors_list[i])
			if i == authors_limit and nb_authors > authors_limit then
				table.insert(final_authors_list, T(_("%1 et al."), full_authors_list[i]))
			else
				table.insert(final_authors_list, full_authors_list[i])
			end
			if i == authors_limit then
				break
			end
		end
		formatted_authors = table.concat(final_authors_list, "\n")
	elseif authors then
		formatted_authors = BD.auto(authors)
	end
	return formatted_authors
end

return ptutil
