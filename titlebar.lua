local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local IconButton = require("ui/widget/iconbutton")
local Math = require("optmath")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local logger = require("logger")
local ptutil = require("ptutil")
local ptdbg = require("ptdbg")

local DGENERIC_ICON_SIZE = G_defaults:readSetting("DGENERIC_ICON_SIZE")

local TitleBar = OverlapGroup:extend {
    left_icon = nil,
    left_icon_tap_callback = function() end,
    left_icon_hold_callback = function() end,
    left_icon_allow_flash = true,
    left2_icon = nil,
    left2_icon_tap_callback = function() end,
    left2_icon_hold_callback = function() end,
    left2_icon_allow_flash = true,
    left3_icon = nil,
    left3_icon_tap_callback = function() end,
    left3_icon_hold_callback = function() end,
    left3_icon_allow_flash = true,
    right_icon = nil,
    right_icon_tap_callback = function() end,
    right_icon_hold_callback = function() end,
    right_icon_allow_flash = true,
    right2_icon = nil,
    right2_icon_tap_callback = function() end,
    right2_icon_hold_callback = function() end,
    right2_icon_allow_flash = true,
    right3_icon = nil,
    right3_icon_tap_callback = function() end,
    right3_icon_hold_callback = function() end,
    right3_icon_allow_flash = true,
    center_icon = nil,
    center_icon_tap_callback = function() end,
    center_icon_hold_callback = function() end,
    center_icon_allow_flash = true,
    -- set any of these _callback to false to not handle the event
    -- and let it propagate; otherwise the event is discarded
    -- If provided, use right_icon="exit" and use this as right_icon_tap_callback
    close_callback = nil,
    close_hold_callback = nil,
    show_parent = nil,
    button_padding = Screen:scaleBySize(11), -- fine to keep exit/cross icon diagonally aligned with screen corners
    -- Internal: remember first sizes computed when title_shrink_font_to_fit=true,
    -- and keep using them after :setTitle() in case a smaller font size is needed,
    -- to keep the TitleBar geometry stable.
    title = "",
    subtitle = "",
    _initial_title_top_padding = nil,
    _initial_title_text_baseline = nil,
    _initial_titlebar_height = nil,
    _initial_filler_height = nil,
    _initial_re_init_needed = nil,
}

