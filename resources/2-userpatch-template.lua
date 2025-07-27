--[[

This is a template for writing a user patch to modify Project: Title itself.

It is similar to ones written targeting Cover Browser, so many of those will still
work on this plugin, and many of the methods used are identical. We tried to leave
file, function, and variable names unchanged. However, please look at the code for
this plugin first, as there are some changes and additions.

To learn about user patches, please visit the KOReader wiki article:
https://github.com/koreader/koreader/wiki/User-patches

]]--

local userpatch = require("userpatch")
local logger = require ("logger")

local function patchCoverBrowser(plugin)
    -- Grab Cover Grid mode and the individual Cover Grid items
    local MosaicMenu = require("mosaicmenu")
    local MosaicMenuItem = userpatch.getUpValue(MosaicMenu._updateItemsBuildUI, "MosaicMenuItem")

    -- Grab Cover List mode and the individual Cover List items
    local ListMenu = require("listmenu")
    local ListMenuItem = userpatch.getUpValue(ListMenu._updateItemsBuildUI, "ListMenuItem")

    -- Grab Cover Menu which sets up top bar, bottom bar, and generates the item table
    local CoverMenu = require("covermenu")
        -- CoverMenu:setupLayout() has the top bar
        -- CoverMenu:updatePageInfo(select_number) has the bottom bar
        -- CoverMenu:genItemTable(dirs, files, path) generates the item table
end

userpatch.registerPatchPluginFunc("coverbrowser", patchCoverBrowser)