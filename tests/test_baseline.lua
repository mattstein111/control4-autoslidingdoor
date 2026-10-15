--[[
  Baseline behaviour of the shipped driver (v2.0.1). These pin the existing
  contract — relays, tile icon, keypad LEDs, events, gesture decoder, sensor
  debounce — so later issue work (#3 variables, #4 history, #5 auto-update)
  can prove "no regressions".
--]]

local OPEN_RELAY, ARM_RELAY, SENSOR, PROXY = 100, 101, 200, 5001
local ALL = { OPEN_RELAY, ARM_RELAY, SENSOR }

return function(T)

  T.test("baseline: boots into Off with both relays released", function()
    local h = T.driver({ bound = ALL })
    T.eq(h.env.Properties["Mode"], "Off")
    T.eq(h.lastProxy(OPEN_RELAY).cmd, "OPEN")
    T.eq(h.lastProxy(ARM_RELAY).cmd, "OPEN")
    T.eq(h.lastProxy(PROXY, "ICON_CHANGED").params.icon, "Mode_Off")
    T.eq(h.env.Properties["Contact Status"], "Connected")
  end)

  T.test("baseline: Set Mode to Hold closes open relay, fires event, swaps tile", function()
    local h = T.driver({ bound = ALL })
    h.env.ExecuteCommand("SET_MODE_HOLD", {})
    T.eq(h.env.Properties["Mode"], "Hold")
    T.eq(h.lastProxy(OPEN_RELAY).cmd, "CLOSE")
    T.eq(h.lastProxy(ARM_RELAY).cmd, "OPEN")
    T.eq(h.lastProxy(PROXY, "ICON_CHANGED").params.icon, "Mode_Hold")
    T.contains(h.log.events, "Mode Changed to Hold")
  end)

  T.test("baseline: Set Mode to Auto arms motion relay", function()
    local h = T.driver({ bound = ALL })
    h.env.ExecuteCommand("SET_MODE_AUTO", {})
    T.eq(h.lastProxy(ARM_RELAY).cmd, "CLOSE")
    T.eq(h.lastProxy(OPEN_RELAY).cmd, "OPEN")
    T.contains(h.log.events, "Mode Changed to Auto")
  end)

  T.test("baseline: setting the same mode is a no-op (no event)", function()
    local h = T.driver({ bound = ALL })
    h.env.ExecuteCommand("SET_MODE_HOLD", {})
    h.clearLogs()
    h.env.ExecuteCommand("SET_MODE_HOLD", {})
    T.eq(#h.log.events, 0)
  end)

  T.test("baseline: keypad LEDs follow mode colour", function()
    local h = T.driver({ bound = ALL })
    h.env.ExecuteCommand("SET_MODE_AUTO", {})
    local p = h.lastProxy(500, "BUTTON_COLORS")
    T.eq(p.params.ON_COLOR.COLOR_STR, "0,200,0")
  end)

  T.test("baseline: Open Door pulses open relay for default duration", function()
    local h = T.driver({ bound = ALL })
    h.env.ExecuteCommand("OPEN_DEFAULT", {})
    T.eq(h.lastProxy(OPEN_RELAY).cmd, "CLOSE")
    h.fireLatest()
    T.eq(h.lastProxy(OPEN_RELAY).cmd, "OPEN")
  end)

  T.test("baseline: contact sensor debounced into Door Opened / Door Closed", function()
    local h = T.driver({ bound = ALL })
    h.env.ReceivedFromProxy(SENSOR, "OPENED", {})
    T.eq(h.env.Properties["Door State"], "Unknown", "not committed before debounce")
    h.fireLatest()
    T.eq(h.env.Properties["Door State"], "Open")
    T.contains(h.log.events, "Door Opened")
    h.env.ReceivedFromProxy(SENSOR, "CLOSED", {})
    h.fireLatest()
    T.eq(h.env.Properties["Door State"], "Closed")
    T.contains(h.log.events, "Door Closed")
  end)

  T.test("baseline: Still Open watchdog fires event", function()
    local h = T.driver({ bound = ALL, properties = { ["Still Open Time (s)"] = "30" } })
    h.env.ReceivedFromProxy(SENSOR, "OPENED", {})
    h.fireLatest()          -- debounce → Open, arms watchdog
    h.fireLatest()          -- watchdog
    T.contains(h.log.events, "Still Open")
  end)

  T.test("baseline: gesture long press -> Hold, double press -> Auto, single -> Off", function()
    local h = T.driver({ bound = ALL })
    -- long press
    h.env.ExecuteCommand("BUTTON_PRESSED", {})
    h.fireLatest()                                  -- long-press timer
    h.env.ExecuteCommand("BUTTON_RELEASED", {})
    T.eq(h.env.Properties["Mode"], "Hold")
    -- double press
    h.env.ExecuteCommand("BUTTON_PRESSED", {})
    h.env.ExecuteCommand("BUTTON_RELEASED", {})
    h.env.ExecuteCommand("BUTTON_PRESSED", {})
    h.env.ExecuteCommand("BUTTON_RELEASED", {})
    T.eq(h.env.Properties["Mode"], "Auto")
    -- single press from Auto → Off
    h.env.ExecuteCommand("BUTTON_PRESSED", {})
    h.env.ExecuteCommand("BUTTON_RELEASED", {})
    h.fireLatest()                                  -- double-click window expires
    T.eq(h.env.Properties["Mode"], "Off")
  end)

  T.test("baseline: Hold auto-release returns to Off", function()
    local h = T.driver({ bound = ALL, properties = { ["Hold Duration (s)"] = "60" } })
    h.env.ExecuteCommand("SET_MODE_HOLD", {})
    h.fireLatest()
    T.eq(h.env.Properties["Mode"], "Off")
    T.contains(h.log.events, "Mode Changed to Off")
  end)

  T.test("baseline: unbound relays are skipped, not commanded", function()
    local h = T.driver({ bound = {} })
    h.env.ExecuteCommand("SET_MODE_HOLD", {})
    T.eq(h.lastProxy(OPEN_RELAY), nil)
    T.eq(h.env.Properties["Contact Status"], "Not connected")
  end)

  T.test("baseline: driver.lua parses and has no accidental globals beyond the C4 entry points", function()
    local h = T.driver({ bound = ALL })
    local allowed = {
      EX_CMDS = true, PROXY_CMDS = true,
      ExecuteCommand = true, ReceivedFromProxy = true, OnBindingChanged = true,
      OnTimerExpired = true, OnPropertyChanged = true, OnDriverInit = true,
      OnDriverLateInit = true, OnDriverDestroyed = true,
      -- harness-owned
      C4 = true, Properties = true, print = true, __C4impl = true,
    }
    for k in pairs(h.env) do
      T.ok(allowed[k], "unexpected global: " .. tostring(k))
    end
  end)
end
