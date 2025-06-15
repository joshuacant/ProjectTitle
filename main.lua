--[[
    Project: Title builds upon the work in the Cover Browser plugin to dramatically
    alter the way list and mosaic views appear.

    Additional provided files must be installed for this plugin to work. See the
    installation wiki page on the Project: Title github for details.
--]]

-- Disable this entire plugin if: fonts missing. icons missing. coverbrowser enabled. wrong version of koreader.
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local Version = require("version")
-- data_dir is separate from lfs.currentdir() on Android.  Will be `.`
-- on Kobo devices but a full path on Android.
local data_dir = DataStorage:getDataDir()
logger.info("Checking project title requirements in " .. data_dir)

local font1_missing = true
if lfs.attributes(data_dir .. "/fonts/source/SourceSans3-Regular.ttf") ~= nil then
    font1_missing = false
else
    logger.warn("Font1 missing")
end
local font2_missing = true
if lfs.attributes(data_dir .. "/fonts/source/SourceSerif4-Regular.ttf") ~= nil then
    font2_missing = false
else
    logger.warn("Font2 missing")
end
local font3_missing = true
if lfs.attributes(data_dir .. "/fonts/source/SourceSerif4-BoldIt.ttf") ~= nil then
    font3_missing = false
else
    logger.warn("Font3 missing")
end
local icons_missing = true
if lfs.attributes(data_dir .. "/icons/hero.svg") ~= nil then
    icons_missing = false -- check for one icon and assume the rest are there too
else
    logger.warn("Icons missing")
end
local plugins_disabled = G_reader_settings:readSetting("plugins_disabled")
if type(plugins_disabled) ~= "table" then
    plugins_disabled = {}
end
local coverbrowser_plugin = true
if plugins_disabled["coverbrowser"] == true then
    coverbrowser_plugin = false
else
    logger.warn("CoverBrowser enabled")
end
local safe_version = 202504000000
local cv_int, cv_hash = Version:getNormalizedCurrentVersion()
local version_unsafe = true
if (cv_int == safe_version) then
    version_unsafe = false
else
    logger.warn("Version not safe ", tostring(cv_int))
end
if font1_missing or font2_missing or font3_missing or icons_missing or coverbrowser_plugin or version_unsafe then
    logger.warn("therefore refusing to load Project: Title")
    return { disabled = true, }
end
logger.info("All tests passed, loading Project: Title on KOReader ver ", tostring(cv_int))

-- carry on...
local FFIUtil = require("ffi/util")
local Dispatcher = require("dispatcher")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local T = require("ffi/util").template
local BookInfoManager = require("bookinfomanager")

-- We need to save the original methods early here as locals.
-- For some reason, saving them as attributes in init() does not allow
-- us to get back to classic mode
local FileChooser = require("ui/widget/filechooser")
local _FileChooser__recalculateDimen_orig = FileChooser._recalculateDimen
local _FileChooser_updateItems_orig = FileChooser.updateItems
local _FileChooser_onCloseWidget_orig = FileChooser.onCloseWidget
local _FileChooser_genItemTable_orig = FileChooser.genItemTable

local FileManager = require("apps/filemanager/filemanager")
local FileManagerHistory = require("apps/filemanager/filemanagerhistory")
local FileManagerCollection = require("apps/filemanager/filemanagercollection")
local FileManagerFileSearcher = require("apps/filemanager/filemanagerfilesearcher")

local _modified_widgets = {
    filemanager  = FileManager,
    history      = FileManagerHistory,
    collections  = FileManagerCollection,
    filesearcher = FileManagerFileSearcher,
}
local _updateItemTable_orig_funcs = {
    history      = FileManagerHistory.updateItemTable,
    collections  = FileManagerCollection.updateItemTable,
    filesearcher = FileManagerFileSearcher.updateItemTable,
}

local _FileManager_tapPlus_orig = FileManager.tapPlus
local _FileManager_setupLayout_orig = FileManager.setupLayout
local _FileManager_updateTitleBarPath_orig = FileManager.updateTitleBarPath

local Menu = require("ui/widget/menu")
local _Menu_init_orig = Menu.init
local _Menu_updatePageInfo_orig = Menu.updatePageInfo

local BookStatusWidget = require("ui/widget/bookstatuswidget")
-- local _BookStatusWidget_genHeader_orig = BookStatusWidget.genHeader
-- local _BookStatusWidget_getStatusContent_orig = BookStatusWidget.getStatusContent
-- local _BookStatusWidget_genBookInfoGroup_orig = BookStatusWidget.genBookInfoGroup
-- local _BookStatusWidget_genSummaryGroup_orig = BookStatusWidget.genSummaryGroup
local AltBookStatusWidget = require("altbookstatuswidget")

-- Available display modes
local DISPLAY_MODES = {
    -- nil or ""                -- classic : filename only
    mosaic_image    = true,     -- 3x3 grid covers with images
    list_image_meta = true,     -- image with metadata (title/authors)
    list_only_meta  = true,     -- metadata with no image
}
local display_mode_db_names = {
    filemanager = "filemanager_display_mode",
    history     = "history_display_mode",
    collections = "collection_display_mode",
}
-- Store some states as locals, to be permanent across instantiations
local init_done = false
local curr_display_modes = {
    filemanager = false,  -- not initialized yet
    history     = false,  -- not initialized yet
    collections = false,  -- not initialized yet
}
local series_mode = nil   -- defaults to not display series

