--[[
    Project: Title builds upon the work in the Cover Browser plugin to dramatically
    alter the way list and mosaic views appear.

    Additional provided files must be installed for this plugin to work. Please
    read the installation steps at the link below:

    https://github.com/joshuacant/ProjectTitle/wiki/Installation
--]]

local DataStorage = require("datastorage")
local logger = require("logger")
local Version = require("version")
local ptutil = require("ptutil")
local util = require("util")
local ptdbg = require("ptdbg")

local data_dir = DataStorage:getDataDir()
logger.info(ptdbg.logprefix, "Checking requirements in '" .. data_dir .. "'")

-- Disable this entire plugin if: fonts missing
local font1_missing = true
if util.fileExists(data_dir .. "/fonts/source/SourceSans3-Regular.ttf") then
    font1_missing = false
else
    logger.warn(ptdbg.logprefix, "Font1 missing")
end
local font2_missing = true
if util.fileExists(data_dir .. "/fonts/source/SourceSerif4-Regular.ttf") then
    font2_missing = false
else
    logger.warn(ptdbg.logprefix, "Font2 missing")
end
local font3_missing = true
if util.fileExists(data_dir .. "/fonts/source/SourceSerif4-BoldIt.ttf") then
    font3_missing = false
else
    logger.warn(ptdbg.logprefix, "Font3 missing")
end

-- Disable this entire plugin if: icons missing
local icons_missing = true
if util.fileExists(data_dir .. "/icons/hero.svg") then
    icons_missing = false -- check for one icon and assume the rest are there too
else
    logger.warn(ptdbg.logprefix, "Icons missing")
end

-- Disable this entire plugin if: Cover Browser is enabled
local plugins_disabled = G_reader_settings:readSetting("plugins_disabled")
if type(plugins_disabled) ~= "table" then
    plugins_disabled = {}
end
local coverbrowser_plugin = true
if plugins_disabled["coverbrowser"] == true then
    coverbrowser_plugin = false
else
    logger.warn(ptdbg.logprefix, "CoverBrowser enabled")
end
--[[
    Directly editing this file to disable the version check is no longer required,
    please use the new method at the link below:

    https://github.com/joshuacant/ProjectTitle/wiki/Use-With-Nightly-KOReader-Builds
--]]
local safe_version = 202504000000
local cv_int, cv_hash = Version:getNormalizedCurrentVersion()
local version_unsafe = true
if (cv_int == safe_version or util.fileExists(data_dir .. "/settings/pt-skipversioncheck.txt")) then
    version_unsafe = false
else
    logger.warn(ptdbg.logprefix, "Version not safe ", tostring(cv_int))
    if cv_int - safe_version < 1000 then
        logger.warn(ptdbg.logprefix, "This is a KOReader nightly build, not the official release")
    end
end

if font1_missing or font2_missing or font3_missing or icons_missing or coverbrowser_plugin or version_unsafe then
    logger.warn(ptdbg.logprefix, "Refusing to load the plugin")
    return { disabled = true, }
end
logger.info(ptdbg.logprefix, "All tests passed, loading into KOReader ver", tostring(cv_int))

-- carry on...
local BookStatusWidget = require("ui/widget/bookstatuswidget")
local AltBookStatusWidget = require("altbookstatuswidget")
local FileChooser = require("ui/widget/filechooser")
local FileManager = require("apps/filemanager/filemanager")
local FileManagerHistory = require("apps/filemanager/filemanagerhistory")
local FileManagerCollection = require("apps/filemanager/filemanagercollection")
local FileManagerFileSearcher = require("apps/filemanager/filemanagerfilesearcher")
local FFIUtil = require("ffi/util")
local Dispatcher = require("dispatcher")
local Menu = require("ui/widget/menu")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("l10n.gettext")
local T = require("ffi/util").template
local BookInfoManager = require("bookinfomanager")

-- We need to save the original methods early here as locals.
-- For some reason, saving them as attributes in init() does not allow
-- us to get back to classic mode
local _FileChooser__recalculateDimen_orig = FileChooser._recalculateDimen
local _FileChooser_updateItems_orig = FileChooser.updateItems
local _FileChooser_onCloseWidget_orig = FileChooser.onCloseWidget
local _FileChooser_genItemTable_orig = FileChooser.genItemTable         -- additional
local _FileManager_setupLayout_orig = FileManager.setupLayout           -- additional
local _Menu_init_orig = Menu.init                                       -- additional
local _Menu_updatePageInfo_orig = Menu.updatePageInfo                   -- additional

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

