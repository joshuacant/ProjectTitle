local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FileManagerBookInfo = require("apps/filemanager/filemanagerbookinfo")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local ProgressWidget = require("ui/widget/progresswidget")
local RenderImage = require("ui/renderimage")
local Size = require("ui/size")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local Screen = Device.screen
local T = require("ffi/util").template
local BookInfoManager = require("bookinfomanager")

local function findLast(haystack, needle)
    local i = haystack:match(".*" .. needle .. "()")
    if i == nil then return nil else return i - 1 end
end

local AltBookStatusWidget = {}

function AltBookStatusWidget:getStatusContent(width)
    local title_bar = TitleBar:new {
        width = width,
        bottom_v_padding = 0,
        close_callback = not self.readonly and function() self:onClose() end,
        show_parent = self,
    }
    local content = VerticalGroup:new {
        align = "left",
        title_bar,
        self:genBookInfoGroup(),
        self:genHeader("Progress"),
        self:genStatisticsGroup(width),
        self:genHeader("Description"),
        self:genSummaryGroup(width),
    }
    return content
end

function AltBookStatusWidget:genHeader(title)
    local width, height = Screen:getWidth(), Size.item.height_default

    local header_title = TextWidget:new {
        text = title,
        face = self.header_font,
        fgcolor = Blitbuffer.COLOR_GRAY_9,
    }

    local padding_span = HorizontalSpan:new { width = self.padding }
    local line_width = (width - header_title:getSize().w) / 2 - self.padding * 2
    local line_container = LeftContainer:new {
        dimen = Geom:new { w = line_width, h = height },
        LineWidget:new {
            background = Blitbuffer.COLOR_LIGHT_GRAY,
            dimen = Geom:new {
                w = line_width,
                h = Size.line.thick,
            }
        }
    }
    local span_top, span_bottom
    if Screen:getScreenMode() == "landscape" then
        span_top = VerticalSpan:new { width = Size.span.horizontal_default }
        span_bottom = VerticalSpan:new { width = Size.span.horizontal_default }
    else
        span_top = VerticalSpan:new { width = Size.item.height_default }
        span_bottom = VerticalSpan:new { width = Size.span.vertical_large }
    end

    return VerticalGroup:new {
        span_top,
        HorizontalGroup:new {
            align = "center",
            padding_span,
            line_container,
            padding_span,
            header_title,
            padding_span,
            line_container,
            padding_span,
        },
        span_bottom,
    }
end

