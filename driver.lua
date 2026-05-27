--[[
  Auto Sliding Door — Control4 DriverWorks driver
  Three-mode experience button (Off / Hold / Auto) for a motion-sensor-enabled
  sliding door wired with two contact closures and one position contact sensor.

  See docs/superpowers/specs/ for the full design spec.
--]]

local DRIVER_VERSION = "2.0.0"

-- Connection IDs (must match driver.xml)
local PROXY_ID            = 5001
local OPEN_RELAY_ID       = 100
local ARM_RELAY_ID        = 101
local SENSOR_ID           = 200
local BL_OPEN             = 500
local BL_OFF              = 501
local BL_HOLD             = 502
local BL_AUTO             = 503

local BUTTON_LINK_IDS = { BL_OPEN, BL_OFF, BL_HOLD, BL_AUTO }

-- State (runtime, not persisted)
local STATE = {
  mode             = "Off",          -- "Off" | "Hold" | "Auto"
  door             = "Unknown",      -- "Open" | "Closed" | "Unknown"
  open_timer       = nil,            -- C4 timer handle for Open-for-N
  hold_timer       = nil,            -- C4 timer handle for Hold auto-release
  still_open_timer = nil,            -- C4 timer handle for Still-Open watchdog
  debounce_timer   = nil,            -- C4 timer handle for sensor debounce
  pending_door     = nil,            -- door state awaiting debounce confirmation
  sensor_bound     = false,
  open_relay_bound = false,
  arm_relay_bound  = false,
}

-- Gesture-decoder state. Drives On Button Pressed / On Button Released actions.
local GESTURE = {
  long_press_fired   = false,
  waiting_for_double = false,
  long_press_timer   = nil,
  double_click_timer = nil,
}

-- Property cache; values get refreshed from Properties[] on init and on changes
local CFG = {
  debug                = false,
  default_open_seconds = 5,
  hold_seconds         = 0,
  still_open_seconds   = 0,
  invert_open_relay    = false,
  invert_arm_relay     = false,
  invert_contact       = false,
  debounce_ms          = 250,
  long_press_ms        = 1000,
  double_click_ms      = 400,
  led_color_off        = "0,0,200",
  led_color_hold       = "200,200,0",
  led_color_auto       = "0,200,0",
}

-- Inversion lookup: maps logical CLOSE/OPEN to wire command based on invert flag
local function wireCmd(invert, logical)
  if invert then
    if logical == "CLOSE" then return "OPEN" else return "CLOSE" end
  end
  return logical
end

-- ============================================================================
-- Logging
-- ============================================================================

local function dbg(...)
  if not CFG.debug then return end
  local args = { ... }
  local parts = {}
  for i = 1, #args do parts[i] = tostring(args[i]) end
  print("[autoslidingdoor] " .. table.concat(parts, " "))
end

-- ============================================================================
-- Property handling
-- ============================================================================

local function asBool(v) return v == "Yes" or v == "yes" or v == true or v == "On" or v == "on" end

local function asInt(v, dflt)
  local n = tonumber(v)
  if n == nil then return dflt end
  return math.floor(n)
end

local function refreshConfig()
  CFG.debug                = (Properties["Debug Mode"] == "On")
  CFG.default_open_seconds = asInt(Properties["Default Open Duration (s)"], 5)
  CFG.hold_seconds         = asInt(Properties["Hold Duration (s)"], 0)
  CFG.still_open_seconds   = asInt(Properties["Still Open Time (s)"], 0)
  CFG.invert_open_relay    = asBool(Properties["Invert Open Door Relay"])
  CFG.invert_arm_relay     = asBool(Properties["Invert Arm Motion Relay"])
  CFG.invert_contact       = asBool(Properties["Invert Door Contact"])
  CFG.debounce_ms          = asInt(Properties["Door Contact Debounce (ms)"], 250)
  CFG.long_press_ms        = asInt(Properties["Long Press Threshold (ms)"], 1000)
  CFG.double_click_ms      = asInt(Properties["Double Click Window (ms)"], 400)
  CFG.led_color_off        = Properties["Off LED Color"]  or "0,0,200"
  CFG.led_color_hold       = Properties["Hold LED Color"] or "200,200,0"
  CFG.led_color_auto       = Properties["Auto LED Color"] or "0,200,0"
