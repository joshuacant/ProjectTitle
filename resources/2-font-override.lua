--[[
    This user patch is primarily for use with the Project: Title plugin.
    
    It sets the UI fonts to the sans serif font used in the plugin.
--]]

local Font = require("ui/font")
for k, v in pairs(Font.fontmap) do
	if v == "NotoSans-Regular.ttf" then
		Font.fontmap[k] = "SourceSans3-Regular.ttf"
	elseif v == "NotoSans-Bold.ttf" then
		Font.fontmap[k] = "SourceSans3-Bold.ttf"
	end
end
for k, v in pairs(Font.sizemap) do
	Font.sizemap[k] = Font.sizemap[k] + 1
end
