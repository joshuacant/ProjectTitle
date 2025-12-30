local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FileManagerBookInfo = require("apps/filemanager/filemanagerbookinfo")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local ProgressWidget = require("ui/widget/progresswidget")
local RenderImage = require("ui/renderimage")
local Size = require("ui/size")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local util = require("util")
local _ = require("l10n.gettext")
local Screen = Device.screen
local T = require("ffi/util").template
local BookInfoManager = require("bookinfomanager")
local ptutil = require("ptutil")
local ptdbg = require("ptdbg")

local AltBookStatusWidget = {}

function AltBookStatusWidget:getStatusContent(width)
    self.padding = Screen:scaleBySize(22)
    local read_percentage = self.ui:getCurrentPage() / self.total_pages
    local content = VerticalGroup:new {
        align = "left",
        VerticalSpan:new { width = self.padding},
        self:genBookInfoGroup(),
        self:genHeader(_("Progress") .. ": " .. string.format("%1.f%%", read_percentage * 100)),
        self:genStatisticsGroup(width),
        self:genHeader(_("Description")),
        self:genSummaryGroup(width),
    }
    return content
end

function AltBookStatusWidget:genHeader(title)
    local header_title = TextWidget:new {
        text = title,
        face = Font:getFace(ptutil.good_sans, ptutil.bookstatus_defaults.header_font_size),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }

    local width = Screen:getWidth()
    local height = header_title:getSize().h
    local padding_span = HorizontalSpan:new { width = self.padding }
    local line_width = (width - header_title:getSize().w) / 2 - self.padding * 2
    local line_container = LeftContainer:new {
        dimen = Geom:new { w = line_width, h = height },
        LineWidget:new {
            background = Blitbuffer.COLOR_GRAY_3,
            dimen = Geom:new {
                w = line_width,
                h = Size.border.thin,
            }
        }
    }

    local span_top = VerticalSpan:new { width = Size.margin.default }
    local span_bottom = VerticalSpan:new { width = Size.margin.tiny }

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
    local screen_width = Screen:getWidth()
    local screen_height = Screen:getHeight()
    local width = screen_width
    local height = screen_height * 0.40
    local max_img_h = height
    local max_img_w = height
    local avail_meta_width = width - (self.padding * 3)
    local avail_meta_height = height

    -- create the full infogroup widget
    local book_info_group = HorizontalGroup:new {
        align = "top",
    }

    -- insert cover column
    local thumbnail = FileManagerBookInfo:getCoverImage(self.ui.document)
    if thumbnail then
        -- Much like BookInfoManager, honor AR here
        local cbb_w, cbb_h = thumbnail:getWidth(), thumbnail:getHeight()
        if cbb_w > max_img_w or cbb_h > max_img_h then
            local scale_factor = math.min(max_img_w / cbb_w, max_img_h / cbb_h)
            cbb_w = math.min(math.floor(cbb_w * scale_factor) + 1, max_img_w)
            cbb_h = math.min(math.floor(cbb_h * scale_factor) + 1, max_img_h)
            thumbnail = RenderImage:scaleBlitBuffer(thumbnail, cbb_w, cbb_h, true)
        end
        local border_total = Size.border.thin * 2
        local dimen = Geom:new {
            w = cbb_w + border_total,
            h = cbb_h + border_total,
        }
        local image = ImageWidget:new {
            image = thumbnail,
            width = cbb_w,
            height = cbb_h,
        }
        table.insert(book_info_group, CenterContainer:new {
            dimen = dimen,
            FrameContainer:new {
                width = dimen.w,
                height = dimen.h,
                margin = 0,
                padding = 0,
                radius = Size.radius.default,
                bordersize = Size.border.thin,
                color = Blitbuffer.COLOR_GRAY_3,
                image,
            }
        })
        avail_meta_width = avail_meta_width - (cbb_w + border_total)
        avail_meta_height = (cbb_h + border_total)
    end

    local text_width = math.floor(avail_meta_width * 0.85)
    local bar_width = math.floor(avail_meta_width * 0.75)

    -- Get a chance to have title and authors rendered with alternate
    -- glyphs for the book language
    local props = self.ui.doc_props
    local lang = props.language

    -- progress info
    local current_page = self.ui:getCurrentPage() or 1
    local book_pages = self.total_pages or 1
    local chapter_pages = 1
    local current_chapter_page = 1
    if self.ui.toc then
        chapter_pages = self.ui.toc:getChapterPageCount(current_page) or 1
        current_chapter_page = self.ui.toc:getChapterPagesDone(current_page) or 0
        current_chapter_page = current_chapter_page + 1 -- include the page you're looking at
    end

    -- author(s) text
    local authors = ""
    if props.authors then
        authors = ptutil.formatAuthors(props.authors, 2)
    end

    -- series name and position (if available, if requested)
    local series_mode = BookInfoManager:getSetting("series_mode")
    local show_series = props.series and props.series_index
    local series
    if show_series then
        series = ptutil.formatSeries(props.series, props.series_index)
        -- if series comes back as blank, don't include it
        if series == "" then show_series = false end
    else
        series = ""
    end

    -- combine author and series
    local author_series_text = ptutil.formatAuthorSeries(authors, series, series_mode, false)

    -- author(s) and series combined box
    local author_series = TextBoxWidget:new {
        text = author_series_text,
        lang = lang,
        face = Font:getFace(ptutil.good_serif, ptutil.bookstatus_defaults.metainfo_font_size),
        width = text_width,
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        alignment = "center",
        fgcolor = Blitbuffer.COLOR_GRAY_2,
    }

    -- book progress bar
    local book_percentage = current_page / book_pages
    local book_progress = ProgressWidget:new {
        width = bar_width,
        height = Screen:scaleBySize(16),
        percentage = book_percentage,
        margin_v = 0,
        margin_h = 0,
        bordersize = Screen:scaleBySize(0.5),
        bordercolor = Blitbuffer.COLOR_BLACK,
        bgcolor = Blitbuffer.COLOR_GRAY_E,
        fillcolor = Blitbuffer.COLOR_GRAY_6,
    }

    -- current chapter title (if available)
    local chapter_text = self.ui.toc:getTocTitleByPage(current_page) or ""
    local chapter_title = TextBoxWidget:new {
        text = chapter_text,
        lang = lang,
        face = Font:getFace(ptutil.good_serif_it, ptutil.bookstatus_defaults.metainfo_font_size),
        width = text_width,
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        alignment = "center",
        fgcolor = Blitbuffer.COLOR_BLACK,
    }

    -- chapter progress bar
    local chapter_percentage = current_chapter_page / chapter_pages
    local chapter_progress = ProgressWidget:new {
        width = bar_width,
        height = Screen:scaleBySize(12),
        percentage = chapter_percentage,
        margin_v = 0,
        margin_h = 0,
        bordersize = Screen:scaleBySize(0.5),
        bordercolor = Blitbuffer.COLOR_BLACK,
        bgcolor = Blitbuffer.COLOR_GRAY_E,
        fillcolor = Blitbuffer.COLOR_GRAY_6,
    }

    -- title box (done last to calculate the max available height)
    local max_title_height = height - author_series:getSize().h - book_progress:getSize().h - chapter_title:getSize().h - Size.padding.default
    local book_title = TextBoxWidget:new {
        text = props.display_title,
        lang = lang,
        width = text_width,
        height = max_title_height,
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        face = Font:getFace(ptutil.title_serif, ptutil.bookstatus_defaults.title_font_size),
        alignment = "center",
    }

    -- padding
    local meta_paddingsize = 0
    local meta_marginsize = 0
    local meta_bordersize = Size.border.thin
    local meta_padding_height = math.max(Size.padding.default,
                                        avail_meta_height - book_title:getSize().h -
                                        author_series:getSize().h - book_progress:getSize().h -
                                        chapter_progress:getSize().h - chapter_title:getSize().h -
                                        (meta_bordersize * 2) - (meta_paddingsize * 2) - (meta_marginsize * 2)
                                    )

    local dividing_line = LineWidget:new {
            background = Blitbuffer.COLOR_GRAY_3,
            dimen = Geom:new {
                w = avail_meta_width,
                h = Size.border.thin,
            }
        }

    -- build metadata column (adjacent to cover)
    local book_meta = VerticalGroup:new { align = "center" }
    table.insert(book_meta, VerticalSpan:new { width = meta_padding_height * 0.35 })
    table.insert(book_meta, book_title)
    table.insert(book_meta, book_progress)
    table.insert(book_meta, VerticalSpan:new { width = meta_padding_height * 0.2 })
    if chapter_text ~= "" then
        table.insert(book_meta, chapter_title)
        table.insert(book_meta, chapter_progress)
    end
    table.insert(book_meta, VerticalSpan:new { width = meta_padding_height * 0.45 })
    table.insert(book_meta, dividing_line)
    table.insert(book_meta, author_series)

    -- insert padding column
    table.insert(book_info_group, HorizontalSpan:new { width = self.padding })

    -- insert metadata column
    table.insert(book_info_group, FrameContainer:new {
        dimen = Geom:new { w = avail_meta_width, h = avail_meta_height },
        margin = meta_marginsize,
        padding = meta_paddingsize,
        radius = Size.radius.default,
        bordersize = meta_bordersize,
        color = Blitbuffer.COLOR_GRAY_3,
        book_meta,
    })

    local meta_container
    if not self.readonly then
        meta_container = InputContainer:new {
            CenterContainer:new {
                dimen = Geom:new { w = screen_width, h = height },
                book_info_group,
            }
        }
        meta_container:registerTouchZones({ {
            id = "meta_tap",
            ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 0.5 },
            handler = function(ges) self:onClose() end,
        }, })
    else
        meta_container = CenterContainer:new {
            dimen = Geom:new { w = screen_width, h = height },
            book_info_group,
        }
    end
    return meta_container