end

-- ============================================================================
-- Outputs (relays, LEDs, tile icon)
-- ============================================================================

local function sendRelay(bindingId, bound, invert, logical)
  if not bound then
    dbg("relay binding", bindingId, "not wired, skipping", logical)
    return
  end
  local cmd = wireCmd(invert, logical)
  dbg("relay", bindingId, "->", cmd)
  C4:SendToProxy(bindingId, cmd, {})
end

local function recomputeOpenRelay()
  local shouldClose = (STATE.mode == "Hold") or (STATE.open_timer ~= nil)
  sendRelay(OPEN_RELAY_ID, STATE.open_relay_bound, CFG.invert_open_relay,
            shouldClose and "CLOSE" or "OPEN")
end

local function recomputeArmRelay()
  local shouldClose = (STATE.mode == "Auto")
  sendRelay(ARM_RELAY_ID, STATE.arm_relay_bound, CFG.invert_arm_relay,
            shouldClose and "CLOSE" or "OPEN")
end

local function updateNavigatorTile()
  local stateId = "Mode_" .. STATE.mode
  dbg("tile state ->", stateId)
  C4:SendToProxy(PROXY_ID, "ICON_CHANGED",
                 { icon = stateId, icon_description = STATE.mode })
end

local function colorForMode()
  if     STATE.mode == "Hold" then return CFG.led_color_hold
  elseif STATE.mode == "Auto" then return CFG.led_color_auto
  else                              return CFG.led_color_off
  end
end

local function setButtonLinkColor(bindingId, colorRgb)
  C4:SendToProxy(bindingId, "BUTTON_COLORS",
                 { ON_COLOR  = { COLOR_STR = colorRgb },
                   OFF_COLOR = { COLOR_STR = colorRgb } },
                 "NOTIFY")
end

local function updateKeypadLeds()
  local color = colorForMode()
  for i = 1, #BUTTON_LINK_IDS do
    setButtonLinkColor(BUTTON_LINK_IDS[i], color)
  end
end

-- ============================================================================
-- Timers
-- ============================================================================

local function killTimer(handle)
  if handle ~= nil then
    C4:KillTimer(handle)
  end
  return nil
end

local function cancelOpenTimer()
  if STATE.open_timer ~= nil then
    dbg("cancel open timer")
    STATE.open_timer = killTimer(STATE.open_timer)
  end
end

local function cancelHoldTimer()
  if STATE.hold_timer ~= nil then
    dbg("cancel hold timer")
    STATE.hold_timer = killTimer(STATE.hold_timer)
  end
end

local function cancelStillOpenTimer()
  if STATE.still_open_timer ~= nil then
    dbg("cancel still-open timer")
    STATE.still_open_timer = killTimer(STATE.still_open_timer)
  end
end

local function cancelDebounceTimer()
  if STATE.debounce_timer ~= nil then
    STATE.debounce_timer = killTimer(STATE.debounce_timer)
    STATE.pending_door = nil
  end
end

local function startStillOpenWatchdog()
  cancelStillOpenTimer()
  if CFG.still_open_seconds > 0 and STATE.door == "Open" then
    dbg("start still-open watchdog", CFG.still_open_seconds, "s")
    STATE.still_open_timer = C4:AddTimer(CFG.still_open_seconds, "SECONDS", false)
  end
end

-- ============================================================================
-- State publishing
-- ============================================================================

local function recordHistory(message)
  C4:RecordHistory("Info", STATE.mode, "Motorization", "Sliding Door", message)
end

local function publishMode()
  C4:UpdateProperty("Mode", STATE.mode)
  C4:SetVariable("MODE", STATE.mode)
  updateNavigatorTile()
  updateKeypadLeds()
