local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local BookList = require("ui/widget/booklist")
local ButtonDialog = require("ui/widget/buttondialog")
local DocSettings = require("docsettings")
local DocumentRegistry = require("document/documentregistry")
local FileChooser = require("ui/widget/filechooser")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Menu = require("ui/widget/menu")
local OverlapGroup = require("ui/widget/overlapgroup")
local Font = require("ui/font")
local FileManager = require("apps/filemanager/filemanager")
local FileManagerBookInfo = require("apps/filemanager/filemanagerbookinfo")
local FileManagerConverter = require("apps/filemanager/filemanagerconverter")
local FileManagerShortcuts = require("apps/filemanager/filemanagershortcuts")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local UIManager = require("ui/uimanager")
local LineWidget = require("ui/widget/linewidget")
local logger = require("logger")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("titlebar")
local FrameContainer = require("ui/widget/container/framecontainer")
local FileManagerMenu = require("apps/filemanager/filemanagermenu")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local Device = require("device")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local util = require("util")
local time = require("ui/time")
local ffiUtil = require("ffi/util")
local C_ = _.pgettext

local Screen = Device.screen
local BookInfoManager = require("bookinfomanager")

-- This is a kind of "base class" for both MosaicMenu and ListMenu.
-- It implements the common code shared by these, mostly the non-UI
-- work : the updating of items and the management of backgrouns jobs.
--
-- Here are defined the common overriden methods of Menu:
--    :updateItems(select_number)
--    :onCloseWidget()
--
-- MosaicMenu or ListMenu should implement specific UI methods:
--    :_recalculateDimen()
--    :_updateItemsBuildUI()
-- This last method is called in the middle of :updateItems() , and
-- should fill self.item_group with some specific UI layout. It may add
-- not found item to self.items_to_update for us to update() them
-- regularly.