end

function AltBookStatusWidget:genStatisticsGroup(width)
    local screen_height = Screen:getHeight()
    local height = screen_height * 0.075
    local statistics_container = CenterContainer:new{
        dimen = Geom:new{ w = width, h = height },
    }
    local statistics_group = VerticalGroup:new{ align = "left" }
    local tile_width = width * 0.33
    local tile_height = height * 0.5
    local titles_group = HorizontalGroup:new{
        align = "center",
        CenterContainer:new{
            dimen = Geom:new{ w = tile_width, h = tile_height },
            TextWidget:new{
                text = _("Days"),
                face = Font:getFace(ptutil.good_serif_bold, ptutil.bookstatus_defaults.metainfo_font_size),
            },
        },
        CenterContainer:new{
            dimen = Geom:new{ w = tile_width, h = tile_height },
            TextWidget:new{
                text = _("Time"),
                face = Font:getFace(ptutil.good_serif_bold, ptutil.bookstatus_defaults.metainfo_font_size),
            },
        },
        CenterContainer:new{
            dimen = Geom:new{ w = tile_width, h = tile_height },
            TextWidget:new{
                text = _("Read pages"),
                face = Font:getFace(ptutil.good_serif_bold, ptutil.bookstatus_defaults.metainfo_font_size),
            }
        }
    }
    local data_group = HorizontalGroup:new{
        align = "center",
        CenterContainer:new{
            dimen = Geom:new{ w = tile_width, h = tile_height },
            TextWidget:new{
                text = self:getStatDays(),
                face = Font:getFace(ptutil.good_serif, ptutil.bookstatus_defaults.metainfo_font_size),
                fgcolor = Blitbuffer.COLOR_GRAY_2,
            },
        },
        CenterContainer:new{
            dimen = Geom:new{ w = tile_width, h = tile_height },
            TextWidget:new{
                text = self:getStatHours(),
                face = Font:getFace(ptutil.good_serif, ptutil.bookstatus_defaults.metainfo_font_size),
                fgcolor = Blitbuffer.COLOR_GRAY_2,
            },
        },
        CenterContainer:new{
            dimen = Geom:new{ w = tile_width, h = tile_height },
            TextWidget:new{
                text = self:getStatReadPages(),
                face = Font:getFace(ptutil.good_serif, ptutil.bookstatus_defaults.metainfo_font_size),
                fgcolor = Blitbuffer.COLOR_GRAY_2,
            }
        }
    }
    table.insert(statistics_group, titles_group)
    table.insert(statistics_group, data_group)
    table.insert(statistics_container, statistics_group)
    return statistics_container
end

function AltBookStatusWidget:genSummaryGroup(width)
    local screen_height = Screen:getHeight()
    local height = screen_height * 0.35
    if Screen:getScreenMode() == "landscape" then
        height = height * 0.85
    end

    local html_contents = ""
    local props = self.ui.doc_props
    if props.description then
        html_contents = "<html lang='" .. props.language .. "'><body>" .. props.description .. "</body></html>"
    else
        html_contents = "<html><body><h3 style='font-style: italic; color: #CCCCCC;'>" ..
        _("No book description available.") .. "</h3></body></html>"
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
        default_font_size = ptutil.bookstatus_defaults.description_font_size,
        html_body = html_contents,
        text_scroll_span = Screen:scaleBySize(20),
        scroll_bar_width = Screen:scaleBySize(10),
        dialog = self,
    }
    table.insert(self.layout, { self.input_note })

    return VerticalGroup:new {
        CenterContainer:new {
            dimen = Geom:new { w = width, h = height },
            self.input_note
        },
        -- LineWidget:new {
        --     background = Blitbuffer.COLOR_BLACK,
        --     dimen = Geom:new {
        --         w = width,
        --         h = Size.line.thick,
        --     }
        -- },
    }
end

return AltBookStatusWidget