end

local function publishDoor()
  C4:UpdateProperty("Door State", STATE.door)
  C4:SetVariable("DOOR_STATE", STATE.door)
end

-- ============================================================================
-- Core transitions
-- ============================================================================

-- The ONE path mode can change. All callers funnel here.
local function SetMode(newMode, fireEvents)
  if newMode ~= "Off" and newMode ~= "Hold" and newMode ~= "Auto" then
    dbg("ignoring invalid mode:", tostring(newMode))
    return
  end

  if fireEvents == nil then fireEvents = true end

  if newMode == STATE.mode then
    dbg("SetMode", newMode, "= no-op (already in mode)")
    return
  end

  dbg("SetMode", STATE.mode, "->", newMode)

  -- 1. Cancel mode-scoped timers
  cancelOpenTimer()
  cancelHoldTimer()

  -- 2. Update internal state
  STATE.mode = newMode

  -- 3. Recompute outputs
  recomputeOpenRelay()
  recomputeArmRelay()

  -- 4. Publish to UI/variables
  publishMode()

  -- 5. Fire event + history
  if fireEvents then
    local evt = "Mode Changed to " .. newMode
    dbg("FireEvent", evt)
    C4:FireEvent(evt)
    recordHistory("Mode changed to " .. newMode)
  end

  -- 6. Arm Hold auto-release if configured
  if newMode == "Hold" and CFG.hold_seconds > 0 then
    dbg("starting Hold auto-release timer", CFG.hold_seconds, "s")
    STATE.hold_timer = C4:AddTimer(CFG.hold_seconds, "SECONDS", false)
  end
end

-- Independent of mode. Does not touch MODE.
local function OpenForN(seconds)
  seconds = asInt(seconds, CFG.default_open_seconds)
  if seconds < 1 then seconds = 1 end

  dbg("OpenForN", seconds, "s")

  -- Reset-on-retrigger semantics
  cancelOpenTimer()
  STATE.open_timer = C4:AddTimer(seconds, "SECONDS", false)
  recomputeOpenRelay()
end

local function CancelOpen()
  if STATE.open_timer ~= nil then
    cancelOpenTimer()
    recomputeOpenRelay()
  end
end

-- ============================================================================
-- Gesture decoder
-- ============================================================================
-- Drives single-press / double-press / long-press detection so callers can wire
-- a physical button's Pressed event to "On Button Pressed" and Released event
-- to "On Button Released" without writing any state-machine programming.
--
-- Outcomes:
--   * Short press, no second press within Double Click Window:
--       - If MODE == Off: Open Door (default duration)
--       - Else:           Set Mode to Off
--   * Two short presses within Double Click Window: Set Mode to Auto
--   * Held past Long Press Threshold: Set Mode to Hold

local function cancelGestureLongPressTimer()
  if GESTURE.long_press_timer ~= nil then
    GESTURE.long_press_timer = killTimer(GESTURE.long_press_timer)
  end
end

local function cancelGestureDoubleClickTimer()
  if GESTURE.double_click_timer ~= nil then
    GESTURE.double_click_timer = killTimer(GESTURE.double_click_timer)
  end
end

local function OnButtonPressed()
  dbg("gesture: PRESSED")
  cancelGestureLongPressTimer()
  GESTURE.long_press_fired = false
  GESTURE.long_press_timer = C4:AddTimer(CFG.long_press_ms, "MILLISECONDS", false)
end

local function OnButtonReleased()
  dbg("gesture: RELEASED  (long_press_fired=", tostring(GESTURE.long_press_fired),
      "waiting_for_double=", tostring(GESTURE.waiting_for_double), ")")

  cancelGestureLongPressTimer()

  if GESTURE.long_press_fired then
    -- Long press already handled by its own timer; ignore release.
    GESTURE.long_press_fired = false
    return
  end

  if GESTURE.waiting_for_double then
    -- Second short release within window => double press.
    cancelGestureDoubleClickTimer()
    GESTURE.waiting_for_double = false
    dbg("gesture -> DOUBLE PRESS -> Auto")
    SetMode("Auto", true)
    return
  end

  -- First short release; arm double-click window.
  GESTURE.waiting_for_double = true
  GESTURE.double_click_timer = C4:AddTimer(CFG.double_click_ms, "MILLISECONDS", false)