function TitleBar:init()
    if self.close_callback then
        self.right_icon = "close"
        self.right_icon_tap_callback = self.close_callback
        self.right_icon_allow_flash = false
        if self.close_hold_callback then
            self.right_icon_hold_callback = function() self.close_hold_callback() end
        end
    end

    local icon_size = Screen:scaleBySize(DGENERIC_ICON_SIZE)
    local icon_height = icon_size
    local icon_baseline = icon_height * 0.8 + self.button_padding

    self.title_widget = TextWidget:new { -- Dummy textwidget to enforce vertical height
        face = Font:getFace("smalltfont"),
        text = self.title,
    }
    local text_baseline = self.title_widget:getBaseline()
    local title_top_padding = Math.round(math.max(0, icon_baseline - text_baseline))
    self.title_group = VerticalGroup:new {
        align = "center",
        overlap_align = "center",
        VerticalSpan:new { width = title_top_padding },
    }
    table.insert(self.title_group, self.title_widget)
    self.titlebar_height = self.title_group:getSize().h
    self.bottom_v_padding = Screen:scaleBySize(6)
    self.titlebar_height = self.titlebar_height + self.bottom_v_padding

    self.width = Screen:getWidth()
    self.dimen = Geom:new {
        x = 0,
        y = 0,
        w = self.width,
        h = self.titlebar_height, -- buttons can overflow this
    }

    local center_icon_size = Screen:scaleBySize(DGENERIC_ICON_SIZE * self.center_icon_size_ratio)
    local center_icon_reserved_width = center_icon_size + self.button_padding
    local icon_reserved_width = icon_size + self.button_padding
    local icon_padding_width = icon_reserved_width * 0.65
    local icon_padding_height = Screen:scaleBySize(6)
    local icon_padding_side_offset = Screen:scaleBySize(14)

    self.left_button = IconButton:new {
        icon = self.left_icon,
        icon_rotation_angle = 0,
        width = icon_reserved_width,
        height = icon_size,
        padding = self.button_padding,
        padding_left = icon_padding_side_offset,
        padding_right = icon_padding_width / 2,
        padding_bottom = icon_size * 0.2,
        padding_top = icon_padding_height,
        overlap_align = "left",
        callback = self.left_icon_tap_callback,
        hold_callback = self.left_icon_hold_callback,
        allow_flash = self.left_icon_allow_flash,
        show_parent = self.show_parent,
    }
    table.insert(self, self.left_button)
    self.left2_button = IconButton:new {
        icon = self.left2_icon,
        icon_rotation_angle = 0,
        width = icon_reserved_width,
        height = icon_size,
        padding = self.button_padding,
        padding_left = icon_padding_side_offset + icon_reserved_width + icon_padding_width,
        padding_right = icon_padding_width / 2,
        padding_bottom = icon_size * 0.2,
        padding_top = icon_padding_height,
        overlap_align = "left",
        callback = self.left2_icon_tap_callback,
        hold_callback = self.left2_icon_hold_callback,
        allow_flash = self.left2_icon_allow_flash,
        show_parent = self.show_parent,
    }
    table.insert(self, self.left2_button)
    self.left3_button = IconButton:new {
        icon = self.left3_icon,
        icon_rotation_angle = 0,
        width = icon_reserved_width,
        height = icon_size,
        padding = self.button_padding,
        padding_left = icon_padding_side_offset + (2 * icon_reserved_width) + (2 * icon_padding_width),
        padding_right = icon_padding_width / 2,
        padding_bottom = icon_size * 0.2,
        padding_top = icon_padding_height,
        overlap_align = "left",
        callback = self.left3_icon_tap_callback,
        hold_callback = self.left3_icon_hold_callback,
        allow_flash = self.left3_icon_allow_flash,
        show_parent = self.show_parent,
    }
    table.insert(self, self.left3_button)
    self.right_button = IconButton:new {
        icon = self.right_icon,
        icon_rotation_angle = 0,
        width = icon_reserved_width,
        height = icon_size,
        padding = self.button_padding,
        padding_left = icon_padding_width / 2,
        padding_right = icon_padding_side_offset,
        padding_bottom = icon_size * 0.2,
        padding_top = icon_padding_height,
        overlap_align = "right",
        callback = self.right_icon_tap_callback,
        hold_callback = self.right_icon_hold_callback,
        allow_flash = self.right_icon_allow_flash,
        show_parent = self.show_parent,
    }
    table.insert(self, self.right_button)
    self.right2_button = IconButton:new {
        icon = self.right2_icon,
        icon_rotation_angle = 0,
        width = icon_reserved_width,
        height = icon_size,
        padding = self.button_padding,
        padding_left = icon_padding_width / 2,
        padding_right = icon_padding_side_offset + icon_reserved_width + icon_padding_width,
        padding_bottom = icon_size * 0.2,
        padding_top = icon_padding_height,
        overlap_align = "right",
        callback = self.right2_icon_tap_callback,
        hold_callback = self.right2_icon_hold_callback,
        allow_flash = self.right2_icon_allow_flash,
        show_parent = self.show_parent,
    }
    table.insert(self, self.right2_button)
    self.right3_button = IconButton:new {
        icon = self.right3_icon,
        icon_rotation_angle = 0,
        width = icon_reserved_width,
        height = icon_size,
        padding = self.button_padding,
        padding_left = icon_padding_width / 2,
        padding_right = icon_padding_side_offset + (2 * icon_reserved_width) + (2 * icon_padding_width),
        padding_bottom = icon_size * 0.2,
        padding_top = icon_padding_height,
        overlap_align = "right",
        callback = self.right3_icon_tap_callback,
        hold_callback = self.right3_icon_hold_callback,
        allow_flash = self.right3_icon_allow_flash,
        show_parent = self.show_parent,
    }
    table.insert(self, self.right3_button)
    self.center_button = IconButton:new {
        icon = self.center_icon,
        icon_rotation_angle = 0,
        width = center_icon_reserved_width,
        height = center_icon_size,
        padding = 0, -- manual padding for hero icon needed
        padding_left = 0,
        padding_right = 0,
        padding_bottom = 0,
        padding_top = Screen:scaleBySize(3),
        overlap_align = "center",
        callback = self.center_icon_tap_callback,
        hold_callback = self.center_icon_hold_callback,
        allow_flash = self.center_icon_allow_flash,
        show_parent = self.show_parent,
    }
    table.insert(self, self.center_button)

    -- Call our base class's init (especially since OverlapGroup has very peculiar self.dimen semantics...)
    OverlapGroup.init(self)