-- Available display modes
local DISPLAY_MODES = {
    -- nil or ""            -- classic : filename only
    mosaic_image    = true, -- 3x3 grid covers with images
    list_image_meta = true, -- image with metadata (title/authors)
    list_only_meta  = true, -- metadata with no image
}
local display_mode_db_names = {
    filemanager = "filemanager_display_mode",
    history     = "history_display_mode",
    collections = "collection_display_mode",
}
-- Store some states as locals, to be permanent across instantiations
local init_done = false
local curr_display_modes = {
    filemanager = false, -- not initialized yet
    history     = false, -- not initialized yet
    collections = false, -- not initialized yet
}
local series_mode = nil  -- defaults to not display series

local CoverBrowser = WidgetContainer:extend {
    name = "coverbrowserclean",
    modes = {
        { _("Cover List"),    "list_image_meta" },
        { _("Cover Grid"),    "mosaic_image" },
        { _("Details List"),  "list_only_meta" },
        { _("Filenames List") },
    },
}

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
    Dispatcher:registerAction("dec_items_pp", {
        category = "none",
        event = "DecreaseItemsPerPage",
        title = _("Project: Title") .. " - " .. _("Decrease Items Per Page"),
        filemanager = true,
        separator = false,
    })
    Dispatcher:registerAction("inc_items_pp", {
        category = "none",
        event = "IncreaseItemsPerPage",
        title = _("Project: Title") .. " - " .. _("Increase Items Per Page"),
        filemanager = true,
        separator = false,
    })
    Dispatcher:registerAction("switch_grid", {
        category = "none",
        event = "SwitchToCoverGrid",
        title = _("Project: Title") .. " - " .. _("Cover Grid"),
        filemanager = true,
        separator = false,
    })
    Dispatcher:registerAction("switch_list", {
        category = "none",
        event = "SwitchToCoverList",
        title = _("Project: Title") .. " - " .. _("Cover List"),
        filemanager = true,
        separator = false,
    })
end