local CoverBrowser = WidgetContainer:extend {
    name = "coverbrowserclean",
    modes = {
        { _("Detailed List"),               "list_only_meta" },
        { _("Detailed List (with covers)"), "list_image_meta" },
        { _("Cover Grid"),                  "mosaic_image" },
        { _("Filenames List") },
    },
}

local enable_custom_bookstatus = true
local max_items_per_page = 10
local min_items_per_page = 3
local default_items_per_page = 7
local max_cols = 4
local max_rows = 4
local min_cols = 2
local min_rows = 2
local default_cols = 3
local default_rows = 3

function CoverBrowser:onDispatcherRegisterActions()
    Dispatcher:registerAction("dec_items_pp",
        { category = "none", event = "DecreaseItemsPerPage", title = _("Project: Title - Decrease Items Per Page"), filemanager = true, separator = false })
    Dispatcher:registerAction("inc_items_pp",
        { category = "none", event = "IncreaseItemsPerPage", title = _("Project: Title - Increase Items Per Page"), filemanager = true, separator = false })
end

function CoverBrowser:init()
    if not self.ui.document then -- FileManager menu only
        self.ui.menu:registerToMainMenu(self)
    end

    if init_done then -- things already patched according to current modes
        return
    end

    if enable_custom_bookstatus == true then
        BookStatusWidget.genHeader = AltBookStatusWidget.genHeader
        BookStatusWidget.getStatusContent = AltBookStatusWidget.getStatusContent
        BookStatusWidget.genBookInfoGroup = AltBookStatusWidget.genBookInfoGroup
        BookStatusWidget.genSummaryGroup = AltBookStatusWidget.genSummaryGroup
    end

    -- Set up default display modes on first launch
    if not G_reader_settings:isTrue("aaaProjectTitle_initial_default_setup_done2") then
        -- Only if no display mode has been set yet
        if not BookInfoManager:getSetting("filemanager_display_mode")
            and not BookInfoManager:getSetting("history_display_mode") then
            BookInfoManager:saveSetting("filemanager_display_mode", "list_image_meta")
            BookInfoManager:saveSetting("history_display_mode", "list_image_meta")
            BookInfoManager:saveSetting("collection_display_mode", "list_image_meta")
        end
        -- set up a few default settings
        BookInfoManager:saveSetting("series_mode", "series_in_separate_line")
        BookInfoManager:saveSetting("hide_file_info", true)
        BookInfoManager:saveSetting("unified_display_mode", true)
        BookInfoManager:saveSetting("show_progress_in_mosaic", true)
        BookInfoManager:saveSetting("autoscan_on_eject", false)
        G_reader_settings:makeTrue("aaaProjectTitle_initial_default_setup_done2")
        UIManager:restartKOReader()
        FFIUtil.sleep(2)
    end

    self:setupFileManagerDisplayMode(BookInfoManager:getSetting("filemanager_display_mode"))
    CoverBrowser.setupWidgetDisplayMode("history", true)
    CoverBrowser.setupWidgetDisplayMode("collections", true)
    series_mode = BookInfoManager:getSetting("series_mode")

    local home_dir = G_reader_settings:readSetting("home_dir")
    if home_dir and BookInfoManager:getSetting("autoscan_on_eject") then
        local cover_specs = { max_cover_w = 1, max_cover_h = 1, }
        Trapper:wrap(function()
            BookInfoManager:extractBooksInDirectory(home_dir, cover_specs, true)
        end)
    end

    init_done = true
    self:onDispatcherRegisterActions()
    BookInfoManager:closeDbConnection() -- will be re-opened if needed
end