end

function TitleBar:paintTo(bb, x, y)
    -- We need to update self.dimen's x and y for any ges.pos:intersectWith(title_bar)
    -- to work. (This is done by FrameContainer, but not by most other widgets... It
    -- should probably be done in all of them, but not sure of side effects...)
    self.dimen.x = x
    self.dimen.y = y
    OverlapGroup.paintTo(self, bb, x, y)
end

function TitleBar:getHeight()
    return self.titlebar_height
end

function TitleBar:setTitle(title, no_refresh)
    self.title = ""
end

function TitleBar:setSubTitle(subtitle, no_refresh)
    self.subtitle = ""
end

function TitleBar:setLeftIcon(icon)
    if self.has_left_icon then
        self.left_button:setIcon(icon)
        UIManager:setDirty(self.show_parent, "ui", self.dimen)
    end
end

function TitleBar:setLeft2Icon(icon)
    if self.has_left2_icon then
        self.left2_button:setIcon(icon)
        UIManager:setDirty(self.show_parent, "ui", self.dimen)
    end
end

function TitleBar:setLeft3Icon(icon)
    if self.has_left3_icon then
        self.left3_button:setIcon(icon)
        UIManager:setDirty(self.show_parent, "ui", self.dimen)
    end
end

function TitleBar:setRightIcon(icon)
    if self.has_right_icon then
        self.right_button:setIcon(icon)
        UIManager:setDirty(self.show_parent, "ui", self.dimen)
    end
end

function TitleBar:setright2Icon(icon)
    if self.has_right2_icon then
        self.right2_button:setIcon(icon)
        UIManager:setDirty(self.show_parent, "ui", self.dimen)
    end
end

function TitleBar:setright3Icon(icon)
    if self.has_right3_icon then
        self.right3_button:setIcon(icon)
        UIManager:setDirty(self.show_parent, "ui", self.dimen)
    end
end

function TitleBar:setcenterIcon(icon)
    if self.has_center_icon then
        self.center_button:setIcon(icon)
        UIManager:setDirty(self.show_parent, "ui", self.dimen)
    end
end

-- layout for FocusManager
function TitleBar:generateHorizontalLayout()
    local row = {}
    if self.left_button then
        table.insert(row, self.left_button)
    end
    if self.left2_button then
        table.insert(row, self.left2_button)
    end
    if self.left3_button then
        table.insert(row, self.left3_button)
    end
    if self.center_button then
        table.insert(row, self.center_button)
    end
    if self.right3_button then
        table.insert(row, self.right3_button)
    end
    if self.right2_button then
        table.insert(row, self.right2_button)
    end
    if self.right_button then
        table.insert(row, self.right_button)
    end
    local layout = {}
    if #row > 0 then
        table.insert(layout, row)
    end
    return layout
end

function TitleBar:generateVerticalLayout()
    local layout = {}
    if self.left_button then
        table.insert(layout, { self.left_button })
    end
    if self.left2_button then
        table.insert(layout, { self.left2_button })
    end
    if self.left3_button then
        table.insert(layout, { self.left3_button })
    end
    if self.center_button then
        table.insert(layout, { self.center_button })
    end
    if self.right3_button then
        table.insert(layout, { self.right3_button })
    end
    if self.right2_button then
        table.insert(layout, { self.right2_button })
    end
    if self.right_button then
        table.insert(layout, { self.right_button })
    end
    return layout
end

return TitleBar