function CoverBrowser:init()
    if not self.ui.document then -- FileManager menu only
        self.ui.menu:registerToMainMenu(self)
    end

    if init_done then -- things already patched according to current modes
        return
    end

    -- on first ever run and occasionally afterward it will be necessary to create
    -- new settings keys in the 'config' table and some of them require restarting
    -- koreader to fully apply.
    local restart_needed = false
    if not G_reader_settings:isTrue("aaaProjectTitle_initial_default_setup_done2") then
        logger.info(ptdbg.logprefix, "Initalizing settings")
        -- Set up default display modes on first launch
        -- but only if no display mode has been set yet
        if not BookInfoManager:getSetting("filemanager_display_mode")
            and not BookInfoManager:getSetting("history_display_mode") then
            BookInfoManager:saveSetting("filemanager_display_mode", "list_image_meta")
            BookInfoManager:saveSetting("history_display_mode", "list_image_meta")
            BookInfoManager:saveSetting("collection_display_mode", "list_image_meta")
        end
        -- initalize settings with their defaults
        BookInfoManager:saveSetting("config_version", "1")
        BookInfoManager:saveSetting("series_mode", "series_in_separate_line")
        BookInfoManager:saveSetting("hide_file_info", true)
        BookInfoManager:saveSetting("unified_display_mode", true)
        BookInfoManager:saveSetting("show_progress_in_mosaic", true)
        BookInfoManager:saveSetting("autoscan_on_eject", false)
        G_reader_settings:makeTrue("aaaProjectTitle_initial_default_setup_done2")
        restart_needed = true
    end

    -- initalize additional settings with their defaults
    if BookInfoManager:getSetting("config_version") == nil then
        -- catch installs done before setting versioning
        logger.info(ptdbg.logprefix, "Migrating settings to version 1")
        BookInfoManager:saveSetting("config_version", "1")
    end
    if BookInfoManager:getSetting("config_version") == 1 then
        logger.info(ptdbg.logprefix, "Migrating settings to version 2")
        BookInfoManager:saveSetting("disable_auto_foldercovers", false)
        BookInfoManager:saveSetting("force_max_progressbars", false)
        BookInfoManager:saveSetting("opened_at_top_of_library", true)
        BookInfoManager:saveSetting("reverse_footer", false)
        BookInfoManager:saveSetting("use_custom_bookstatus", true)
        BookInfoManager:saveSetting("replace_footer_text", false)
        BookInfoManager:saveSetting("show_name_grid_folders", true)
        BookInfoManager:saveSetting("config_version", "2")
        restart_needed = true
    end
    if BookInfoManager:getSetting("config_version") == 2 then
        logger.info(ptdbg.logprefix, "Migrating settings to version 3")
        BookInfoManager:saveSetting("force_no_progressbars", false)
        BookInfoManager:saveSetting("config_version", "3")
    end
    if BookInfoManager:getSetting("config_version") == 3 then
        logger.info(ptdbg.logprefix, "Migrating settings to version 4")
        BookInfoManager:saveSetting("force_focus_indicator", false)
        BookInfoManager:saveSetting("use_stacked_foldercovers", false)
        BookInfoManager:saveSetting("config_version", "4")
    end

    -- restart if needed
    if restart_needed then
        logger.info(ptdbg.logprefix, "Restarting KOReader to apply settings")
        UIManager:restartKOReader()
        FFIUtil.sleep(2)
    end

    self:setupFileManagerDisplayMode(BookInfoManager:getSetting("filemanager_display_mode"))
    CoverBrowser.setupWidgetDisplayMode("history", true)
    CoverBrowser.setupWidgetDisplayMode("collections", true)
    series_mode = BookInfoManager:getSetting("series_mode")

    if BookInfoManager:getSetting("use_custom_bookstatus") then
        BookStatusWidget.genHeader = AltBookStatusWidget.genHeader
        BookStatusWidget.getStatusContent = AltBookStatusWidget.getStatusContent
        BookStatusWidget.genBookInfoGroup = AltBookStatusWidget.genBookInfoGroup
        BookStatusWidget.genSummaryGroup = AltBookStatusWidget.genSummaryGroup
    end

    local home_dir = G_reader_settings:readSetting("home_dir")
    if home_dir then logger.info(ptdbg.logprefix, "Home directory is set to: ", home_dir) end
    if home_dir and util.pathExists(home_dir) and BookInfoManager:getSetting("autoscan_on_eject") then
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
    local fc = self.ui.file_chooser
    for i, v in ipairs(self.modes) do
        local text, mode = unpack(v)
        sub_item_table[i] = {
            text = text,
            checked_func = function()
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
        separator = true,
        enabled_func = function()
            return not BookInfoManager:getSetting("unified_display_mode")
        end,
        sub_item_table = collection_sub_item_table,
    })
    table.insert(sub_item_table, {
        text = _("Advanced settings"),
        sub_item_table = {
            -- {
            --     text = _("Show focus indicator on touchscreen devices"),
            --     checked_func = function() return BookInfoManager:getSetting("force_focus_indicator") end,
            --     callback = function()
            --         BookInfoManager:toggleSetting("force_focus_indicator")
            --     end,
            -- },
            {
                text = _("Items per page"),
                sub_item_table = {
                    {
                        text_func = function()
                            return _("Portrait cover grid mode") .. T(_(": %1 × %2"), fc.nb_cols_portrait,
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
                            return _("Landscape cover grid mode") .. T(_(": %1 × %2"), fc.nb_cols_landscape,
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
                            return _("List modes") .. T(_(": %1"),
                                fc.files_per_page or default_items_per_page)
                        end,
                        callback = function()
                            local files_per_page = fc.files_per_page or default_items_per_page
                            local SpinWidget = require("ui/widget/spinwidget")
                            local widget = SpinWidget:new {
                                title_text = _("List modes"),
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
                    },
                },
            },
            {
                text = _("Folder display"),
                sub_item_table = {
                    {
                        text = _("Auto-generate cover images from books"),
                        checked_func = function()
                            return not BookInfoManager:getSetting("disable_auto_foldercovers")
                        end,
                        callback = function()
                            BookInfoManager:toggleSetting("disable_auto_foldercovers")
                            fc:updateItems()
                        end,
                    },
                    {
                        text = _("Show auto-generated cover images as stack instead of grid"),
                        enabled_func = function()
                            return not (BookInfoManager:getSetting("disable_auto_foldercovers"))
                        end,
                        checked_func = function() return BookInfoManager:getSetting("use_stacked_foldercovers") end,
                        callback = function()
                            BookInfoManager:toggleSetting("use_stacked_foldercovers")
                            fc:updateItems(1, true)
                        end,
                    },
                    {
                        text = _("Overlay name and details in cover grid"),
                        checked_func = function() return BookInfoManager:getSetting("show_name_grid_folders") end,
                        callback = function()
                            BookInfoManager:toggleSetting("show_name_grid_folders")
                            fc:updateItems(1, true)
                        end,
                    },
                },
            },
            {
                text = _("Book display"),
                sub_item_table = {
                    {
                        text = _("Show file info instead of pages or progress %"),
                        checked_func = function() return not BookInfoManager:getSetting("hide_file_info") end,
                        callback = function()
                            BookInfoManager:toggleSetting("hide_file_info")
                            fc:updateItems(1, true)
                        end,
                    },
                    {
                        text = _("Show pages read instead of progress %"),
                        enabled_func = function()
                            return not (
                                    not BookInfoManager:getSetting("hide_file_info")
                                )
                        end,
                        checked_func = function() return BookInfoManager:getSetting("show_pages_read_as_progress") end,
                        callback = function()
                            BookInfoManager:toggleSetting("show_pages_read_as_progress")
                            fc:updateItems(1, true)
                        end,
                    },
                    {
                        text = _("Show progress % instead of progress bars"),
                        enabled_func = function()
                            return not (
                                    BookInfoManager:getSetting("show_pages_read_as_progress") or
                                    not BookInfoManager:getSetting("hide_file_info")
                                )
                        end,
                        checked_func = function() return BookInfoManager:getSetting("force_no_progressbars") end,
                        callback = function()
                            BookInfoManager:toggleSetting("force_no_progressbars")
                            fc:updateItems(1, true)
                        end,
                    },
                    {
                        text = _("Always show maximum length progress bars"),
                        separator = true,
                        enabled_func = function()
                            return not (
                                    BookInfoManager:getSetting("force_no_progressbars") or
                                    BookInfoManager:getSetting("show_pages_read_as_progress") or
                                    not BookInfoManager:getSetting("hide_file_info")
                                )
                        end,
                        checked_func = function() return BookInfoManager:getSetting("force_max_progressbars") end,
                        callback = function()
                            BookInfoManager:toggleSetting("force_max_progressbars")
                            fc:updateItems(1, true)
                        end,
                    },
                    {
                        text = _("Show series"),
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
                        text = _("Use custom book status screen"),
                        checked_func = function() return BookInfoManager:getSetting("use_custom_bookstatus") end,
                        callback = function()
                            BookInfoManager:toggleSetting("use_custom_bookstatus")
                            UIManager:askForRestart()
                        end,
                    },
                },
            },
            {
                text = _("Footer"),
                sub_item_table = {
                    {
                        text = _("Replace folder name with device info"),
                        checked_func = function() return BookInfoManager:getSetting("replace_footer_text") end,
                        callback = function()
                            BookInfoManager:toggleSetting("replace_footer_text")
                            UIManager:askForRestart()
                        end,
                    },
                    {
                        text = _("Show page controls in left corner"),
                        checked_func = function() return BookInfoManager:getSetting("reverse_footer") end,
                        callback = function()
                            BookInfoManager:toggleSetting("reverse_footer")
                            UIManager:askForRestart()
                        end,
                    },
                },
            },
            {
                text = _("Library mode"),
                sub_item_table = {
                    {
                        text = _("Show opened books first"),
                        checked_func = function()
                            return BookInfoManager:getSetting("opened_at_top_of_library")
                        end,
                        callback = function()
                            BookInfoManager:toggleSetting("opened_at_top_of_library")
                            -- can't figure out how to refresh the item table from here
                            -- but a restart gets the job done
                            UIManager:askForRestart()
                        end,
                    },
                },
            },
            {
                text = _("Cache database"),
                sub_item_table = {
                    {
                        text = _("Scan home folder for new books automatically"),
                        checked_func = function() return BookInfoManager:getSetting("autoscan_on_eject") end,
                        callback = function()
                            BookInfoManager:toggleSetting("autoscan_on_eject")
                            UIManager:askForRestart()
                        end,
                    },
                    {
                        text = _("Prune cache"),
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
                        text = _("Empty cache"),
                        keep_menu_open = false,
                        callback = function()
                            local ConfirmBox = require("ui/widget/confirmbox")
                            UIManager:close(self.file_dialog)
                            UIManager:show(ConfirmBox:new {
                                text = _("Are you sure that you want to delete cover and metadata cache?"),
                                ok_text = _("Empty cache"),
                                ok_callback = function()
                                    BookInfoManager:deleteDb()
                                    BookInfoManager:compactDb() -- compact
                                    local InfoMessage = require("ui/widget/infomessage")
                                    UIManager:show(InfoMessage:new { text = _("Cache emptied.") })
                                end
                            })
                        end,
                        separator = true,
                    },
                    {
                        text_func = function() -- add current db size to menu text
                            local sstr = BookInfoManager:getDbSize()
                            return _("Cache size") .. ": " .. sstr
                        end,
                        keep_menu_open = true,
                        callback = function() end, -- no callback, only for information
                    },
                },
            },
        },
    })
    menu_items.filemanager_display_mode = {
        text = _("Project: Title settings"),
        sub_item_table = sub_item_table,
        separator = true,
    }
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

function CoverBrowser:refreshFileManagerInstance()
    local fc = self.ui.file_chooser
    if fc then
        fc:_recalculateDimen()
        fc:switchItemTable(nil, nil, fc.prev_itemnumber, { dummy = "" }) -- dummy itemmatch to draw focus
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
        display_mode = nil                                                  -- unknown mode, fallback to classic
    end
    if init_done and display_mode == curr_display_modes["filemanager"] then -- no change
        return
    end
    if init_done then -- save new mode in db
        BookInfoManager:saveSetting(display_mode_db_names["filemanager"], display_mode)
    end
    -- remember current mode in module variable
    curr_display_modes["filemanager"] = display_mode
    logger.dbg(ptdbg.logprefix, "Setting FileManager display mode to:", display_mode or "classic")

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
        FileManager.setupLayout = _FileManager_setupLayout_orig
        Menu.init = _Menu_init_orig
        Menu.updatePageInfo = _Menu_updatePageInfo_orig
        -- Also clean-up what we added, even if it does not bother original code
        FileChooser._updateItemsBuildUI = nil
        FileChooser._do_cover_images = nil
        FileChooser._do_filename_only = nil
        FileChooser._do_hint_opened = nil
        FileChooser._do_center_partial_rows = nil
        self:refreshFileManagerInstance()
        return
    end

    CoverBrowser.addFileDialogButtons("filesearcher")
    _modified_widgets["filesearcher"].updateItemTable = CoverBrowser.getUpdateItemTableFunc(display_mode)
    -- In both mosaic and list modes, replace original methods with those from
    -- our generic CoverMenu
    local CoverMenu = require("covermenu")
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

    CoverMenu._FileChooser_genItemTable_orig = _FileChooser_genItemTable_orig
    FileChooser.genItemTable = CoverMenu.genItemTable

    CoverMenu._FileManager_setupLayout_orig = _FileManager_setupLayout_orig
    FileManager.setupLayout = CoverMenu.setupLayout

    CoverMenu._Menu_init_orig = _Menu_init_orig
    CoverMenu._Menu_updatePageInfo_orig = _Menu_updatePageInfo_orig

    Menu.init = CoverMenu.menuInit
    Menu.updatePageInfo = CoverMenu.updatePageInfo

    if init_done then
        self:refreshFileManagerInstance()
    else
        -- If KOReader has started directly to FileManager, the FileManager
        -- instance is being init()'ed and there is no FileManager.instance yet,
        -- but there'll be one at next tick.
        UIManager:nextTick(function()
            self:refreshFileManagerInstance()
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
    logger.dbg(ptdbg.logprefix, "Setting display mode:", widget_id, display_mode or "classic")

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
                booklist_menu._do_center_partial_rows = false -- nicer looking when few elements
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

-- Gesturable: Switch to Cover Grid display mode
function CoverBrowser:onSwitchToCoverGrid()
    self:setDisplayMode("mosaic_image")
end

-- Gesturable: Switch to Cover List display mode
function CoverBrowser:onSwitchToCoverList()
    self:setDisplayMode("list_image_meta")
end

return CoverBrowser
