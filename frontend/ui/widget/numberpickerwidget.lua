--[[--
A customizable number picker.

Example:
    local NumberPickerWidget = require("ui/widget/numberpickerwidget")
    local numberpicker = NumberPickerWidget:new{
        -- for floating point (decimals), use something like "%.2f"
        precision = "%02d",
        value = 0,
        value_min = 0,
        value_max = 23,
        value_step = 1,
        value_hold_step = 4,
        wrap = true,
        update_callback = function() end,
    }
--]]

local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local Font = require("ui/font")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local RenderText = require("ui/rendertext")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local NumberPickerWidget = InputContainer:new{
    spinner_face = Font:getFace("smalltfont"),
    precision = "%02d",
    width = nil,
    height = nil,
    value = 0,
    value_min = 0,
    value_max = 23,
    value_step = 1,
    value_hold_step = 4,
    value_table = nil,
    wrap = true,
    update_callback = function() end,
    -- in case we need calculate number of days in a given month and year
    date_month = nil,
    date_year = nil,
}

function NumberPickerWidget:init()
    self.screen_width = Screen:getWidth()
    self.screen_height = Screen:getHeight()
    if self.width == nil then
        self.width = self.screen_width * 0.2
    end
    if self.value_table then
        self.value_index = 1
        self.value = self.value_table[self.value_index]
        self.step = 1
        self.value_hold_step = 1
    end
    self:update()
end

function NumberPickerWidget:paintWidget()
    local bordersize = Size.border.default
    local margin = Size.margin.default
    local button_up = Button:new{
        text = "▲",
        bordersize = bordersize,
        margin = margin,
        radius = 0,
        text_font_size = 24,
        width = self.width,
        show_parent = self.show_parent,
        callback = function()
            if self.date_month and self.date_year then
                self.value_max = self:getDaysInMonth(self.date_month:getValue(), self.date_year:getValue())
            end
            self.value = self:changeValue(self.value, self.value_step, self.value_max, self.value_min, self.wrap)
            self:update()
        end,
        hold_callback = function()
            if self.date_month and self.date_year then
                self.value_max = self:getDaysInMonth(self.date_month:getValue(), self.date_year:getValue())
            end
            self.value = self:changeValue(self.value, self.value_hold_step, self.value_max, self.value_min, self.wrap)
            self:update()
        end
    }
    local button_down = Button:new{
        text = "▼",
        bordersize = bordersize,
        margin = margin,
        radius = 0,
        text_font_size = 24,
        width = self.width,
        show_parent = self.show_parent,
        callback = function()
            if self.date_month and self.date_year then
                self.value_max = self:getDaysInMonth(self.date_month:getValue(), self.date_year:getValue())
            end
            self.value = self:changeValue(self.value, self.value_step * -1, self.value_max, self.value_min, self.wrap)
            self:update()
        end,
        hold_callback = function()
            if self.date_month and self.date_year then
                self.value_max = self:getDaysInMonth(self.date_month:getValue(), self.date_year:getValue())
            end
            self.value = self:changeValue(self.value, self.value_hold_step * -1, self.value_max, self.value_min, self.wrap)
            self:update()
        end
    }

    local empty_space = VerticalSpan:new{
        width = self.screen_height * 0.01
    }
    local value = self.value
    if self.value_table then
        local text_width = RenderText:sizeUtf8Text(0, self.width, self.spinner_face, self.value, true, true).x
        if self.width < text_width then
            value = RenderText:truncateTextByWidth(self.value, self.spinner_face, self.width,true, true)
        end
    else
        value = string.format(self.precision, value)
    end

    local input_dialog
    local callback_input = nil
    if self.value_table == nil then
        callback_input =  function()
            input_dialog = InputDialog:new{
                title = _("Enter number"),
                input = self.value,
                input_type = "number",
                buttons = {
                    {
                        {
                            text = _("Cancel"),
                            callback = function()
                                UIManager:close(input_dialog)
                            end,
                        },
                        {
                            text = _("OK"),
                            is_enter_default = true,
                            callback = function()
                                input_dialog:closeInputDialog()
                                local input_value = tonumber(input_dialog:getInputText())
                                if input_value and input_value >= self.value_min and input_value <= self.value_max then
                                    self.value = input_value
                                    self:update()
                                    UIManager:close(input_dialog)
                                elseif input_value and input_value < self.value_min then
                                    UIManager:show(InfoMessage:new{
                                        text = T(_("This value should be %1 or more."), self.value_min),
                                        timeout = 2,
                                    })
                                elseif input_value and input_value > self.value_max then
                                    UIManager:show(InfoMessage:new{
                                        text = T(_("This value should be %1 or less."), self.value_max),
                                        timeout = 2,
                                    })
                                else
                                    UIManager:show(InfoMessage:new{
                                        text = _("Invalid value. Please enter a valid value."),
                                        timeout = 2
                                    })
                                end
                            end,
                        },
                    },
                },
            }
            UIManager:show(input_dialog)
            input_dialog:onShowKeyboard()
        end
    end

    local text_value = Button:new{
        text = value,
        bordersize = 0,
        padding = 0,
        text_font_face = self.spinner_face_font,
        text_font_size = self.spinner_face_size,
        width = self.width,
        callback = callback_input,
    }
    return VerticalGroup:new{
        align = "center",
        button_up,
        empty_space,
        text_value,
        empty_space,
        button_down,
    }
end

--[[--
Update.
--]]
function NumberPickerWidget:update()
    local widget_spinner = self:paintWidget()
    self.frame = FrameContainer:new{
        bordersize = 0,
        padding = Size.padding.default,
        CenterContainer:new{
            align = "center",
            dimen = Geom:new{
                w = widget_spinner:getSize().w,
                h = widget_spinner:getSize().h
            },
            widget_spinner
        }
    }
    self.dimen = self.frame:getSize()
    self[1] = self.frame
    UIManager:setDirty(self.show_parent, function()
        return "ui", self.dimen
    end)
    self.update_callback()
end

--[[--
Change value.
--]]
function NumberPickerWidget:changeValue(value, step, max, min, wrap)
    if self.value_index then
        self.value_index = self.value_index + step
        if self.value_index > #self.value_table then
            self.value_index = wrap and 1 or #self.value_table
        elseif
        self.value_index < 1 then
            self.value_index = wrap and #self.value_table or 1
        end
        value = self.value_table[self.value_index]
    else
        value = value + step
        if value > max then
            value = wrap and min or max
        elseif value < min then
            value = wrap and max or min
        end
    end
    return value
end

--[[--
Get days in month.
--]]
function NumberPickerWidget:getDaysInMonth(month, year)
    local days_in_month = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    local days = days_in_month[month]
    -- check for leap year
    if (month == 2) then
        if year % 4 == 0 then
            if year % 100 == 0 then
                if year % 400 == 0 then
                    days = 29
                end
            else
                days = 29
            end
        end
    end
    return days
end

--[[--
Get value.
--]]
function NumberPickerWidget:getValue()
    return self.value
end

return NumberPickerWidget
