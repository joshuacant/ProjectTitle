--[[
    This user patch is primarily for use with the Project: Title plugin.
    
    It sets the "Status Bar" (Footer) font to the serif font used in the plugin.
--]]

local ReaderFooter = require("apps/reader/modules/readerfooter")
local _ReaderFooter_init_orig = ReaderFooter.init
ReaderFooter.init = function(self)
	self.text_font_face = "SourceSerif4-Regular.ttf"
	_ReaderFooter_init_orig(self)
end
