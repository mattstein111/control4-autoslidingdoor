--[[
  Issue #4 — device history must be (a) stored and (b) visible in the app.

  (a) Only the four-argument C4:RecordHistory(severity, eventType, category,
      subcategory) form is proven to store on OS 3.4.3; the mock flags any
      other arity as a violation.
  (b) Navigator only renders a stored record whose (category, subcategory,
      type) matches a C4:RegisterEvents registration; the mock flags an
      unregistered tuple as a violation.

  Since every test fails on a recorded violation, the baseline mode/door tests
  also guard this from now on. These cases pin the exact contract.
--]]

local OPEN_RELAY, ARM_RELAY, SENSOR = 100, 101, 200
local ALL = { OPEN_RELAY, ARM_RELAY, SENSOR }

local CATEGORY    = "Locks & Sensors"
local SUBCATEGORY = "Sliding Door"
local TYPES = {
  "Mode Changed to Off", "Mode Changed to Hold", "Mode Changed to Auto",
  "Door Opened", "Door Closed", "Door Still Open",
}

local function lastHistory(h)
  return h.log.history[#h.log.history]
end

return function(T)

  T.test("#4: OnDriverLateInit registers every history type once, against the proxy device", function()
    local h = T.driver({ bound = ALL })
    T.eq(#h.log.registered_events, 1, "RegisterEvents call count")
    local xml = h.log.registered_events[1]
    T.ok(xml:find('<device id="43"/>', 1, true), "device id from GetProxyDevices: " .. xml)
    T.ok(xml:find('Locks &amp; Sensors', 1, true), "category must be XML-escaped: " .. xml)
    for _, t in ipairs(TYPES) do
      T.ok(h.registered["43|" .. CATEGORY .. "|" .. SUBCATEGORY .. "|" .. t],
           "type not registered: " .. t)
    end
  end)

  T.test("#4: mode change records a stored, registered 'Mode Changed to X' entry", function()
    local h = T.driver({ bound = ALL })
    h.env.ExecuteCommand("SET_MODE_HOLD", {})
    local r = lastHistory(h)
    T.ok(r, "no stored history record")
    T.eq(r.type, "Mode Changed to Hold")
    T.eq(r.severity, "Info")
    T.eq(r.category, CATEGORY)
    T.eq(r.subcategory, SUBCATEGORY)
    T.ok(r.uuid, "uuid")
  end)

  T.test("#4: boot into Off does not record a history entry", function()
    local h = T.driver({ bound = ALL })
    T.eq(#h.log.history, 0)
  end)

  T.test("#4: door open / close record 'Door Opened' / 'Door Closed'", function()
    local h = T.driver({ bound = ALL })
    h.env.ReceivedFromProxy(SENSOR, "OPENED", {})
    h.fireLatest()
    T.eq(lastHistory(h).type, "Door Opened")
    h.env.ReceivedFromProxy(SENSOR, "CLOSED", {})
    h.fireLatest()
    T.eq(lastHistory(h).type, "Door Closed")
  end)

  T.test("#4: Still Open watchdog records 'Door Still Open' as a Warning", function()
    local h = T.driver({ bound = ALL, properties = { ["Still Open Time (s)"] = "30" } })
    h.env.ReceivedFromProxy(SENSOR, "OPENED", {})
    h.fireLatest()
    h.fireLatest()
    local r = lastHistory(h)
    T.eq(r.type, "Door Still Open")
    T.eq(r.severity, "Warning")
  end)

  T.test("#4: Hold auto-release and gesture-driven mode changes are recorded too", function()
    local h = T.driver({ bound = ALL, properties = { ["Hold Duration (s)"] = "60" } })
    h.env.ExecuteCommand("BUTTON_PRESSED", {})
    h.fireLatest()                                -- long press → Hold
    h.env.ExecuteCommand("BUTTON_RELEASED", {})
    T.eq(lastHistory(h).type, "Mode Changed to Hold")
    h.fireLatest()                                -- Hold auto-release → Off
    T.eq(lastHistory(h).type, "Mode Changed to Off")
  end)

  T.test("#4: a nil UUID (not stored) is reported, and the handler carries on", function()
    local h = T.driver({ bound = ALL })
    h.env.__C4impl.RecordHistory = function() return nil end
    h.clearLogs()
    h.env.ExecuteCommand("SET_MODE_AUTO", {})
    T.contains(h.log.events, "Mode Changed to Auto", "event still fired")
    local warned = false
    for _, line in ipairs(h.log.printed) do
      if line:find("RecordHistory did not store", 1, true) then warned = true end
    end
    T.ok(warned, "expected an always-on warning when RecordHistory returns nil")
  end)

  T.test("#4: a RecordHistory fault cannot abort the door-state handler", function()
    local h = T.driver({ bound = ALL, properties = { ["Still Open Time (s)"] = "30" } })
    h.env.__C4impl.RecordHistory = function() error("boom") end
    h.env.ReceivedFromProxy(SENSOR, "OPENED", {})
    h.fireLatest()
    T.eq(h.var("DOOR_STATE"), "Open")
    T.contains(h.log.events, "Door Opened")
    T.eq(h.activeTimerCount(), 1, "Still Open watchdog must still be armed after the history call")
  end)

  T.test("#4: GetProxyDevices returning a bare number still registers", function()
    local h = T.driver({ bound = ALL, proxyDevices = 77 })
    T.ok(h.log.registered_events[1] and h.log.registered_events[1]:find('<device id="77"/>', 1, true),
         "expected registration against device 77")
  end)

  T.test("#4: no proxy device → registration skipped with a warning, driver still works", function()
    T.allowViolations()      -- records will be stored-but-unregistered; that's the point
    local h = T.driver({ bound = ALL, proxyDevices = {} })
    T.eq(#h.log.registered_events, 0)
    local warned = false
    for _, line in ipairs(h.log.printed) do
      if line:find("RegisterEvents skipped", 1, true) then warned = true end
    end
    T.ok(warned, "expected a warning when no proxy device id is available")
    h.env.ExecuteCommand("SET_MODE_HOLD", {})
    T.eq(h.env.Properties["Mode"], "Hold")
  end)

  T.test("#4: RegisterEvents returning non-zero or nil is reported (only 0 is success)", function()
    for _, ret in ipairs({ 1, "nil" }) do
      local h = T.driver({ noBoot = true, bound = ALL })
      h.env.__C4impl.RegisterEvents = function() if ret ~= "nil" then return ret end end
      h.env.OnDriverInit()
      h.env.OnDriverLateInit()
      T.allowViolations()     -- registration was swallowed, so records are unregistered
      local warned = false
      for _, line in ipairs(h.log.printed) do
        if line:find("RegisterEvents returned", 1, true) then warned = true end
      end
      T.ok(warned, "expected a warning for RegisterEvents return " .. tostring(ret))
    end
  end)

  T.test("#4: registering against the wrong device is caught by the mock", function()
    -- Guards the mock itself: a record only counts as visible when it matches a
    -- registration for this driver's proxy device.
    local h = T.driver({ bound = ALL })
    h.env.__C4impl.RegisterEvents(nil, '<events><device id="999"/><categories>'
      .. '<category name="X"><subcategories><subcategory name="Y"><types>'
      .. '<type name="Z"/></types></subcategory></subcategories></category>'
      .. '</categories></events>')
    T.allowViolations()
    h.env.C4:RecordHistory("Info", "Z", "X", "Y")
    local found = false
    for _, v in ipairs(h.log.violations) do
      if v:find("not registered", 1, true) then found = true end
    end
    T.ok(found, "device-999 registration must not satisfy a device-43 record")
  end)

  T.test("#4: driver update in place re-registers (registration is per driver load)", function()
    local h = T.driver({ bound = ALL })
    h.reload()
    T.eq(#h.log.registered_events, 2)
    h.env.ExecuteCommand("SET_MODE_AUTO", {})
    T.eq(lastHistory(h).type, "Mode Changed to Auto")
  end)
end