-- Store these as local, to be set by some object and re-used by
-- another object (as we plug the methods below to different objects,
-- we can't store them in 'self' if we want another one to use it)
local current_path = nil
local current_cover_specs = false
local is_pathchooser = false
local meta_browse_mode = false

local good_serif = "source/SourceSerif4-Regular.ttf"

-- Do some collectgarbage() every few drawings
local NB_DRAWINGS_BETWEEN_COLLECTGARBAGE = 5
local nb_drawings_since_last_collectgarbage = 0

-- Simple holder of methods that will replace those
-- in the real Menu class or instance
local CoverMenu = {}

-- function CoverMenu:updateCache(file, status, do_create, pages)
--     if do_create then -- create new cache entry if absent
--         if self.cover_info_cache[file] then return end
--         local doc_settings = DocSettings:open(file)
--         -- We can get nb of page in the new 'doc_pages' setting, or from the old 'stats.page'
--         local doc_pages = doc_settings:readSetting("doc_pages")
--         if doc_pages then
--             pages = doc_pages
--         else
--             local stats = doc_settings:readSetting("stats")
--             if stats and stats.pages and stats.pages ~= 0 then -- crengine with statistics disabled stores 0
--                 pages = stats.pages
--             end
--         end
--         local percent_finished = doc_settings:readSetting("percent_finished")
--         local summary = doc_settings:readSetting("summary")
--         status = summary and summary.status
--         local has_highlight
--         local annotations = doc_settings:readSetting("annotations")
--         if annotations then
--             has_highlight = #annotations > 0
--         else
--             local highlight = doc_settings:readSetting("highlight")
--             has_highlight = highlight and next(highlight) and true
--         end
--         self.cover_info_cache[file] = table.pack(pages, percent_finished, status, has_highlight) -- may be a sparse array
--     else
--         if self.cover_info_cache and self.cover_info_cache[file] then
--             if status then
--                 self.cover_info_cache[file][3] = status
--             else
--                 self.cover_info_cache[file] = nil
--             end
--         end
--     end
-- end

function CoverMenu:updateItems(select_number, no_recalculate_dimen)
    logger.info("PTPT update items start")
    logger.info(debug.getinfo(2).name)
    local start_time = time.now()
    -- As done in Menu:updateItems()
    local old_dimen = self.dimen and self.dimen:copy()
    -- self.layout must be updated for focusmanager
    self.layout = {}
    self.item_group:clear()
    -- NOTE: Our various _recalculateDimen overloads appear to have a stronger dependency
    --       on the rest of the widget elements being properly laid-out,
    --       so we have to run it *first*, unlike in Menu.
    --       Otherwise, various layout issues arise (e.g., MosaicMenu's page_info is misaligned).
    if not no_recalculate_dimen then
        self:_recalculateDimen()
    end
    self.page_info:resetLayout()
    self.return_button:resetLayout()
    self.content_group:resetLayout()
    -- default to select the first item
    if not select_number then
        select_number = 1
    end

    -- Reset the list of items not found in db that will need to
    -- be updated by a scheduled action
    self.items_to_update = {}
    -- Cancel any previous (now obsolete) scheduled update
    if self.items_update_action then
        UIManager:unschedule(self.items_update_action)
        self.items_update_action = nil
    end

    -- Force garbage collecting before drawing a new page.
    -- It's not really needed from a memory usage point of view, we did
    -- all the free() where necessary, and koreader memory usage seems
    -- stable when file browsing only (15-25 MB).
    -- But I witnessed some freezes after browsing a lot when koreader's main
    -- process was using 100% cpu (and some slow downs while drawing soon before
    -- the freeze, like the full refresh happening before the final drawing of
    -- new text covers), while still having a small memory usage (20/30 Mb)
    -- that I suspect may be some garbage collecting happening at one point
    -- and getting stuck...
    -- With this, garbage collecting may be more deterministic, and it has
    -- no negative impact on user experience.
    -- But don't do it on every drawing, to not have all of them slow
    -- when memory usage is already high
    nb_drawings_since_last_collectgarbage = nb_drawings_since_last_collectgarbage + 1
    if nb_drawings_since_last_collectgarbage >= NB_DRAWINGS_BETWEEN_COLLECTGARBAGE then
        -- (delay it a bit so this pause is less noticable)
        UIManager:scheduleIn(0.2, function()
            collectgarbage()
            collectgarbage()
        end)
        nb_drawings_since_last_collectgarbage = 0
    end

    -- Specific UI building implementation (defined in some other module)
    self._has_cover_images = false
    select_number = self:_updateItemsBuildUI() or select_number

    -- Set the local variables with the things we know
    -- These are used only by extractBooksInDirectory(), which should
    -- use the cover_specs set for FileBrowser, and not those from History.
    -- Hopefully, we get self.path=nil when called from History
    if self.path and is_pathchooser == false then
        current_path = self.path
        current_cover_specs = self.cover_specs
    end

    -- As done in Menu:updateItems()
    self:updatePageInfo(select_number)
    Menu.mergeTitleBarIntoLayout(self)

    self.show_parent.dithered = self._has_cover_images
    UIManager:setDirty(self.show_parent, function()
        local refresh_dimen =
            old_dimen and old_dimen:combine(self.dimen)
            or self.dimen
        return "ui", refresh_dimen, self.show_parent.dithered
    end)

    -- As additionally done in FileChooser:updateItems()
    if self.path_items then
        self.path_items[self.path] = (self.page - 1) * self.perpage + (select_number or 1)
    end

    -- Deal with items not found in db
    if #self.items_to_update > 0 then
        -- Prepare for background info extraction job
        local files_to_index = {} -- table of {filepath, cover_specs}
        for i = 1, #self.items_to_update do
            table.insert(files_to_index, {
                filepath = self.items_to_update[i].filepath,
                cover_specs = self.items_to_update[i].cover_specs
            })
        end
        -- Launch it at nextTick, so UIManager can render us smoothly
        UIManager:nextTick(function()
            local launched = BookInfoManager:extractInBackground(files_to_index)
            if not launched then -- fork failed (never experienced that, but let's deal with it)
                -- Cancel scheduled update, as it won't get any result
                if self.items_update_action then
                    UIManager:unschedule(self.items_update_action)
                    self.items_update_action = nil
                end
                UIManager:show(InfoMessage:new {
                    text = _("Start-up of background extraction job failed.\nPlease restart KOReader or your device.")
                })
            end
        end)

        -- Scheduled update action
        self.items_update_action = function()
            logger.dbg("Scheduled items update:", #self.items_to_update, "waiting")
            local is_still_extracting = BookInfoManager:isExtractingInBackground()
            local i = 1
            while i <= #self.items_to_update do -- process and clean in-place
                local item = self.items_to_update[i]
                item:update()
                if item.bookinfo_found then
                    logger.dbg("  found", item.text)
                    self.show_parent.dithered = item._has_cover_image
                    local refreshfunc = function()
                        if item.refresh_dimen then
                            -- MosaicMenuItem may exceed its own dimen in its paintTo
                            -- with its "description" hint
                            return "ui", item.refresh_dimen, self.show_parent.dithered
                        else
                            return "ui", item[1].dimen, self.show_parent.dithered
                        end
                    end
                    UIManager:setDirty(self.show_parent, refreshfunc)
                    table.remove(self.items_to_update, i)
                else
                    logger.dbg("  not yet found", item.text)
                    i = i + 1
                end
            end
            if #self.items_to_update > 0 then -- re-schedule myself
                if is_still_extracting then   -- we have still chances to get new stuff
                    logger.dbg("re-scheduling items update:", #self.items_to_update, "still waiting")
                    UIManager:scheduleIn(1, self.items_update_action)
                else
                    logger.dbg("Not all items found, but background extraction has stopped, not re-scheduling")
                end
            else
                logger.dbg("items update completed")
            end
        end
        UIManager:scheduleIn(1, self.items_update_action)
    end

    logger.info(string.format("PTPT done in %.3f", time.to_ms(time.since(start_time))))
end

function CoverMenu:onCloseWidget()
    -- Due to close callback in FileManagerHistory:onShowHist, we may be called
    -- multiple times (witnessed that with print(debug.traceback())
    -- So, avoid doing what follows twice
    if self._covermenu_onclose_done then
        return
    end
    self._covermenu_onclose_done = true

    -- Stop background job if any (so that full cpu is available to reader)
    logger.dbg("CoverMenu:onCloseWidget: terminating jobs if needed")
    BookInfoManager:terminateBackgroundJobs()
    BookInfoManager:closeDbConnection() -- sqlite connection no more needed
    BookInfoManager:cleanUp()           -- clean temporary resources
    is_pathchooser = false

    -- Cancel any still scheduled update
    if self.items_update_action then
        logger.dbg("CoverMenu:onCloseWidget: unscheduling items_update_action")
        UIManager:unschedule(self.items_update_action)
        self.items_update_action = nil
    end

    -- Propagate a call to free() to all our sub-widgets, to release memory used by their _bb
    self.item_group:free()

    -- Clean any short term cache (used by ListMenu to cache some Doc Settings info)
    self.cover_info_cache = nil

    -- Force garbage collecting when leaving too
    -- (delay it a bit so this pause is less noticable)
    UIManager:scheduleIn(0.2, function()
        collectgarbage()
        collectgarbage()
    end)
    nb_drawings_since_last_collectgarbage = 0

    -- Call the object's original onCloseWidget (i.e., Menu's, as none our our expected subclasses currently implement it)
    Menu.onCloseWidget(self)
end

function CoverMenu:genItemTable(dirs, files, path)
    if meta_browse_mode == true and is_pathchooser == false and G_reader_settings:readSetting("home_dir") ~= nil then
        -- build item tables from coverbrowser-style sqlite db
        -- sqlite db doesn't track read status or progress %, would have to get that from elsewhere
        local Filechooser = require("ui/widget/filechooser")
        local lfs = require("libs/libkoreader-lfs")
        local SQ3 = require("lua-ljsqlite3/init")
        local DataStorage = require("datastorage")
        local custom_item_table = {}
        self.db_location = DataStorage:getSettingsDir() .. "/PT_bookinfo_cache.sqlite3"
        self.db_conn = SQ3.open(self.db_location)
        self.db_conn:set_busy_timeout(5000)
        local res = self.db_conn:exec("SELECT directory, filename FROM bookinfo WHERE directory LIKE '" ..
            G_reader_settings:readSetting("home_dir") .. "%' ORDER BY authors ASC, series ASC, series_index ASC, title ASC;")
        if res then
            local directories = res[1]
            local filenames = res[2]
            for i, filename in ipairs(filenames) do
                local dirpath = directories[i]
                local fullpath = dirpath..filename
                if lfs.attributes(fullpath, "mode") == "file" and not (G_reader_settings:isFalse("show_hidden") and util.stringStartsWith(filename, ".")) then
                    local attributes = lfs.attributes(fullpath) or {}
                    local collate = { can_collate_mixed = nil, item_func = nil }
                    local item = Filechooser:getListItem(dirpath, filename, fullpath, attributes, collate)
                    table.insert(custom_item_table, item)
                end
            end
        end
        self.db_conn:close()
        return custom_item_table

        -- build item tables from calibre json database
        -- local CalibreMetadata = require("metadata")
        -- local Filechooser = require("ui/widget/filechooser")
        -- local lfs = require("libs/libkoreader-lfs")
        -- local custom_item_table = {}
        -- local root = "/mnt/onboard" -- would need to replace with a generic
        -- CalibreMetadata:init(root, true)
        -- for _, book in ipairs(CalibreMetadata.books) do
        --     local fullpath = root.."/"..book.lpath
        --     local dirpath, f = util.splitFilePathName(fullpath)
        --     -- if file, then insert in custom_item_table
        -- end
        -- CalibreMetadata:clean()
        -- return custom_item_table
    else
        local item_table = CoverMenu._FileChooser_genItemTable_orig(self, dirs, files, path)
        if #item_table > 0 and is_pathchooser == false then
            if item_table[1].text == "⬆ ../" then table.remove(item_table, 1) end
        end
        if path ~= "/" and (G_reader_settings:isTrue("lock_home_folder") and path == G_reader_settings:readSetting("home_dir")) and is_pathchooser then
            table.insert(item_table, 1, {
                text = BD.mirroredUILayout() and BD.ltr("../ ⬆") or "⬆ ../",
                path = path .. "/..",
                is_go_up = true,
            })
        end
        return item_table
    end
end

local function onFolderUp()
    if current_path then -- file browser or PathChooser
        if not (G_reader_settings:isTrue("lock_home_folder") and
                current_path == G_reader_settings:readSetting("home_dir")) then
            FileManager.instance.file_chooser:changeToPath(string.format("%s/..", current_path), current_path)
        end
        -- if current_path ~= "/" and not (G_reader_settings:isTrue("lock_home_folder") and
        --         current_path == G_reader_settings:readSetting("home_dir")) then
        --     FileManager.instance.file_chooser:changeToPath(string.format("%s/..", current_path))
        -- else
        --     FileManager.instance.file_chooser:goHome()
        -- end
    end
end

function CoverMenu:updateTitleBarPath(path)
    -- We dont need the original function
    -- We dont use that title bar and we dont use the subtitle
end

function CoverMenu:setupLayout()
    self.show_parent = self.show_parent or self
    self.title_bar = TitleBar:new {
        show_parent = self.show_parent,
        fullscreen = "true",
        align = "center",
        title = "",
        title_top_padding = Screen:scaleBySize(6),
        subtitle = "",
        subtitle_truncate_left = true,
        subtitle_fullwidth = true,
        button_padding = Screen:scaleBySize(5),
        -- home
        left_icon = "home",
        left_icon_size_ratio = 1,
        left_icon_tap_callback = function() self:goHome() end,
        left_icon_hold_callback = function() self:onShowFolderMenu() end,
        -- favorites
        left2_icon = "favorites",
        left2_icon_size_ratio = 1,
        left2_icon_tap_callback = function() FileManager.instance.collections:onShowColl() end,
        left2_icon_hold_callback = function() FileManager.instance.folder_shortcuts:onShowFolderShortcutsDialog() end,
        -- history
        left3_icon = "history",
        left3_icon_size_ratio = 1,
        left3_icon_tap_callback = function() FileManager.instance.history:onShowHist() end,
        left3_icon_hold_callback = false,
        -- plus menu
        right_icon = self.selected_files and "check" or "plus",
        right_icon_size_ratio = 1,
        right_icon_tap_callback = function() self:onShowPlusMenu() end,
        right_icon_hold_callback = false,
        -- up folder
        right2_icon = "go_up",
        right2_icon_size_ratio = 1,
        right2_icon_tap_callback = function() onFolderUp() end,
        right2_icon_hold_callback = false,
        -- open last file
        right3_icon = "last_document",
        right3_icon_size_ratio = 1,
        right3_icon_tap_callback = function() FileManager.instance.menu:onOpenLastDoc() end,
        right3_icon_hold_callback = false,
        -- centered logo
        center_icon = "hero",
        center_icon_size_ratio = 1.25, -- larger "hero" size compared to rest of titlebar icons
        center_icon_tap_callback = false,
        center_icon_hold_callback = function()
            meta_browse_mode = not meta_browse_mode
            self:goHome()
        end,
        -- center_icon_hold_callback = function()
        --     UIManager:show(InfoMessage:new {
        --         text = T(_("KOReader %1\nwith Project: Title UI\nhttps://koreader.rocks\n\nLicensed under Affero GPL v3.\nAll dependencies are free software."), BD.ltr(Version:getShortVersion())),
        --         show_icon = false,
        --         alignment = "center",
        --     })
        -- end,
    }

    local file_chooser = FileChooser:new {
        name = "filemanager",
        path = self.root_path,
        focused_path = self.focused_file,
        show_parent = self.show_parent,
        height = Screen:getHeight(),
        is_popout = false,
        is_borderless = true,
        file_filter = function(filename) return DocumentRegistry:hasProvider(filename) end,
        close_callback = function() return self:onClose() end,
        -- allow left bottom tap gesture, otherwise it is eaten by hidden return button
        return_arrow_propagation = true,
        -- allow Menu widget to delegate handling of some gestures to GestureManager
        ui = self,
        -- Tell FileChooser (i.e., Menu) to use our own title bar instead of Menu's default one
        custom_title_bar = self.title_bar,
        search_callback = function(search_string)
            self.filesearcher:onShowFileSearch(search_string)
        end,
    }
    self.file_chooser = file_chooser
    self.focused_file = nil -- use it only once

    local file_manager = self

    function file_chooser:onFileSelect(item)
        if file_manager.selected_files then -- toggle selection
            item.dim = not item.dim and true or nil
            file_manager.selected_files[item.path] = item.dim
            self:updateItems()
        else
            file_manager:openFile(item.path)
        end
        return true
    end

    function file_chooser:onFileHold(item)
        if file_manager.selected_files then
            file_manager:tapPlus()
        else
            self:showFileDialog(item)
        end
    end

    function file_chooser:showFileDialog(item)
        local file = item.path
        local is_file = item.is_file
        local is_not_parent_folder = not item.is_go_up

        local function close_dialog_callback()
            UIManager:close(self.file_dialog)
        end
        local function refresh_callback()
            self:refreshPath()
        end
        local function close_dialog_refresh_callback()
            UIManager:close(self.file_dialog)
            self:refreshPath()
        end

        local buttons = {
            {
                {
                    text = C_("File", "Paste"),
                    enabled = file_manager.clipboard and true or false,
                    callback = function()
                        UIManager:close(self.file_dialog)
                        file_manager:pasteFileFromClipboard(file)
                    end,
                },
                {
                    text = _("Select"),

                    callback = function()
                        UIManager:close(self.file_dialog)
                        file_manager:onToggleSelectMode()
                        if is_file then
                            file_manager.selected_files[file] = true
                            item.dim = true
                            self:updateItems()
                        end
                    end,
                },
                {
                    text = _("Rename"),
                    enabled = is_not_parent_folder,
                    callback = function()
                        UIManager:close(self.file_dialog)
                        file_manager:showRenameFileDialog(file, is_file)
                    end,
                },
            },
            {
                {
                    text = _("Delete"),
                    enabled = is_not_parent_folder,
                    callback = function()
                        UIManager:close(self.file_dialog)
                        file_manager:showDeleteFileDialog(file, refresh_callback)
                    end,
                },
                {
                    text = _("Cut"),
                    enabled = is_not_parent_folder,
                    callback = function()
                        UIManager:close(self.file_dialog)
                        file_manager:cutFile(file)
                    end,
                },
                {
                    text = C_("File", "Copy"),
                    enabled = is_not_parent_folder,
                    callback = function()
                        UIManager:close(self.file_dialog)
                        file_manager:copyFile(file)
                    end,
                },
            },
            {}, -- separator
        }

        local book_props
        if is_file then
            local has_provider = DocumentRegistry:hasProvider(file)
            local been_opened = BookList.hasBookBeenOpened(file)
            local doc_settings_or_file = file
            if has_provider or been_opened then
                book_props = file_manager.coverbrowser and file_manager.coverbrowser:getBookInfo(file)
                if been_opened then
                    doc_settings_or_file = BookList.getDocSettings(file)
                    if not book_props then
                        local props = doc_settings_or_file:readSetting("doc_props")
                        book_props = FileManagerBookInfo.extendProps(props, file)
                        book_props.has_cover = true -- to enable "Book cover" button, we do not know if cover exists
                    end
                end
                table.insert(buttons,
                    filemanagerutil.genStatusButtonsRow(doc_settings_or_file, close_dialog_refresh_callback))
                table.insert(buttons, {}) -- separator
                table.insert(buttons, {
                    filemanagerutil.genResetSettingsButton(doc_settings_or_file, close_dialog_refresh_callback),
                    file_manager.collections:genAddToCollectionButton(file, close_dialog_callback, refresh_callback),
                })
            end
            if Device:canExecuteScript(file) then
                table.insert(buttons, {
                    filemanagerutil.genExecuteScriptButton(file, close_dialog_callback),
                })
            end
            if FileManagerConverter:isSupported(file) then
                table.insert(buttons, {
                    FileManagerConverter:genConvertButton(file, close_dialog_callback, refresh_callback)
                })
            end
            table.insert(buttons, {
                {
                    text = _("Open with…"),
                    callback = function()
                        UIManager:close(self.file_dialog)
                        file_manager:showOpenWithDialog(file)
                    end,
                },
                filemanagerutil.genBookInformationButton(doc_settings_or_file, book_props, close_dialog_callback),
            })
            if has_provider then
                table.insert(buttons, {
                    filemanagerutil.genBookCoverButton(file, book_props, close_dialog_callback),
                    filemanagerutil.genBookDescriptionButton(file, book_props, close_dialog_callback),
                })
            end
        else -- folder
            local folder = ffiUtil.realpath(file)
            table.insert(buttons, {
                {
                    text = _("Set as HOME folder"),
                    callback = function()
                        UIManager:close(self.file_dialog)
                        file_manager:setHome(folder)
                    end
                },
            })
            table.insert(buttons, {
                file_manager.folder_shortcuts:genAddRemoveShortcutButton(folder, close_dialog_callback, refresh_callback)
            })
        end

        if file_manager.file_dialog_added_buttons ~= nil then
            for _, row_func in ipairs(file_manager.file_dialog_added_buttons) do
                local row = row_func(file, is_file, book_props)
                if row ~= nil then
                    table.insert(buttons, row)
                end
            end
        end

        self.file_dialog = ButtonDialog:new {
            title = is_file and BD.filename(file:match("([^/]+)$")) or BD.directory(file:match("([^/]+)$")),
            title_align = "center",
            buttons = buttons,
        }
        UIManager:show(self.file_dialog)
        return true
    end

    local fm_ui = FrameContainer:new {
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        file_chooser,
    }

    self[1] = fm_ui

    self.menu = FileManagerMenu:new {
        ui = self
    }

    -- No need to reinvent the wheel, use FileChooser's layout
    self.layout = file_chooser.layout

    self:registerKeyEvents()
end

function CoverMenu:menuInit()
    CoverMenu._Menu_init_orig(self)

    -- create footer items
    local pagination_width = self.page_info:getSize().w -- get width before changing anything
    self.page_info = HorizontalGroup:new {
        self.page_info_first_chev,
        self.page_info_left_chev,
        self.page_info_text,
        self.page_info_right_chev,
        self.page_info_last_chev,
    }
    local page_info_container = RightContainer:new {
        dimen = Geom:new {
            w = self.screen_w * 0.98, -- 98% instead of 94% here due to whitespace on chevrons
            h = self.page_info:getSize().h,
        },
        self.page_info,
    }
    local path = ""
    if type(self.path) == "string" then path = self.path end
    self.cur_folder_text = TextWidget:new {
        text = path,
        face = Font:getFace(good_serif, 20),
        max_width = self.screen_w * 0.94 - pagination_width,
        truncate_with_ellipsis = true,
        truncate_left = true,
    }
    local cur_folder = HorizontalGroup:new {
        self.cur_folder_text,
    }
    local cur_folder_container = LeftContainer:new {
        dimen = Geom:new {
            w = self.screen_w * 0.94,
            h = self.page_info:getSize().h,
        },
        cur_folder,
    }
    local footer_left = BottomContainer:new {
        dimen = self.inner_dimen:copy(),
        cur_folder_container
    }
    local footer_right = BottomContainer:new {
        dimen = self.inner_dimen:copy(),
        page_info_container
    }
    local page_return = BottomContainer:new {
        dimen = self.inner_dimen:copy(),
        WidgetContainer:new {
            dimen = Geom:new {
                x = 0, y = 0,
                w = self.screen_w * 0.94,
                h = self.page_return_arrow:getSize().h,
            },
            self.return_button,
        }
    }
    local footer_line = BottomContainer:new { -- line to separate footer from content above
        dimen = Geom:new {
            x = 0, y = 0,
            w = self.inner_dimen.w,
            h = self.inner_dimen.h - self.page_info:getSize().h,
        },
        LineWidget:new {
            dimen = Geom:new {
                w = self.screen_w * 0.94,
                h = Size.line.medium },
            background = Blitbuffer.COLOR_BLACK,
        },
    }

    local content = OverlapGroup:new {
        -- This unique allow_mirroring=false looks like it's enough
        -- to have this complex Menu, and all widgets based on it,
        -- be mirrored correctly with RTL languages
        allow_mirroring = false,
        dimen = self.inner_dimen:copy(),
        self.content_group,
        page_return,
        footer_left,
        footer_right,
        footer_line,
    }
    self[1] = FrameContainer:new {
        background = Blitbuffer.COLOR_WHITE,
        padding = 0,
        margin = 0,
        bordersize = 0,
        radius = self.is_popout and math.floor(self.dimen.w * (1 / 20)) or 0,
        content
    }

    -- set and update pathchooser status
    is_pathchooser = false
    if util.stringEndsWith(self.title_bar.title, "name to choose it") then
        is_pathchooser = true
    end

    if self.item_table.current then
        self.page = self:getPageNumber(self.item_table.current)
    end
    if not self.path_items then -- not FileChooser
        self:updateItems(1, true)
    end
end

function CoverMenu:updatePageInfo(select_number)
    CoverMenu._Menu_updatePageInfo_orig(self, select_number)
    -- slim down text to just "X of Y" numbers
    local no_page_text = string.gsub(self.page_info_text.text, "Page ", "")
    self.page_info_text:setText(no_page_text)

    -- test to see what items to draw (pathchooser vs "detailed list view mode")
    if not is_pathchooser then
        local display_path = ""
        if self.cur_folder_text and type(self.path) == "string" and self.path ~= '' then
            self.cur_folder_text:setMaxWidth(self.screen_w * 0.94 - self.page_info:getSize().w)
            if (self.path == filemanagerutil.getDefaultDir() or
                    self.path == G_reader_settings:readSetting("home_dir")) and
                G_reader_settings:nilOrTrue("shorten_home_dir") then
                display_path = "Home"
            elseif self._manager and type(self._manager.name) == "string" then
                display_path = ""
            else
                -- show only the current folder name, not the whole path
                local folder_name = "/"
                local crumbs = {}
                for crumb in string.gmatch(self.path, "[^/]+") do
                    table.insert(crumbs, crumb)
                end
                if #crumbs > 1 then
                    folder_name = table.concat(crumbs, "", #crumbs, #crumbs)
                end
                -- add a star if folder is in shortcuts
                if FileManagerShortcuts:hasFolderShortcut(self.path) then
                    folder_name = "★ " .. folder_name
                end
                display_path = folder_name
            end
            if meta_browse_mode == true then display_path = "Library" end
            self.cur_folder_text:setText(display_path)
        elseif self.cur_folder_text and type(self.path) == "boolean" then
            display_path = ""
            self.cur_folder_text:setText(display_path)
        end
    else
        self.cur_folder_text:setText("")
    end
end

return CoverMenu