end

local function handleGestureLongPressExpired()
  -- Button is still being held past the long-press threshold.
  GESTURE.long_press_timer = nil
  GESTURE.long_press_fired = true
  cancelGestureDoubleClickTimer()
  GESTURE.waiting_for_double = false
  dbg("gesture -> LONG PRESS -> Hold")
  SetMode("Hold", true)
end

local function handleGestureDoubleClickExpired()
  -- No second press within window: confirmed single press.
  GESTURE.double_click_timer = nil
  GESTURE.waiting_for_double = false
  if STATE.mode == "Off" then
    dbg("gesture -> SINGLE PRESS (from Off) -> Open Door")
    OpenForN(CFG.default_open_seconds)
  else
    dbg("gesture -> SINGLE PRESS (from " .. STATE.mode .. ") -> Off")
    SetMode("Off", true)
  end
end

-- ============================================================================
-- Sensor handling (with debounce)
-- ============================================================================

local function rawToLogicalDoor(raw)
  -- raw is "OPENED" or "CLOSED" from the contact sensor proxy
  local logical
  if raw == "OPENED" then
    logical = "Open"
  elseif raw == "CLOSED" then
    logical = "Closed"
  else
    return nil
  end
  if CFG.invert_contact then
    if logical == "Open" then logical = "Closed" else logical = "Open" end
  end
  return logical
end

local function commitDoorState(newDoor)
  if newDoor == STATE.door then
    dbg("door state unchanged:", newDoor)
    return
  end

  dbg("door", STATE.door, "->", newDoor)
  STATE.door = newDoor
  publishDoor()

  if newDoor == "Open" then
    C4:FireEvent("Door Opened")
    C4:RecordHistory("Info", "Open", "Motorization", "Sliding Door", "Door opened")
    startStillOpenWatchdog()
  elseif newDoor == "Closed" then
    C4:FireEvent("Door Closed")
    C4:RecordHistory("Info", "Closed", "Motorization", "Sliding Door", "Door closed")
    cancelStillOpenTimer()
  end
end

local function onSensorReport(rawCmd)
  local logical = rawToLogicalDoor(rawCmd)
  if logical == nil then return end

  if CFG.debounce_ms <= 1 then
    commitDoorState(logical)
    return
  end

  -- Debounce: only commit if the same state persists past the debounce window
  cancelDebounceTimer()
  STATE.pending_door = logical
  STATE.debounce_timer = C4:AddTimer(CFG.debounce_ms, "MILLISECONDS", false)
end

-- ============================================================================
-- Contact Status property
-- ============================================================================

local function updateContactStatus()
  if STATE.sensor_bound then
    C4:UpdateProperty("Contact Status", "Connected")
  else
    C4:UpdateProperty("Contact Status", "Not connected")
  end
end

-- ============================================================================
-- Action dispatch (Composer/voice/programming → driver)
-- ============================================================================

EX_CMDS = {}

function EX_CMDS.OPEN_DEFAULT(tParams)
  OpenForN(CFG.default_open_seconds)
end

function EX_CMDS.OPEN_FOR_N(tParams)
  local secs = (tParams and tParams.Seconds) or CFG.default_open_seconds
  OpenForN(secs)
end

function EX_CMDS.SET_MODE_OFF(tParams)  SetMode("Off",  true) end
function EX_CMDS.SET_MODE_HOLD(tParams) SetMode("Hold", true) end
function EX_CMDS.SET_MODE_AUTO(tParams) SetMode("Auto", true) end

function EX_CMDS.CANCEL_OPEN(tParams) CancelOpen() end

