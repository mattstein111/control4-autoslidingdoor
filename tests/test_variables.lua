--[[
  Issue #3 — MODE and DOOR_STATE must exist as Director variables.

  Before the fix, driver.lua called C4:SetVariable on both names but never
  C4:AddVariable, so every write was a silent no-op on Director. The mock
  records SetVariable-on-uncreated-variable as a violation, so these cases
  (and every baseline case) fail against the unfixed driver.
--]]

local OPEN_RELAY, ARM_RELAY, SENSOR, PROXY = 100, 101, 200, 5001
local ALL = { OPEN_RELAY, ARM_RELAY, SENSOR }

return function(T)

  T.test("#3: OnDriverInit creates MODE and DOOR_STATE as read-only STRING variables", function()
    local h = T.driver({ noBoot = true })
    h.env.OnDriverInit()
    for _, name in ipairs({ "MODE", "DOOR_STATE" }) do
      local v = h.variables[name]
      T.ok(v, name .. " not created in OnDriverInit")
      T.eq(v.type, "STRING", name .. " type")
      T.eq(v.readonly, true, name .. " readonly")
      T.eq(v.hidden, false, name .. " hidden")
    end
  end)

  T.test("#3: variables are seeded on boot (MODE=Off, DOOR_STATE=Unknown)", function()
    local h = T.driver({ bound = ALL })
    T.eq(h.var("MODE"), "Off")
    T.eq(h.var("DOOR_STATE"), "Unknown")
  end)

  T.test("#3: mode changes update MODE", function()
    local h = T.driver({ bound = ALL })
    h.env.ExecuteCommand("SET_MODE_HOLD", {})
    T.eq(h.var("MODE"), "Hold")
    h.env.ExecuteCommand("SET_MODE_AUTO", {})
    T.eq(h.var("MODE"), "Auto")
    h.env.ExecuteCommand("SET_MODE_OFF", {})
    T.eq(h.var("MODE"), "Off")
  end)

  T.test("#3: door open/close updates DOOR_STATE", function()
    local h = T.driver({ bound = ALL })
    h.env.ReceivedFromProxy(SENSOR, "OPENED", {})
    h.fireLatest()
    T.eq(h.var("DOOR_STATE"), "Open")
    h.env.ReceivedFromProxy(SENSOR, "CLOSED", {})
    h.fireLatest()
    T.eq(h.var("DOOR_STATE"), "Closed")
  end)

  T.test("#3: sensor unbinding resets DOOR_STATE to Unknown", function()
    local h = T.driver({ bound = ALL })
    h.env.ReceivedFromProxy(SENSOR, "OPENED", {})
    h.fireLatest()
    h.bindings[SENSOR] = 0
    h.env.OnBindingChanged(SENSOR, "CONTACT_SENSOR", false)
    T.eq(h.var("DOOR_STATE"), "Unknown")
  end)

  T.test("#3: variables and properties never disagree", function()
    local h = T.driver({ bound = ALL })
    local function check()
      T.eq(h.var("MODE"), h.env.Properties["Mode"], "MODE vs Mode property")
      T.eq(h.var("DOOR_STATE"), h.env.Properties["Door State"], "DOOR_STATE vs Door State property")
    end
    check()
    h.env.ExecuteCommand("SET_MODE_HOLD", {}); check()
    h.env.ReceivedFromProxy(SENSOR, "OPENED", {}); h.fireLatest(); check()
    h.env.ExecuteCommand("SET_MODE_OFF", {}); check()
  end)

  T.test("#3: a SetVariable fault does not abort publishMode (tile + LEDs still update)", function()
    local h = T.driver({ bound = ALL })
    -- Make every SetVariable raise, as a mis-addressed variable does on Director.
    h.env.__C4impl.SetVariable = function() error("identifier should be a number/string") end
    h.clearLogs()
    h.env.ExecuteCommand("SET_MODE_AUTO", {})
    T.eq(h.lastProxy(PROXY, "ICON_CHANGED").params.icon, "Mode_Auto", "tile icon")
    T.ok(h.lastProxy(500, "BUTTON_COLORS"), "keypad LEDs")
    T.contains(h.log.events, "Mode Changed to Auto")
    T.eq(h.lastProxy(ARM_RELAY).cmd, "CLOSE")
  end)

  T.test("#3: driver update in place re-uses existing variables without faulting", function()
    local h = T.driver({ bound = ALL })
    h.env.ExecuteCommand("SET_MODE_HOLD", {})
    h.reload()                       -- fresh Lua state, Director keeps variables
    T.eq(h.var("MODE"), "Off", "driver wakes in Off after reload")
    T.eq(h.var("MODE"), h.env.Properties["Mode"])
  end)

  T.test("#3: after a reload with the door open, DOOR_STATE is re-seeded to match the property", function()
    -- Fresh Lua state resets STATE.door to Unknown while Director still holds
    -- DOOR_STATE=Open from before the update. OnDriverLateInit must re-publish
    -- the door state so the variable and property agree (review finding on #3).
    local h = T.driver({ bound = ALL })
    h.env.ReceivedFromProxy(SENSOR, "OPENED", {})
    h.fireLatest()
    T.eq(h.var("DOOR_STATE"), "Open")
    h.bindings[SENSOR] = 0          -- sensor quiet across the reload: no re-report
    h.reload()
    T.eq(h.var("DOOR_STATE"), h.env.Properties["Door State"], "variable vs property after reload")
  end)
end