function AltBookStatusWidget:genBookInfoGroup()
    -- override the original fonts with our included fonts
    self.small_font_face = Font:getFace("source/SourceSerif4-Regular.ttf", 18)
    self.medium_font_face = Font:getFace("source/SourceSerif4-Regular.ttf", 22)
    self.large_font_face = Font:getFace("source/SourceSerif4-Regular.ttf", 30)

    -- and set up our own as well
    self.header_font = Font:getFace("source/SourceSans3-Regular.ttf", 24)
    self.small_serif_font = Font:getFace("source/SourceSerif4-Regular.ttf", 18)
    self.large_serif_font = Font:getFace("source/SourceSerif4-BoldIt.ttf", 30)

    -- padding at 3% per side to match the 94% total width used in listview
    self.padding = Screen:getSize().w * 0.03

    local screen_width = Screen:getWidth()
    local split_span_width = math.floor(screen_width * 0.05)

    local img_width, img_height
    if Screen:getScreenMode() == "landscape" then
        img_width = Screen:scaleBySize(132)
        img_height = Screen:scaleBySize(184)
    else
        img_width = Screen:scaleBySize(132 * 1.5)
        img_height = Screen:scaleBySize(184 * 1.5)
    end

    local height = img_height
    local width = screen_width - split_span_width - img_width

    -- Get a chance to have title and authors rendered with alternate
    -- glyphs for the book language
    local props = self.ui.doc_props
    local lang = props.language

    -- author(s) text
    local author_text = ""
    if props.authors then
        local authors = props.authors
        if authors and authors:find("\n") then
            authors = util.splitToArray(authors, "\n")
            for i = 1, #authors do
                authors[i] = BD.auto(authors[i])
            end
            if #authors > 2 then
                authors = { authors[1], T(_("%1 et al."), authors[2]) }
            end
            author_text = table.concat(authors, "\n")
        elseif authors then
            author_text = BD.auto(authors)
        end
    end

    -- series text and position (if available, if requested)
    local series_mode = BookInfoManager:getSetting("series_mode")
    -- suppress showing series information if position in series is "0"
    local show_series = props.series and props.series_index and props.series_index ~= 0
    if show_series then
        local series_text = props.series
        if string.match(props.series, ": ") then
            series_text = string.sub(series_text, findLast(series_text, ": ") + 1, -1)
        end
        if props.series_index then
            series_text = "#" .. props.series_index .. " – " .. BD.auto(series_text)
        else
            series_text = BD.auto(series_text)
        end
        if not author_text then
            if series_mode == "series_in_separate_line" then
                author_text = series_text
            end
        else
            if series_mode == "series_in_separate_line" then
                author_text = series_text .. "\n" .. author_text
            end
        end
    end

    -- author(s) and series combined box
    local bookinfo = TextBoxWidget:new {
        text = author_text,
        lang = lang,
        face = self.small_serif_font,
        width = width,
        alignment = "center",
        fgcolor = Blitbuffer.COLOR_GRAY_2
    }

    -- progress bar
    local read_percentage = self.ui:getCurrentPage() / self.total_pages
    local progress_bar = ProgressWidget:new {
        width = math.floor(width * 0.7),
        height = Screen:scaleBySize(18),
        percentage = read_percentage,
        margin_v = 0,
        margin_h = 0,
        bordersize = Screen:scaleBySize(0.5),
        bordercolor = Blitbuffer.COLOR_BLACK,
        bgcolor = Blitbuffer.COLOR_GRAY_E,
        fillcolor = Blitbuffer.COLOR_GRAY_6,
    }

    -- progress text
    local progress_text = TextWidget:new {
        text = T(_("%1% Read"),
            string.format("%1.f", read_percentage * 100)),
        face = self.small_serif_font,
    }

    -- title box (done last to calculate the max available height)
    local max_title_height = height - bookinfo:getSize().h - progress_bar:getSize().h - progress_text:getSize().h -
        Size.padding.default
    local booktitle = TextBoxWidget:new {
        text = props.display_title,
        lang = lang,
        width = width,
        height = max_title_height,
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        face = self.large_serif_font,
        alignment = "center",
    }

    -- padding
    local meta_padding_height = math.max(Size.padding.default,
        height - booktitle:getSize().h - bookinfo:getSize().h - progress_bar:getSize().h - progress_text:getSize().h)
    local meta_padding = VerticalSpan:new { width = meta_padding_height }

    -- build metadata column (adjacent to cover)
    local book_meta_info_group = VerticalGroup:new {
        align = "center",
    }
    table.insert(book_meta_info_group, booktitle)
    table.insert(book_meta_info_group,
        CenterContainer:new {
            dimen = Geom:new { w = width, h = bookinfo:getSize().h },
            bookinfo
        }
    )
    table.insert(book_meta_info_group, meta_padding)
    table.insert(book_meta_info_group,
        CenterContainer:new {
            dimen = Geom:new { w = width, h = progress_bar:getSize().h },
            progress_bar
        }
    )
    table.insert(book_meta_info_group,
        CenterContainer:new {
            dimen = Geom:new { w = width, h = progress_text:getSize().h },
            progress_text
        }
    )

    -- assemble the final row w/ cover and metadata [X|Y]
    local book_info_group = HorizontalGroup:new {
        align = "top",
        HorizontalSpan:new { width = split_span_width }
    }
    -- cover column
    local thumbnail = FileManagerBookInfo:getCoverImage(self.ui.document)
    if thumbnail then
        -- Much like BookInfoManager, honor AR here
        local cbb_w, cbb_h = thumbnail:getWidth(), thumbnail:getHeight()
        if cbb_w > img_width or cbb_h > img_height then
            local scale_factor = math.min(img_width / cbb_w, img_height / cbb_h)
            cbb_w = math.min(math.floor(cbb_w * scale_factor) + 1, img_width)
            cbb_h = math.min(math.floor(cbb_h * scale_factor) + 1, img_height)
            thumbnail = RenderImage:scaleBlitBuffer(thumbnail, cbb_w, cbb_h, true)
        end

        table.insert(book_info_group, ImageWidget:new {
            image = thumbnail,
            width = cbb_w,
            height = cbb_h,
        })
    end
    -- metadata column
    table.insert(book_info_group, CenterContainer:new {
        dimen = Geom:new { w = width, h = height },
        book_meta_info_group,
    })

    return CenterContainer:new {
        dimen = Geom:new { w = screen_width, h = img_height },
        book_info_group,
    }
end

function AltBookStatusWidget:genSummaryGroup(width)
    local height
    if Screen:getScreenMode() == "landscape" then
        height = Screen:scaleBySize(165)
    else
        height = Screen:scaleBySize(265)
    end

    local html_contents
    local props = self.ui.doc_props
    if props.description then
        html_contents = "<html lang='" .. props.language .. "'><body>" .. props.description .. "</body></html>"
        --html_contents = "<html><body>" .. props.description .. "</body></html>"
    else
        html_contents = "<html><body><h2 style='font-style: italic; color: #CCCCCC;'>No description.</h3></body></html>"
    end
    self.input_note = ScrollHtmlWidget:new {
        width = width - Screen:scaleBySize(60),
        height = height,
        css = [[
            @page {
                margin: 0;
                font-family: 'Source Serif 4', serif;
                font-size: 18px;
                line-height: 1.00;
                text-align: justify;
            }
            body {
                margin: 0;
                padding: 0;
            }
            p {
                margin-top: 0;
                margin-bottom: 0;
                text-indent: 1.2em;
            }
            p + p {
                margin-top: 0.5em;
            }
        ]],
        default_font_size = Screen:scaleBySize(18),
        html_body = html_contents,
        text_scroll_span = Screen:scaleBySize(20),
        scroll_bar_width = Screen:scaleBySize(10),
        dialog = self,
    }
    table.insert(self.layout, { self.input_note })

    return VerticalGroup:new {
        VerticalSpan:new { width = Size.span.vertical_large },
        CenterContainer:new {
            dimen = Geom:new { w = width, h = height },
            self.input_note
        }
    }
end

return AltBookStatusWidget