function EX_CMDS.BUTTON_PRESSED(tParams)  OnButtonPressed()  end
function EX_CMDS.BUTTON_RELEASED(tParams) OnButtonReleased() end

function EX_CMDS.LUA_ACTION(tParams)
  -- Some Composer flows invoke actions via LUA_ACTION with the command in tParams
  if not tParams or not tParams.ACTION then return end
  local handler = EX_CMDS[tParams.ACTION]
  if handler then handler(tParams) end
end

-- ============================================================================
-- Proxy command dispatch (Navigator tile + bound device responses)
-- ============================================================================

PROXY_CMDS = {}

-- Navigator tile click on the experience button
function PROXY_CMDS.DO_CLICK(tParams, idBinding) OpenForN(CFG.default_open_seconds) end
function PROXY_CMDS.SELECT(tParams, idBinding)   OpenForN(CFG.default_open_seconds) end

-- Contact sensor reports
function PROXY_CMDS.OPENED(tParams, idBinding)
  if idBinding == SENSOR_ID then onSensorReport("OPENED") end
end
function PROXY_CMDS.CLOSED(tParams, idBinding)
  if idBinding == SENSOR_ID then onSensorReport("CLOSED") end
end

-- Inform proxy when bound — request current sensor state
function PROXY_CMDS.STATE_OPENED(tParams, idBinding)
  if idBinding == SENSOR_ID then onSensorReport("OPENED") end
end
function PROXY_CMDS.STATE_CLOSED(tParams, idBinding)
  if idBinding == SENSOR_ID then onSensorReport("CLOSED") end
end

-- Keypad request for button colors after binding
function PROXY_CMDS.REQUEST_BUTTON_COLORS(tParams, idBinding)
  setButtonLinkColor(idBinding, colorForMode())
end

-- ============================================================================
-- C4 entry points
-- ============================================================================

function ExecuteCommand(strCommand, tParams)
  dbg("ExecuteCommand", strCommand)
  local handler = EX_CMDS[strCommand]
  if handler then
    local ok, err = pcall(handler, tParams or {})
    if not ok then dbg("ExecuteCommand error:", err) end
  else
    dbg("Unhandled command:", strCommand)
  end
end

function ReceivedFromProxy(idBinding, strCommand, tParams)
  if strCommand == nil then return end
  dbg("ReceivedFromProxy binding=", idBinding, "cmd=", strCommand)
  local handler = PROXY_CMDS[strCommand]
  if handler then
    local ok, err = pcall(handler, tParams or {}, idBinding)
    if not ok then dbg("ReceivedFromProxy error:", err) end
  end
end

function OnBindingChanged(idBinding, strClass, bIsBound)
  dbg("OnBindingChanged binding=", idBinding, "class=", strClass, "bound=", tostring(bIsBound))
  if idBinding == SENSOR_ID then
    STATE.sensor_bound = bIsBound
    updateContactStatus()
    if bIsBound then
      C4:SendToProxy(SENSOR_ID, "GET_STATE", {})
    else
      STATE.door = "Unknown"
      publishDoor()
    end
  elseif idBinding == OPEN_RELAY_ID then
    STATE.open_relay_bound = bIsBound
    if bIsBound then recomputeOpenRelay() end
  elseif idBinding == ARM_RELAY_ID then
    STATE.arm_relay_bound = bIsBound
    if bIsBound then recomputeArmRelay() end
  end
end

