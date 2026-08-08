--[[
    This user patch is primarily for use with the Project: Title plugin.

    It enables using the top toolbar with d-pad controls on non-touch devices, mostly Kindles.
--]]

local Menu = require("ui/widget/menu")
local logger = require("logger")
Menu.mergeTitleBarIntoLayout = function(self)
    if not self.title_bar then return end
    local title_bar_layout = self.title_bar:generateVerticalLayout()
    for i, row in ipairs(title_bar_layout) do
        table.insert(self.layout, i, row)
    end
    self.selected.y = self.selected.y + #title_bar_layout
    logger.dbg("Menu:mergeTitleBarIntoLayout (Patched): Adjusted focus position to account for added titlebar rows:", self.selected.x, ",", self.selected.y)
end
