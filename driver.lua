--[[
  Auto Sliding Door — Control4 DriverWorks driver
  Three-mode experience button (Off / Hold / Auto) for a motion-sensor-enabled
  sliding door wired with two contact closures and one position contact sensor.

  See docs/superpowers/specs/ for the full design spec.
--]]

local DRIVER_VERSION = "2.1.1"

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

-- Director variables (issue #3). Addressed by NAME, never by the return value
-- of C4:AddVariable, which is a boolean rather than an ID (c4-conventions §2).
-- Both are created read-only in OnDriverInit: the driver has no
-- OnVariableChanged handler, so a programming write would desync the variable
-- from STATE. Mode changes go through the Set Mode actions only.
local VAR = {
  MODE       = "MODE",        -- "Off" | "Hold" | "Auto"
  DOOR_STATE = "DOOR_STATE",  -- "Open" | "Closed" | "Unknown"
}

-- Device history (issue #4). For an entry to appear in the Control4 app's
-- History, two things must hold (c4-conventions §2, validated end to end in
-- control4-frigate #24 on OS 3.4.3):
--   1. Call the FOUR-argument form C4:RecordHistory(severity, eventType,
--      category, subcategory). There is no description parameter; eventType is
--      the text the app displays. The optional fifth argument is a metadata
--      table, and passing one stops the record being stored on OS 3.4.3.
--   2. Register the (category, subcategory, type) tuple with
--      C4:RegisterEvents. Navigator silently hides stored records that match
--      no registration (they still show in the History agent's data tab).
-- Recorder and registration share these constants so they cannot drift.
-- Category matches Control4's stock relay door drivers ("Locks & Sensors" /
-- "Door (Relay)"), so entries sit next to other doors in the app's filter.
local HISTORY_CATEGORY    = "Locks & Sensors"
local HISTORY_SUBCATEGORY = "Sliding Door"
local HISTORY = {
  MODE = {                                   -- keyed by STATE.mode
    Off  = "Mode Changed to Off",
    Hold = "Mode Changed to Hold",
    Auto = "Mode Changed to Auto",
  },
  DOOR_OPENED     = "Door Opened",
  DOOR_CLOSED     = "Door Closed",
  DOOR_STILL_OPEN = "Door Still Open",
}
-- Every type recordHistory() may be called with. All are registered.
local HISTORY_TYPES = {
  HISTORY.MODE.Off, HISTORY.MODE.Hold, HISTORY.MODE.Auto,
  HISTORY.DOOR_OPENED, HISTORY.DOOR_CLOSED, HISTORY.DOOR_STILL_OPEN,
}

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

-- Create the driver's Director variables. Safe to call on every init: on a
-- driver update in place the variables already exist and AddVariable is a
-- harmless no-op. Must run before anything calls setVar().
local function initVariables()
  -- Append new variables at the END only. Director appears to assign variable
  -- IDs in creation order and Composer programming refers to variables by ID,
  -- so inserting or reordering here could re-point existing programming.
  C4:AddVariable(VAR.MODE,       "Off",     "STRING", true, false)  -- return value ignored
  C4:AddVariable(VAR.DOOR_STATE, "Unknown", "STRING", true, false)
end

-- Write a Director variable without letting a fault escape. A raised error
-- here would abort the enclosing publish*() before the tile icon, keypad LEDs
-- and events behind it run (c4-conventions §2, "blast radius").
local function setVar(name, value)
  local ok, err = pcall(function() C4:SetVariable(name, tostring(value)) end)
  if not ok then
    print("[autoslidingdoor] SetVariable failed for " .. tostring(name) .. ": " .. tostring(err))
  end
end

-- Record one device-history entry. eventType must be one of HISTORY_TYPES
-- (anything else is stored but never shown in the app). The UUID return value
-- is the only signal of whether Director stored the record, so a nil is always
-- reported, not just in debug mode. pcall'd so a history fault can never
-- abort the state handler that called it.
local function recordHistory(eventType, severity)
  severity = severity or "Info"
  local ok, uuid = pcall(function()
    return C4:RecordHistory(severity, eventType, HISTORY_CATEGORY, HISTORY_SUBCATEGORY)
  end)
  if ok and uuid ~= nil and uuid ~= "" then
    dbg("history recorded:", eventType, "(" .. tostring(uuid) .. ")")
  elseif ok then
    print("[autoslidingdoor] RecordHistory did not store '" .. tostring(eventType)
          .. "' (nil UUID). Is the History agent installed?")
  else
    print("[autoslidingdoor] RecordHistory error for '" .. tostring(eventType)
          .. "': " .. tostring(uuid))
  end
end

local function xmlEscape(str)
  return (tostring(str):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
                       :gsub('"', "&quot;"):gsub("'", "&apos;"))
end

-- The proxy device id that history is registered against. Frigate (validated
-- on OS 3.4.3) treats C4:GetProxyDevices() as a table keyed by device id; a
-- bare number is accepted too in case a firmware returns the single id.
local function getProxyDeviceId()
  local ok, devs = pcall(function() return C4:GetProxyDevices() end)
  if not ok then return nil end
  if type(devs) == "number" then return devs end
  if type(devs) == "string" then return tonumber(devs) end
  if type(devs) == "table" then
    for id in pairs(devs) do return id end
  end
  return nil
end

-- Declare every history type this device records, so Navigator renders them.
-- Called on every driver load from OnDriverLateInit.
local function registerHistoryEvents()
  local deviceId = getProxyDeviceId()
  if not deviceId then
    print("[autoslidingdoor] RegisterEvents skipped: no proxy device id. "
          .. "History will be stored but not shown in the Control4 app.")
    return
  end
  local types = {}
  for i = 1, #HISTORY_TYPES do
    types[i] = '<type name="' .. xmlEscape(HISTORY_TYPES[i]) .. '"/>'
  end
  local xml = '<events>'
    .. '<device id="' .. tostring(deviceId) .. '"/>'
    .. '<categories><category name="' .. xmlEscape(HISTORY_CATEGORY) .. '">'
    .. '<subcategories><subcategory name="' .. xmlEscape(HISTORY_SUBCATEGORY) .. '">'
    .. '<types>' .. table.concat(types) .. '</types>'
    .. '</subcategory></subcategories>'
    .. '</category></categories></events>'
  local ok, result = pcall(function() return C4:RegisterEvents(xml) end)
  -- 0 is Director's success code (as checked in control4-frigate). Anything
  -- else, nil included, is reported: an unregistered device's history is
  -- stored but never shown in the app, and that is otherwise invisible.
  if ok and result == 0 then
    dbg("registered", #HISTORY_TYPES, "history types for device", deviceId)
  else
    print("[autoslidingdoor] RegisterEvents returned " .. tostring(result)
          .. ". History may not appear in the Control4 app.")
  end
end

local function publishMode()
  C4:UpdateProperty("Mode", STATE.mode)
  setVar(VAR.MODE, STATE.mode)
  updateNavigatorTile()
  updateKeypadLeds()
end

local function publishDoor()
  C4:UpdateProperty("Door State", STATE.door)
  setVar(VAR.DOOR_STATE, STATE.door)
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
    recordHistory(HISTORY.MODE[newMode])
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
    recordHistory(HISTORY.DOOR_OPENED)
    startStillOpenWatchdog()
  elseif newDoor == "Closed" then
    C4:FireEvent("Door Closed")
    recordHistory(HISTORY.DOOR_CLOSED)
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

-- Query the current bound state of one of our consumer bindings.
-- Used at init time because OnBindingChanged is NOT re-fired for bindings
-- that were already established before the driver code reloaded (issue #1).
local function isBindingWired(idBinding)
  local ok, providerBinding = pcall(function()
    return C4:GetBoundProviderBinding(C4:GetDeviceID(), idBinding)
  end)
  if not ok then
    dbg("GetBoundProviderBinding failed for", idBinding, "-", tostring(providerBinding))
    return false
  end
  return (providerBinding or 0) ~= 0
end

-- Re-seed all binding-state flags from Director and run any first-time
-- side effects (query sensor, recompute relays). Safe to call repeatedly.
local function syncBindingState()
  local prevSensor = STATE.sensor_bound
  local prevOpen   = STATE.open_relay_bound
  local prevArm    = STATE.arm_relay_bound

  STATE.sensor_bound     = isBindingWired(SENSOR_ID)
  STATE.open_relay_bound = isBindingWired(OPEN_RELAY_ID)
  STATE.arm_relay_bound  = isBindingWired(ARM_RELAY_ID)

  dbg("syncBindingState sensor=", tostring(STATE.sensor_bound),
      "open=", tostring(STATE.open_relay_bound),
      "arm=", tostring(STATE.arm_relay_bound))

  updateContactStatus()

  -- If sensor just became visible, ask it for current state.
  if STATE.sensor_bound and not prevSensor then
    C4:SendToProxy(SENSOR_ID, "GET_STATE", {})
  elseif (not STATE.sensor_bound) and prevSensor then
    STATE.door = "Unknown"
    publishDoor()
  end

  -- If relays just became visible, push current desired state to them.
  if STATE.open_relay_bound and not prevOpen then recomputeOpenRelay() end
  if STATE.arm_relay_bound  and not prevArm  then recomputeArmRelay()  end
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
  -- Defer to the canonical reseed path. Director's view is authoritative;
  -- bIsBound is informational. syncBindingState handles all the side effects.
  syncBindingState()
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
    recordHistory(HISTORY.DOOR_STILL_OPEN, "Warning")
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
  initVariables()   -- issue #3: before OnDriverLateInit's first setVar()
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

  -- Issue #4: declare history types before anything can record one.
  registerHistoryEvents()

  -- Establish initial state — Off, both relays open. fireEvents=false so we don't
  -- spam "Mode Changed to Off" on Director restart unless mode actually was non-Off.
  STATE.mode = "Off"
  publishMode()     -- seeds the MODE variable
  publishDoor()     -- seeds DOOR_STATE (Unknown until the sensor reports)
  recomputeOpenRelay()
  recomputeArmRelay()

  -- Critical: query Director for current binding state. OnBindingChanged is
  -- not re-fired for bindings that existed before this driver code loaded
  -- (issue #1). Without this, all *_bound flags stay false and the driver
  -- silently drops every relay command and sensor query.
  syncBindingState()
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