function CoverBrowser:addToMainMenu(menu_items)
    local sub_item_table, history_sub_item_table, collection_sub_item_table = {}, {}, {}
    for i, v in ipairs(self.modes) do
        local text, mode = unpack(v)
        sub_item_table[i] = {
            text = text,
            checked_func = function()
                -- return mode == filemanager_display_mode
                return mode == curr_display_modes["filemanager"]
            end,
            callback = function()
                self:setDisplayMode(mode)
            end,
        }
        history_sub_item_table[i] = {
            text = text,
            checked_func = function()
                return mode == curr_display_modes["history"]
            end,
            callback = function()
                CoverBrowser.setupWidgetDisplayMode("history", mode)
            end,
        }
        collection_sub_item_table[i] = {
            text = text,
            checked_func = function()
                return mode == curr_display_modes["collections"]
            end,
            callback = function()
                CoverBrowser.setupWidgetDisplayMode("collections", mode)
            end,
        }
    end
    sub_item_table[#self.modes].separator = true
    table.insert(sub_item_table, {
        text = _("Use this mode everywhere"),
        checked_func = function()
            return BookInfoManager:getSetting("unified_display_mode")
        end,
        callback = function()
            if BookInfoManager:toggleSetting("unified_display_mode") then
                CoverBrowser.setupWidgetDisplayMode("history", curr_display_modes["filemanager"])
                CoverBrowser.setupWidgetDisplayMode("collections", curr_display_modes["filemanager"])
            end
        end,
    })
    table.insert(sub_item_table, {
        text = _("History display mode"),
        enabled_func = function()
            return not BookInfoManager:getSetting("unified_display_mode")
        end,
        sub_item_table = history_sub_item_table,
    })
    table.insert(sub_item_table, {
        text = _("Collections display mode"),
        enabled_func = function()
            return not BookInfoManager:getSetting("unified_display_mode")
        end,
        sub_item_table = collection_sub_item_table,
    })
    menu_items.filemanager_display_mode = {
        text = _("Display mode"),
        sub_item_table = sub_item_table,
    }

    -- add Mosaic / Detailed list mode settings to File browser Settings submenu
    -- next to Classic mode settings
    if menu_items.filebrowser_settings == nil then return end
    local fc = self.ui.file_chooser
    table.insert(menu_items.filebrowser_settings.sub_item_table, 5, {
        text = _("Project: Title settings"),
        separator = true,
        sub_item_table = {
            {
                text_func = function()
                    return T(_("Items per page in portrait cover grid mode: %1 × %2"), fc.nb_cols_portrait,
                        fc.nb_rows_portrait)
                end,
                -- Best to not "keep_menu_open = true", to see how this apply on the full view
                callback = function()
                    local nb_cols = fc.nb_cols_portrait
                    local nb_rows = fc.nb_rows_portrait
                    local DoubleSpinWidget = require("/ui/widget/doublespinwidget")
                    local widget = DoubleSpinWidget:new {
                        title_text = _("Portrait cover grid mode"),
                        width_factor = 0.6,
                        left_text = _("Columns"),
                        left_value = nb_cols,
                        left_min = min_cols,
                        left_max = max_cols,
                        left_default = default_cols,
                        left_precision = "%01d",
                        right_text = _("Rows"),
                        right_value = nb_rows,
                        right_min = min_rows,
                        right_max = max_rows,
                        right_default = default_rows,
                        right_precision = "%01d",
                        keep_shown_on_apply = true,
                        callback = function(left_value, right_value)
                            fc.nb_cols_portrait = left_value
                            fc.nb_rows_portrait = right_value
                            if fc.display_mode_type == "mosaic" and fc.portrait_mode then
                                fc.no_refresh_covers = true
                                fc:updateItems()
                            end
                        end,
                        close_callback = function()
                            if fc.nb_cols_portrait ~= nb_cols or fc.nb_rows_portrait ~= nb_rows then
                                BookInfoManager:saveSetting("nb_cols_portrait", fc.nb_cols_portrait)
                                BookInfoManager:saveSetting("nb_rows_portrait", fc.nb_rows_portrait)
                                FileChooser.nb_cols_portrait = fc.nb_cols_portrait
                                FileChooser.nb_rows_portrait = fc.nb_rows_portrait
                                if fc.display_mode_type == "mosaic" and fc.portrait_mode then
                                    fc.no_refresh_covers = nil
                                    fc:updateItems()
                                end
                            end
                        end,
                    }
                    UIManager:show(widget)
                end,
            },
            {
                text_func = function()
                    return T(_("Items per page in landscape cover grid mode: %1 × %2"), fc.nb_cols_landscape,
                        fc.nb_rows_landscape)
                end,
                callback = function()
                    local nb_cols = fc.nb_cols_landscape
                    local nb_rows = fc.nb_rows_landscape
                    local DoubleSpinWidget = require("/ui/widget/doublespinwidget")
                    local widget = DoubleSpinWidget:new {
                        title_text = _("Landscape cover grid mode"),
                        width_factor = 0.6,
                        left_text = _("Columns"),
                        left_value = nb_cols,
                        left_min = min_cols,
                        left_max = max_cols,
                        left_default = default_cols,
                        left_precision = "%01d",
                        right_text = _("Rows"),
                        right_value = nb_rows,
                        right_min = min_rows,
                        right_max = max_rows,
                        right_default = default_cols,
                        right_precision = "%01d",
                        keep_shown_on_apply = true,
                        callback = function(left_value, right_value)
                            fc.nb_cols_landscape = left_value
                            fc.nb_rows_landscape = right_value
                            if fc.display_mode_type == "mosaic" and not fc.portrait_mode then
                                fc.no_refresh_covers = true
                                fc:updateItems()
                            end
                        end,
                        close_callback = function()
                            if fc.nb_cols_landscape ~= nb_cols or fc.nb_rows_landscape ~= nb_rows then
                                BookInfoManager:saveSetting("nb_cols_landscape", fc.nb_cols_landscape)
                                BookInfoManager:saveSetting("nb_rows_landscape", fc.nb_rows_landscape)
                                FileChooser.nb_cols_landscape = fc.nb_cols_landscape
                                FileChooser.nb_rows_landscape = fc.nb_rows_landscape
                                if fc.display_mode_type == "mosaic" and not fc.portrait_mode then
                                    fc.no_refresh_covers = nil
                                    fc:updateItems()
                                end
                            end
                        end,
                    }
                    UIManager:show(widget)
                end,
            },
            {
                text_func = function()
                    -- default files_per_page should be calculated by ListMenu on the first drawing,
                    -- use 7 if ListMenu has not been drawn yet
                    return T(_("Items per page in portrait list mode: %1"), fc.files_per_page or default_items_per_page)
                end,
                callback = function()
                    local files_per_page = fc.files_per_page or default_items_per_page
                    local SpinWidget = require("ui/widget/spinwidget")
                    local widget = SpinWidget:new {
                        title_text = _("Portrait list mode"),
                        value = files_per_page,
                        value_min = min_items_per_page,
                        value_max = max_items_per_page,
                        default_value = default_items_per_page,
                        keep_shown_on_apply = true,
                        callback = function(spin)
                            fc.files_per_page = spin.value
                            if fc.display_mode_type == "list" then
                                fc.no_refresh_covers = true
                                fc:updateItems()
                            end
                        end,
                        close_callback = function()
                            if fc.files_per_page ~= files_per_page then
                                BookInfoManager:saveSetting("files_per_page", fc.files_per_page)
                                FileChooser.files_per_page = fc.files_per_page
                                if fc.display_mode_type == "list" then
                                    fc.no_refresh_covers = nil
                                    fc:updateItems()
                                end
                            end
                        end,
                    }
                    UIManager:show(widget)
                end,
                separator = true,
            },
            {
                text = _("Show series metadata"),
                checked_func = function() return series_mode == "series_in_separate_line" end,
                callback = function()
                    if series_mode == "series_in_separate_line" then
                        series_mode = nil
                    else
                        series_mode = "series_in_separate_line"
                    end
                    BookInfoManager:saveSetting("series_mode", series_mode)
                    fc:updateItems(1, true)
                end,
            },
            {
                text = _("Show pages read instead of progress %"),
                enabled_func = function() return not BookInfoManager:getSetting("hide_page_info") end,
                checked_func = function() return BookInfoManager:getSetting("show_pages_read_as_progress") end,
                callback = function()
                    BookInfoManager:toggleSetting("show_pages_read_as_progress")
                    fc:updateItems(1, true)
                end,
            },
            {
                text = _("Show file info instead of pages or progress %"),
                checked_func = function()
                    return not BookInfoManager:getSetting("hide_file_info")
                end,
                callback = function()
                    BookInfoManager:toggleSetting("hide_file_info")
                    if not BookInfoManager:getSetting("hide_file_info") then
                        BookInfoManager:saveSetting("hide_page_info", true)
                    else
                        BookInfoManager:saveSetting("hide_page_info", false)
                    end
                    fc:updateItems(1, true)
                end,
            },
            {
                text = _("Book covers and info cache"),
                sub_item_table = {
                    {
                        text = _("Scan home folder for new books automatically"),
                        checked_func = function() return BookInfoManager:getSetting("autoscan_on_eject") end,
                        callback = function()
                            BookInfoManager:toggleSetting("autoscan_on_eject")
                        end,
                    },
                    {
                        text = _("Prune cache…"),
                        keep_menu_open = false,
                        callback = function()
                            local ConfirmBox = require("ui/widget/confirmbox")
                            UIManager:close(self.file_dialog)
                            UIManager:show(ConfirmBox:new {
                                -- Checking file existences is quite fast, but deleting entries is slow.
                                text = _("Are you sure that you want to prune cache of removed books?\n(This may take a while.)"),
                                ok_text = _("Prune cache"),
                                ok_callback = function()
                                    local InfoMessage = require("ui/widget/infomessage")
                                    local msg = InfoMessage:new { text = _("Pruning cache of removed books…") }
                                    UIManager:show(msg)
                                    UIManager:nextTick(function()
                                        local summary = BookInfoManager:removeNonExistantEntries()
                                        BookInfoManager:compactDb() -- compact
                                        UIManager:close(msg)
                                        UIManager:show(InfoMessage:new { text = summary })
                                    end)
                                end
                            })
                        end,
                    },
                    {
                        text = _("Empty cache…"),
                        keep_menu_open = false,
                        callback = function()
                            local ConfirmBox = require("ui/widget/confirmbox")
                            UIManager:close(self.file_dialog)
                            UIManager:show(ConfirmBox:new {
                                text = _("Are you sure that you want to delete cover and metadata cache for all books?"),
                                ok_text = _("Empty cache"),
                                ok_callback = function()
                                    BookInfoManager:deleteDb()
                                    BookInfoManager:compactDb() -- compact
                                    local InfoMessage = require("ui/widget/infomessage")
                                    UIManager:show(InfoMessage:new { text = "Cache emptied." })
                                end
                            })
                        end,
                        separator = true,
                    },
                    {
                        text_func = function() -- add current db size to menu text
                            local sstr = BookInfoManager:getDbSize()
                            return _("Cache Size: ") .. sstr
                        end,
                        keep_menu_open = true,
                        callback = function() end, -- no callback, only for information
                    },
                },
            },
        },
    })
end

function CoverBrowser:genExtractBookInfoButton(close_dialog_callback) -- for FileManager Plus dialog
    return curr_display_modes["filemanager"] and {
        {
            text = _("Extract and cache book information"),
            callback = function()
                close_dialog_callback()
                local fc = self.ui.file_chooser
                local Trapper = require("ui/trapper")
                Trapper:wrap(function()
                    BookInfoManager:extractBooksInDirectory(fc.path, fc.cover_specs)
                end)
            end,
        },
    }
end

function CoverBrowser:genMultipleRefreshBookInfoButton(close_dialog_toggle_select_mode_callback, button_disabled)
    return curr_display_modes["filemanager"] and {
        {
            text = _("Refresh cached book information"),
            enabled = not button_disabled,
            callback = function()
                for file in pairs(self.ui.selected_files) do
                    BookInfoManager:deleteBookInfo(file)
                    self.ui.file_chooser.resetBookInfoCache(file)
                end
                close_dialog_toggle_select_mode_callback()
            end,
        },
    }
end

function CoverBrowser.initGrid(menu, display_mode)
    if menu == nil then return end
    if menu.nb_cols_portrait == nil then
        menu.nb_cols_portrait  = BookInfoManager:getSetting("nb_cols_portrait") or default_cols
        menu.nb_rows_portrait  = BookInfoManager:getSetting("nb_rows_portrait") or default_rows
        menu.nb_cols_landscape = BookInfoManager:getSetting("nb_cols_landscape") or default_cols
        menu.nb_rows_landscape = BookInfoManager:getSetting("nb_rows_landscape") or default_rows
        -- initial List mode files_per_page will be calculated and saved by ListMenu on the first drawing
        menu.files_per_page    = BookInfoManager:getSetting("files_per_page")
    end
    menu.display_mode_type = display_mode and display_mode:gsub("_.*", "") -- "mosaic" or "list"
end

function CoverBrowser.addFileDialogButtons(widget_id)
    local widget = _modified_widgets[widget_id]
    FileManager.addFileDialogButtons(widget, "coverbrowser_1", function(file, is_file, bookinfo)
        if is_file then
            return bookinfo and {
                { -- Allow user to ignore some offending cover image
                    text = bookinfo.ignore_cover and _("Unignore cover") or _("Ignore cover"),
                    enabled = bookinfo.has_cover and true or false,
                    callback = function()
                        BookInfoManager:setBookInfoProperties(file, {
                            ["ignore_cover"] = not bookinfo.ignore_cover and 'Y' or false,
                        })
                        widget.files_updated = true
                        local menu = widget.getMenuInstance()
                        UIManager:close(menu.file_dialog)
                        menu:updateItems(1, true)
                    end,
                },
                { -- Allow user to ignore some bad metadata (filename will be used instead)
                    text = bookinfo.ignore_meta and _("Unignore metadata") or _("Ignore metadata"),
                    enabled = bookinfo.has_meta and true or false,
                    callback = function()
                        BookInfoManager:setBookInfoProperties(file, {
                            ["ignore_meta"] = not bookinfo.ignore_meta and 'Y' or false,
                        })
                        widget.files_updated = true
                        local menu = widget.getMenuInstance()
                        UIManager:close(menu.file_dialog)
                        menu:updateItems(1, true)
                    end,
                },
            }
        end
    end)
    FileManager.addFileDialogButtons(widget, "coverbrowser_2", function(file, is_file, bookinfo)
        if is_file then
            return bookinfo and {
                { -- Allow a new extraction (multiple interruptions, book replaced)...
                    text = _("Refresh cached book information"),
                    callback = function()
                        BookInfoManager:deleteBookInfo(file)
                        widget.files_updated = true
                        local menu = widget.getMenuInstance()
                        menu.resetBookInfoCache(file)
                        UIManager:close(menu.file_dialog)
                        menu:updateItems(1, true)
                    end,
                },
            }
        end
    end)
end

function CoverBrowser.removeFileDialogButtons(widget_id)
    local widget = _modified_widgets[widget_id]
    FileManager.removeFileDialogButtons(widget, "coverbrowser_2")
    FileManager.removeFileDialogButtons(widget, "coverbrowser_1")
end

function CoverBrowser:refreshFileManagerInstance(cleanup, post_init)
    local fc = self.ui.file_chooser
    if fc then
        fc:_recalculateDimen()
        fc:switchItemTable(nil, nil, fc.prev_itemnumber, { dummy = "" }) -- dummy itemmatch to draw focus
        if cleanup then                                                  -- clean instance properties we may have set
            if fc.showFileDialog_orig then
                -- remove our showFileDialog that extended file_dialog with new buttons
                fc.showFileDialog = fc.showFileDialog_orig
                fc.showFileDialog_orig = nil
                fc.showFileDialog_ours = nil
                FileManager.instance:reinit(fc.path, fc.prev_focused_path)
            end
        end
        -- if filemanager_display_mode then
        if curr_display_modes["filemanager"] then
            if post_init then
                self.ui:setupLayout()
                -- FileBrowser was initialized in classic mode, but we changed
                -- display mode: items per page may have changed, and we want
                -- to re-position on the focused_file
                fc:_recalculateDimen()
                fc:changeToPath(fc.path, fc.prev_focused_path)
            else
                fc:updateItems()
            end
        else -- classic file_chooser needs this for a full redraw
            fc:refreshPath()
        end
    end
end

function CoverBrowser:setDisplayMode(display_mode)
    self:setupFileManagerDisplayMode(display_mode)
    if BookInfoManager:getSetting("unified_display_mode") then
        CoverBrowser.setupWidgetDisplayMode("history", display_mode)
        CoverBrowser.setupWidgetDisplayMode("collections", display_mode)
    end
end

function CoverBrowser:setupFileManagerDisplayMode(display_mode)
    if not DISPLAY_MODES[display_mode] then
        display_mode = nil -- unknown mode, fallback to classic
    end
    -- if init_done and display_mode == filemanager_display_mode then -- no change
    if init_done and display_mode == curr_display_modes["filemanager"] then -- no change
        return
    end
    if init_done then -- save new mode in db
        BookInfoManager:saveSetting(display_mode_db_names["filemanager"], display_mode)
    end
    -- remember current mode in module variable
    -- filemanager_display_mode = display_mode
    curr_display_modes["filemanager"] = display_mode
    logger.dbg("CoverBrowser: setting FileManager display mode to:", display_mode or "classic")

    -- init Mosaic and List grid dimensions (in Classic mode used in the settings menu)
    CoverBrowser.initGrid(FileChooser, display_mode)

    if not init_done and not display_mode then
        return -- starting in classic mode, nothing to patch
    end


    if not display_mode then -- classic mode
        CoverBrowser.removeFileDialogButtons("filesearcher")
        _modified_widgets["filesearcher"].updateItemTable = _updateItemTable_orig_funcs["filesearcher"]
        -- Put back original methods
        FileChooser.updateItems = _FileChooser_updateItems_orig
        FileChooser.onCloseWidget = _FileChooser_onCloseWidget_orig
        FileChooser._recalculateDimen = _FileChooser__recalculateDimen_orig
        CoverBrowser.removeFileDialogButtons("filemanager")
        FileChooser.genItemTable = _FileChooser_genItemTable_orig
        FileManager.tapPlus = _FileManager_tapPlus_orig
        FileManager.setupLayout = _FileManager_setupLayout_orig
        FileManager.updateTitleBarPath = _FileManager_updateTitleBarPath_orig
        Menu.init = _Menu_init_orig
        Menu.updatePageInfo = _Menu_updatePageInfo_orig
        -- Also clean-up what we added, even if it does not bother original code
        FileChooser.updateCache = nil
        FileChooser._updateItemsBuildUI = nil
        FileChooser._do_cover_images = nil
        FileChooser._do_filename_only = nil
        FileChooser._do_hint_opened = nil
        FileChooser._do_center_partial_rows = nil
        self:refreshFileManagerInstance(true, true)
        return
    end

    CoverBrowser.addFileDialogButtons("filesearcher")
    _modified_widgets["filesearcher"].updateItemTable = CoverBrowser.getUpdateItemTableFunc(display_mode)
    -- In both mosaic and list modes, replace original methods with those from
    -- our generic CoverMenu
    local CoverMenu = require("covermenu")
    FileChooser.updateCache = CoverMenu.updateCache
    FileChooser.updateItems = CoverMenu.updateItems
    FileChooser.onCloseWidget = CoverMenu.onCloseWidget
    CoverBrowser.addFileDialogButtons("filemanager")
    if FileChooser.display_mode_type == "mosaic" then
        -- Replace some other original methods with those from our MosaicMenu
        local MosaicMenu = require("mosaicmenu")
        FileChooser._recalculateDimen = MosaicMenu._recalculateDimen
        FileChooser._updateItemsBuildUI = MosaicMenu._updateItemsBuildUI
        -- Set MosaicMenu behaviour:
        FileChooser._do_cover_images = display_mode ~= "mosaic_text"
        FileChooser._do_hint_opened = true -- dogear at bottom
        -- Don't have "../" centered in empty directories
        FileChooser._do_center_partial_rows = false
    elseif FileChooser.display_mode_type == "list" then
        -- Replace some other original methods with those from our ListMenu
        local ListMenu = require("listmenu")
        FileChooser._recalculateDimen = ListMenu._recalculateDimen
        FileChooser._updateItemsBuildUI = ListMenu._updateItemsBuildUI
        -- Set ListMenu behaviour:
        FileChooser._do_cover_images = display_mode ~= "list_only_meta"
        FileChooser._do_filename_only = display_mode == "list_image_filename"
        FileChooser._do_hint_opened = true -- dogear at bottom
    end

    -- Replace this FileManager method with the one from CoverMenu
    -- (but first, make the original method saved here as local available
    -- to CoverMenu)
    CoverMenu._FileManager_tapPlus_orig = _FileManager_tapPlus_orig
    FileManager.tapPlus = CoverMenu.tapPlus

    CoverMenu._FileChooser_genItemTable_orig = _FileChooser_genItemTable_orig
    FileChooser.genItemTable = CoverMenu.genItemTable

    CoverMenu._FileManager_setupLayout_orig = _FileManager_setupLayout_orig
    FileManager.setupLayout = CoverMenu.setupLayout

    CoverMenu._FileManager_updateTitleBarPath_orig = _FileManager_updateTitleBarPath_orig
    FileManager.updateTitleBarPath = CoverMenu.updateTitleBarPath


    CoverMenu._Menu_init_orig = _Menu_init_orig
    CoverMenu._Menu_updatePageInfo_orig = _Menu_updatePageInfo_orig

    Menu.init = CoverMenu.menuInit
    Menu.updatePageInfo = CoverMenu.updatePageInfo

    if init_done then
        self:refreshFileManagerInstance(false, true)
    else
        -- If KOReader has started directly to FileManager, the FileManager
        -- instance is being init()'ed and there is no FileManager.instance yet,
        -- but there'll be one at next tick.
        UIManager:nextTick(function()
            self:refreshFileManagerInstance(false, true)
        end)
    end
end

function CoverBrowser.setupWidgetDisplayMode(widget_id, display_mode)
    if display_mode == true then -- init
        display_mode = BookInfoManager:getSetting(display_mode_db_names[widget_id])
    end
    if not DISPLAY_MODES[display_mode] then
        display_mode = nil                                              -- unknown mode, fallback to classic
    end
    if init_done and display_mode == curr_display_modes[widget_id] then -- no change
        return
    end
    if init_done then -- save new mode in db
        BookInfoManager:saveSetting(display_mode_db_names[widget_id], display_mode)
    end
    -- remember current mode in module variable
    curr_display_modes[widget_id] = display_mode
    logger.dbg("CoverBrowser: setting display mode:", widget_id, display_mode or "classic")

    if not init_done and not display_mode then
        return -- starting in classic mode, nothing to patch
    end

    -- We only need to replace one method
    local widget = _modified_widgets[widget_id]
    if display_mode then
        CoverBrowser.addFileDialogButtons(widget_id)
        widget.updateItemTable = CoverBrowser.getUpdateItemTableFunc(display_mode)
    else -- classic mode
        CoverBrowser.removeFileDialogButtons(widget_id)
        widget.updateItemTable = _updateItemTable_orig_funcs[widget_id]
    end
end

function CoverBrowser.getUpdateItemTableFunc(display_mode)
    return function(this, ...)
        -- 'this' here is the single widget instance
        -- The widget has just created a new instance of BookList as 'booklist_menu'
        -- at each display of the widget. Soon after instantiation, this method
        -- is called. The first time it is called, we replace some methods.
        local booklist_menu = this.booklist_menu
        local widget_id = booklist_menu.name

        if not booklist_menu._coverbrowser_overridden then
            booklist_menu._coverbrowser_overridden = true

            -- In both mosaic and list modes, replace original methods with those from
            -- our generic CoverMenu
            local CoverMenu = require("covermenu")
            booklist_menu.updateItems = CoverMenu.updateItems
            booklist_menu.onCloseWidget = CoverMenu.onCloseWidget

            CoverBrowser.initGrid(booklist_menu, display_mode)
            if booklist_menu.display_mode_type == "mosaic" then
                -- Replace some other original methods with those from our MosaicMenu
                local MosaicMenu = require("mosaicmenu")
                booklist_menu._recalculateDimen = MosaicMenu._recalculateDimen
                booklist_menu._updateItemsBuildUI = MosaicMenu._updateItemsBuildUI
                -- Set MosaicMenu behaviour:
                booklist_menu._do_cover_images = display_mode ~= "mosaic_text"
                booklist_menu._do_center_partial_rows = true -- nicer looking when few elements
            elseif booklist_menu.display_mode_type == "list" then
                -- Replace some other original methods with those from our ListMenu
                local ListMenu = require("listmenu")
                booklist_menu._recalculateDimen = ListMenu._recalculateDimen
                booklist_menu._updateItemsBuildUI = ListMenu._updateItemsBuildUI
                -- Set ListMenu behaviour:
                booklist_menu._do_cover_images = display_mode ~= "list_only_meta"
                booklist_menu._do_filename_only = display_mode == "list_image_filename"
            end

            if widget_id == "history" then
                booklist_menu._do_hint_opened = BookInfoManager:getSetting("history_hint_opened")
            elseif widget_id == "collections" then
                booklist_menu._do_hint_opened = BookInfoManager:getSetting("collections_hint_opened")
            else -- "filesearcher"
                booklist_menu._do_hint_opened = true
            end
        end

        -- And do now what the original does
        _updateItemTable_orig_funcs[widget_id](this, ...)
    end
end

function CoverBrowser:getBookInfo(file)
    return BookInfoManager:getBookInfo(file)
end

function CoverBrowser.getDocProps(file)
    return BookInfoManager:getDocProps(file)
end

function CoverBrowser:onInvalidateMetadataCache(file)
    BookInfoManager:deleteBookInfo(file)
    return true
end

function CoverBrowser:onDocSettingsItemsChanged(file, doc_settings)
    local status -- nil to wipe the covermenu book cache
    if doc_settings then
        status = doc_settings.summary and doc_settings.summary.status
        if not status then return end -- changes not for us
    end
    if curr_display_modes["filemanager"] and self.ui.file_chooser then
        self.ui.file_chooser:updateCache(file, status)
    end
    if curr_display_modes["history"] and self.ui.history and self.ui.history.hist_menu then
        self.ui.history.hist_menu:updateCache(file, status)
    end
    if curr_display_modes["collections"] and self.ui.collections and self.ui.collections.coll_menu then
        self.ui.collections.coll_menu:updateCache(file, status)
    end
end

function CoverBrowser:extractBooksInDirectory(path)
    local Trapper = require("ui/trapper")
    Trapper:wrap(function()
        BookInfoManager:extractBooksInDirectory(path)
    end)
end

-- Gesturable: Increase items per page (makes items smaller)
function CoverBrowser:onIncreaseItemsPerPage()
    local fc = self.ui.file_chooser
    local display_mode = BookInfoManager:getSetting("filemanager_display_mode")
    -- list modes
    if display_mode == "list_image_meta" or display_mode == "list_only_meta" then
        local files_per_page = fc.files_per_page or default_items_per_page
        files_per_page = math.min(files_per_page + 1, max_items_per_page)
        BookInfoManager:saveSetting("files_per_page", files_per_page)
        FileChooser.files_per_page = files_per_page
        -- grid mode
    elseif display_mode == "mosaic_image" then
        local Device = require("device")
        local Screen = Device.screen
        local portrait_mode = Screen:getWidth() <= Screen:getHeight()
        if portrait_mode then
            local portrait_cols = BookInfoManager:getSetting("nb_cols_portrait") or default_cols
            local portrait_rows = BookInfoManager:getSetting("nb_rows_portrait") or default_rows
            if portrait_cols == portrait_rows then
                fc.nb_cols_portrait = math.min(portrait_cols + 1, max_cols)
                fc.nb_rows_portrait = math.min(portrait_rows + 1, max_rows)
                BookInfoManager:saveSetting("nb_cols_portrait", fc.nb_cols_portrait)
                BookInfoManager:saveSetting("nb_rows_portrait", fc.nb_rows_portrait)
                FileChooser.nb_cols_portrait = fc.nb_cols_portrait
                FileChooser.nb_rows_portrait = fc.nb_rows_portrait
            end
        end
        if not portrait_mode then
            local landscape_cols = BookInfoManager:getSetting("nb_cols_landscape") or default_cols
            local landscape_rows = BookInfoManager:getSetting("nb_rows_landscape") or default_rows
            if landscape_cols == landscape_rows then
                fc.nb_cols_landscape = math.min(landscape_cols + 1, max_cols)
                fc.nb_rows_landscape = math.min(landscape_rows + 1, max_rows)
                BookInfoManager:saveSetting("nb_cols_landscape", fc.nb_cols_landscape)
                BookInfoManager:saveSetting("nb_rows_landscape", fc.nb_rows_landscape)
                FileChooser.nb_cols_landscape = fc.nb_cols_landscape
                FileChooser.nb_rows_landscape = fc.nb_rows_landscape
            end
        end
    end
    fc.no_refresh_covers = nil
    fc:updateItems()
end

-- Gesturable: Decrease items per page (makes items bigger)
function CoverBrowser:onDecreaseItemsPerPage()
    local fc = self.ui.file_chooser
    local display_mode = BookInfoManager:getSetting("filemanager_display_mode")
    -- list modes
    if display_mode == "list_image_meta" or display_mode == "list_only_meta" then
        local files_per_page = fc.files_per_page or default_items_per_page
        files_per_page = math.max(files_per_page - 1, min_items_per_page)
        BookInfoManager:saveSetting("files_per_page", files_per_page)
        FileChooser.files_per_page = files_per_page
        -- grid mode
    elseif display_mode == "mosaic_image" then
        local Device = require("device")
        local Screen = Device.screen
        local portrait_mode = Screen:getWidth() <= Screen:getHeight()
        if portrait_mode then
            local portrait_cols = BookInfoManager:getSetting("nb_cols_portrait") or default_cols
            local portrait_rows = BookInfoManager:getSetting("nb_rows_portrait") or default_rows
            if portrait_cols == portrait_rows then
                fc.nb_cols_portrait = math.max(portrait_cols - 1, min_cols)
                fc.nb_rows_portrait = math.max(portrait_rows - 1, min_rows)
                BookInfoManager:saveSetting("nb_cols_portrait", fc.nb_cols_portrait)
                BookInfoManager:saveSetting("nb_rows_portrait", fc.nb_rows_portrait)
                FileChooser.nb_cols_portrait = fc.nb_cols_portrait
                FileChooser.nb_rows_portrait = fc.nb_rows_portrait
            end
        end
        if not portrait_mode then
            local landscape_cols = BookInfoManager:getSetting("nb_cols_landscape") or default_cols
            local landscape_rows = BookInfoManager:getSetting("nb_rows_landscape") or default_rows
            if landscape_cols == landscape_rows then
                fc.nb_cols_landscape = math.max(landscape_cols - 1, min_cols)
                fc.nb_rows_landscape = math.max(landscape_rows - 1, min_rows)
                BookInfoManager:saveSetting("nb_cols_landscape", fc.nb_cols_landscape)
                BookInfoManager:saveSetting("nb_rows_landscape", fc.nb_rows_landscape)
                FileChooser.nb_cols_landscape = fc.nb_cols_landscape
                FileChooser.nb_rows_landscape = fc.nb_rows_landscape
            end
        end
    end
    fc.no_refresh_covers = nil
    fc:updateItems()
end

return CoverBrowser