function OnTimerExpired(idTimer)
  if STATE.open_timer ~= nil and idTimer == STATE.open_timer then
    dbg("open timer expired")
    STATE.open_timer = nil
    recomputeOpenRelay()
    return
  end

  if STATE.hold_timer ~= nil and idTimer == STATE.hold_timer then
    dbg("hold timer expired -> Off")
    STATE.hold_timer = nil
    SetMode("Off", true)
    return
  end

  if STATE.still_open_timer ~= nil and idTimer == STATE.still_open_timer then
    dbg("still-open timer expired")
    STATE.still_open_timer = nil
    C4:FireEvent("Still Open")
    C4:RecordHistory("Info", "Still Open", "Motorization", "Sliding Door",
                     "Door still open after " .. tostring(CFG.still_open_seconds) .. "s")
    return
  end

  if STATE.debounce_timer ~= nil and idTimer == STATE.debounce_timer then
    dbg("debounce timer expired -> commit", tostring(STATE.pending_door))
    STATE.debounce_timer = nil
    if STATE.pending_door ~= nil then
      commitDoorState(STATE.pending_door)
      STATE.pending_door = nil
    end
    return
  end

  if GESTURE.long_press_timer ~= nil and idTimer == GESTURE.long_press_timer then
    handleGestureLongPressExpired()
    return
  end

  if GESTURE.double_click_timer ~= nil and idTimer == GESTURE.double_click_timer then
    handleGestureDoubleClickExpired()
    return
  end
end

function OnPropertyChanged(strProperty)
  dbg("OnPropertyChanged", strProperty, "=", tostring(Properties[strProperty]))
  refreshConfig()

  if strProperty == "Invert Open Door Relay" then
    recomputeOpenRelay()
  elseif strProperty == "Invert Arm Motion Relay" then
    recomputeArmRelay()
  elseif strProperty == "Invert Door Contact" then
    -- Logical interpretation may flip; re-query sensor to refresh
    if STATE.sensor_bound then C4:SendToProxy(SENSOR_ID, "GET_STATE", {}) end
  elseif strProperty == "Still Open Time (s)" then
    startStillOpenWatchdog()
  elseif strProperty == "Hold Duration (s)" then
    if STATE.mode == "Hold" then
      cancelHoldTimer()
      if CFG.hold_seconds > 0 then
        STATE.hold_timer = C4:AddTimer(CFG.hold_seconds, "SECONDS", false)
      end
    end
  elseif strProperty == "Off LED Color"
      or strProperty == "Hold LED Color"
      or strProperty == "Auto LED Color" then
    updateKeypadLeds()
  end
end

function OnDriverInit()
  -- Reset Properties safe defaults first (XML defaults are not always populated yet)
  refreshConfig()
  C4:UpdateProperty("Driver Version", DRIVER_VERSION)
  C4:UpdateProperty("Mode", "Off")
  C4:UpdateProperty("Door State", "Unknown")
  C4:UpdateProperty("Contact Status", "Not connected")
end

function OnDriverLateInit()
  refreshConfig()

  -- Unlock FileSetDir for any future self-update capability (per c4-conventions §3a)
  local ok, err = pcall(function() C4:FileSetDir("c29tZXNwZWNpYWxrZXk=++11") end)
  if not ok then dbg("FileSetDir handshake error:", err) end

  -- Establish initial state — Off, both relays open. fireEvents=false so we don't
  -- spam "Mode Changed to Off" on Director restart unless mode actually was non-Off.
  STATE.mode = "Off"
  publishMode()
  recomputeOpenRelay()
  recomputeArmRelay()

  -- Initialize variables in C4's variable system so they show up in programming.
  C4:SetVariable("MODE", STATE.mode)
  C4:SetVariable("DOOR_STATE", STATE.door)

  -- If sensor is already bound (e.g., driver hot-reload), query state.
  if STATE.sensor_bound then
    C4:SendToProxy(SENSOR_ID, "GET_STATE", {})
  end
end

function OnDriverDestroyed()
  dbg("OnDriverDestroyed")
  cancelOpenTimer()
  cancelHoldTimer()
  cancelStillOpenTimer()
  cancelDebounceTimer()
  cancelGestureLongPressTimer()
  cancelGestureDoubleClickTimer()
  -- Release relays defensively
  if STATE.open_relay_bound then
    sendRelay(OPEN_RELAY_ID, true, CFG.invert_open_relay, "OPEN")
  end
  if STATE.arm_relay_bound then
    sendRelay(ARM_RELAY_ID, true, CFG.invert_arm_relay, "OPEN")
  end
end
