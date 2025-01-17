local logger = require("logger")
local _ = require("gettext")

local function yes() return true end
local function no() return false end

local Device = {
    screen_saver_mode = false,
    charging_mode = false,
    survive_screen_saver = false,
    is_cover_closed = false,
    should_restrict_JIT = false,
    model = nil,
    powerd = nil,
    screen = nil,
    screen_dpi_override = nil,
    input = nil,
    -- For Kobo, wait at least 15 seconds before calling suspend script. Otherwise, suspend might
    -- fail and the battery will be drained while we are in screensaver mode
    suspend_wait_timeout = 15,

    -- hardware feature tests: (these are functions!)
    hasKeyboard = no,
    hasKeys = no,
    hasDPad = no,
    hasWifiToggle = yes,
    hasWifiManager = no,
    isTouchDevice = no,
    hasFrontlight = no,
    hasLightLevelFallback = no,
    hasNaturalLight = no, -- FL warmth implementation specific to NTX boards (Kobo, Cervantes)
    hasNaturalLightMixer = no, -- Same, but only found on newer boards
    needsTouchScreenProbe = no,
    hasClipboard = yes, -- generic internal clipboard on all devices
    hasEinkScreen = yes,
    canHWDither = no,
    canHWInvert = no,
    canUseCBB = yes, -- The C BB maintains a 1:1 feature parity with the Lua BB, except that is has NO support for BB4, and limited support for BBRGB24
    hasColorScreen = no,
    hasBGRFrameBuffer = no,
    canToggleGSensor = no,
    canToggleMassStorage = no,
    canUseWAL = yes, -- requires mmap'ed I/O on the target FS
    canRestart = yes,
    canReboot = no,
    canPowerOff = no,

    -- use these only as a last resort. We should abstract the functionality
    -- and have device dependent implementations in the corresponting
    -- device/<devicetype>/device.lua file
    -- (these are functions!)
    isAndroid = no,
    isCervantes = no,
    isKindle = no,
    isKobo = no,
    isPocketBook = no,
    isSonyPRSTUX = no,
    isSDL = no,
    isEmulator = no,
    isDesktop = no,

    -- some devices have part of their screen covered by the bezel
    viewport = nil,
    -- enforce portrait orientation on display, no matter how configured at
    -- startup
    isAlwaysPortrait = no,
    -- needs full screen refresh when resumed from screensaver?
    needsScreenRefreshAfterResume = yes,

    -- set to yes on devices whose framebuffer reports 8bit per pixel,
    -- but is actually a color eInk screen with 24bit per pixel.
    -- The refresh is still based on bytes. (This solves issue #4193.)
    has3BytesWideFrameBuffer = no,

    -- set to yes on devices that support over-the-air incremental updates.
    hasOTAUpdates = no,

    canOpenLink = no,
    openLink = no,
    canExternalDictLookup = no,
}

function Device:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

-- Inverts PageTurn button mappings
-- NOTE: For ref. on Kobo, stored by Nickel in the [Reading] section as invertPageTurnButtons=true
function Device:invertButtons()
    if self:hasKeys() and self.input and self.input.event_map then
        for key, value in pairs(self.input.event_map) do
            if value == "LPgFwd" then
                self.input.event_map[key] = "LPgBack"
            elseif value == "LPgBack" then
                self.input.event_map[key] = "LPgFwd"
            elseif value == "RPgFwd" then
                self.input.event_map[key] = "RPgBack"
            elseif value == "RPgBack" then
                self.input.event_map[key] = "RPgFwd"
            end
        end

        -- NOTE: We currently leave self.input.rotation_map alone,
        --       which will definitely yield fairly stupid mappings in Landscape...
    end
end

function Device:init()
    assert(self ~= nil)
    if not self.screen then
        error("screen/framebuffer must be implemented")
    end

    if self.hasMultitouch == nil then
        -- default to assuming multitouch when dealing with a touch device
        self.hasMultitouch = self.isTouchDevice
    end

    self.screen.isColorScreen = self.hasColorScreen
    self.screen.isColorEnabled = function()
        if G_reader_settings:has("color_rendering") then
            return G_reader_settings:isTrue("color_rendering")
        else
            return self.screen.isColorScreen()
        end
    end

    self.screen.isBGRFrameBuffer = self.hasBGRFrameBuffer

    local low_pan_rate = G_reader_settings:readSetting("low_pan_rate")
    if low_pan_rate ~= nil then
        self.screen.low_pan_rate = low_pan_rate
    else
        self.screen.low_pan_rate = self.hasEinkScreen()
    end

    logger.info("initializing for device", self.model)
    logger.info("framebuffer resolution:", self.screen:getSize())

    if not self.input then
        self.input = require("device/input"):new{device = self}
    end
    if not self.powerd then
        self.powerd = require("device/generic/powerd"):new{device = self}
    end

    if self.viewport then
        logger.dbg("setting a viewport:", self.viewport)
        self.screen:setViewport(self.viewport)
        self.input:registerEventAdjustHook(
            self.input.adjustTouchTranslate,
            {x = 0 - self.viewport.x, y = 0 - self.viewport.y})
    end

    -- Handle button mappings shenanigans
    if self:hasKeys() then
        if G_reader_settings:isTrue("input_invert_page_turn_keys") then
            self:invertButtons()
        end
    end
end

function Device:setScreenDPI(dpi_override)
    self.screen:setDPI(dpi_override)
    self.input.gesture_detector:init()
    self.screen_dpi_override = dpi_override
end

function Device:getPowerDevice()
    return self.powerd
end

function Device:rescheduleSuspend()
    local UIManager = require("ui/uimanager")
    UIManager:unschedule(self.suspend)
    UIManager:scheduleIn(self.suspend_wait_timeout, self.suspend)
end

-- ONLY used for Kobo and PocketBook devices
function Device:onPowerEvent(ev)
    if self.screen_saver_mode then
        if ev == "Power" or ev == "Resume" then
            if self.is_cover_closed then
                -- don't let power key press wake up device when the cover is in closed state
                self:rescheduleSuspend()
            else
                logger.dbg("Resuming...")
                local UIManager = require("ui/uimanager")
                UIManager:unschedule(self.suspend)
                local network_manager = require("ui/network/manager")
                if network_manager.wifi_was_on and G_reader_settings:isTrue("auto_restore_wifi") then
                    network_manager:restoreWifiAsync()
                    network_manager:scheduleConnectivityCheck()
                end
                self:resume()
                -- restore to previous rotation mode, if need be.
                if self.orig_rotation_mode then
                    self.screen:setRotationMode(self.orig_rotation_mode)
                end
                require("ui/screensaver"):close()
                if self:needsScreenRefreshAfterResume() then
                    UIManager:scheduleIn(1, function() self.screen:refreshFull() end)
                end
                self.screen_saver_mode = false
                self.powerd:afterResume()
            end
        elseif ev == "Suspend" then
            -- Already in screen saver mode, no need to update UI/state before
            -- suspending the hardware. This usually happens when sleep cover
            -- is closed after the device was sent to suspend state.
            logger.dbg("Already in screen saver mode, suspending...")
            self:rescheduleSuspend()
        end
    -- else we were not in screensaver mode
    elseif ev == "Power" or ev == "Suspend" then
        self.powerd:beforeSuspend()
        local UIManager = require("ui/uimanager")
        logger.dbg("Suspending...")
        -- Mostly always suspend in portrait mode...
        -- ... except when we just show an InfoMessage, it plays badly with landscape mode (c.f., #4098)
        if G_reader_settings:readSetting("screensaver_type") ~= "message" then
            self.orig_rotation_mode = self.screen:getRotationMode()
            self.screen:setRotationMode(0)

            -- On eInk, if we're using a screensaver mode that shows an image,
            -- flash the screen to white first, to eliminate ghosting.
            if self:hasEinkScreen() and
               G_reader_settings:readSetting("screensaver_type") == "cover" or
               G_reader_settings:readSetting("screensaver_type") == "random_image" or
               G_reader_settings:readSetting("screensaver_type") == "image_file" then
                if not G_reader_settings:isTrue("screensaver_no_background") then
                    self.screen:clear()
                end
                self.screen:refreshFull()
            end
        else
            -- nil it, in case user switched ScreenSaver modes during our lifetime.
            self.orig_rotation_mode = nil
        end
        require("ui/screensaver"):show()
        if self:needsScreenRefreshAfterResume() then
            self.screen:refreshFull()
        end
        self.screen_saver_mode = true
        UIManager:scheduleIn(0.1, function()
          local network_manager = require("ui/network/manager")
          -- NOTE: wifi_was_on does not necessarily mean that WiFi is *currently* on! It means *we* enabled it.
          --       This is critical on Kobos (c.f., #3936), where it might still be on from KSM or Nickel,
          --       without us being aware of it (i.e., wifi_was_on still unset or false),
          --       because suspend will at best fail, and at worst deadlock the system if WiFi is on,
          --       regardless of who enabled it!
          if network_manager.wifi_was_on or network_manager:isWifiOn() then
              network_manager:releaseIP()
              network_manager:turnOffWifi()
          end
          UIManager:scheduleIn(self.suspend_wait_timeout, self.suspend)
        end)
    end
end

-- Hardware specific method to handle usb plug in event
function Device:usbPlugIn() end

-- Hardware specific method to handle usb plug out event
function Device:usbPlugOut() end

-- Hardware specific method to suspend the device
function Device:suspend() end

-- Hardware specific method to resume the device
function Device:resume() end

-- Hardware specific method to power off the device
function Device:powerOff() end

-- Hardware specific method to reboot the device
function Device:reboot() end

-- Hardware specific method to initialize network manager module
function Device:initNetworkManager() end

function Device:supportsScreensaver() return false end

-- Device specific method to set datetime
function Device:setDateTime(year, month, day, hour, min, sec) end

-- Device specific method if any setting needs being saved
function Device:saveSettings() end

-- Device specific method for toggling the GSensor
function Device:toggleGSensor(toggle) end

-- Device specific method for set custom light levels
function Device:setScreenBrightness(level) end

--[[
prepare for application shutdown
--]]
function Device:exit()
    require("ffi/input"):closeAll()
    self.screen:close()
end

function Device:retrieveNetworkInfo()
    local std_out = io.popen("ifconfig | " ..
                             "sed -n " ..
                             "-e 's/ \\+$//g' " ..
                             "-e 's/ \\+/ /g' " ..
                             "-e 's/ \\?inet6\\? addr: \\?\\([^ ]\\+\\) .*$/IP: \\1/p' " ..
                             "-e 's/Link encap:Ethernet\\(.*\\)/\\1/p'",
                             "r")
    if std_out then
        local result = std_out:read("*all")
        std_out:close()
        std_out = io.popen('2>/dev/null iwconfig | grep ESSID | cut -d\\" -f2')
        if std_out then
            local ssid = std_out:read("*all")
            result = result .. "SSID: " .. ssid:gsub("(.-)%s*$", "%1") .. "\n"
            std_out:close()
        end
        if os.execute("ip r | grep -q default") == 0 then
            -- NOTE: No -w flag available in the old busybox build used on Legacy Kindles...
            local pingok
            if self:isKindle() and self:hasKeyboard() then
                pingok = os.execute("ping -q -c 2 `ip r | grep default | tail -n 1 | cut -d ' ' -f 3` > /dev/null")
            else
                pingok = os.execute("ping -q -w 3 -c 2 `ip r | grep default | tail -n 1 | cut -d ' ' -f 3` > /dev/null")
            end
            if pingok == 0 then
                result = result .. "Gateway ping successful"
            else
                result = result .. "Gateway ping FAILED"
            end
        else
            result = result .. "No default gateway to ping"
        end
        return result
    end
end

function Device:setTime(hour, min)
        return false
end

-- Return an integer value to indicate the brightness of the environment. The value should be in
-- range [0, 4].
-- 0: dark.
-- 1: dim, frontlight is needed.
-- 2: neutral, turning frontlight on or off does not impact the reading experience.
-- 3: bright, frontlight is not needed.
-- 4: dazzling.
function Device:ambientBrightnessLevel()
    return 0
end

return Device
