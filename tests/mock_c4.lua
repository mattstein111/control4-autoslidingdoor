--[[
  Mock Control4 DriverWorks environment for offline testing of driver.lua.

  Runs under LuaJIT (Lua 5.1 semantics, matching Director's interpreter) and
  under stock Lua 5.2+. Each call to M.new() builds a fresh, isolated sandbox:
  a global `C4` object, a `Properties` table seeded from driver.xml defaults,
  and a captured `print`. The real driver.lua is then loaded into that sandbox.

  The mock deliberately models the *silent* Director failure modes this driver
  has been bitten by, and records them as "violations" so tests can fail loudly
  where the real controller fails quietly:

    * C4:SetVariable on a variable that was never created with AddVariable
      (issue #3 — a no-op on Director).
    * C4:RecordHistory with other than four arguments returns nil and stores
      nothing (issue #4). On OS 3.4.3 the five-argument *table* form is
      proven not to store; the five-argument *string* form stored in frigate
      v0.8.13. The mock treats any non-four-argument call as a violation,
      because four arguments is the only form proven in both directions.
    * C4:RecordHistory storing a (category, subcategory, type) tuple that no
      C4:RegisterEvents call registered: stored, but never rendered in the
      Control4 app (frigate #24, c4-conventions §2).
    * C4:FireEvent with a name not declared in driver.xml <events>.

  Any C4 method the mock does not implement raises immediately, so a test
  cannot pass by accidentally exercising an unmodelled API.
--]]

local M = {}

-- ---------------------------------------------------------------------------
-- Paths
-- ---------------------------------------------------------------------------

local function repoRoot()
  -- tests/mock_c4.lua → repo root is the parent of this file's directory
  local src = debug.getinfo(1, "S").source:sub(2)
  local dir = src:match("^(.*)/tests/[^/]*$") or "."
  return dir
end

M.ROOT = repoRoot()

local function readFile(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

-- ---------------------------------------------------------------------------
-- driver.xml parsing (just enough for property defaults and event names)
-- ---------------------------------------------------------------------------

local function parseDriverXml()
  local xml = readFile(M.ROOT .. "/driver.xml")
  local props, events = {}, {}

  local propsBlock = xml:match("<properties>(.-)</properties>") or ""
  for block in propsBlock:gmatch("<property>(.-)</property>") do
    local name = block:match("<name>(.-)</name>")
    local dflt = block:match("<default>(.-)</default>") or ""
    if name then props[name] = dflt end
  end

  local eventsBlock = xml:match("<events>(.-)</events>") or ""
  for block in eventsBlock:gmatch("<event>(.-)</event>") do
    local name = block:match("<name>(.-)</name>")
    if name then events[name] = true end
  end

  return props, events, xml
end

-- The device id the driver should register history against, given what the
-- mock's GetProxyDevices returns (default { [43] = true }).
function M.proxyDeviceIdOf(proxyDevices)
  if proxyDevices == nil then return 43 end
  if type(proxyDevices) == "table" then
    for id in pairs(proxyDevices) do return id end
    return nil
  end
  return tonumber(proxyDevices)
end

-- ---------------------------------------------------------------------------
-- Sandbox
-- ---------------------------------------------------------------------------

function M.new(opts)
  opts = opts or {}

  local propDefaults, declaredEvents, xmlText = parseDriverXml()

  local env           -- current driver global environment (see freshEnv)
  local log = {
    calls       = {},   -- every C4 call: { name=, args={...} }
    printed     = {},   -- captured print() lines
    violations  = {},   -- silent-on-Director failures, as strings
    proxy       = {},   -- SendToProxy: { id=, cmd=, params=, mode= }
    events      = {},   -- FireEvent names, in order
    history     = {},   -- RecordHistory calls that STORED (returned a UUID)
    history_rejected = {}, -- RecordHistory calls that did NOT store
    registered_events = {}, -- RegisterEvents XML payloads
  }

  local variables = {}      -- name -> { value=, type=, readonly=, hidden= }
  local timers = {}         -- id -> { interval=, units=, rep= }
  local nextTimer = 1000
  local nextUuid = 1
  local bindings = opts.bindings or {} -- bindingId -> provider binding (0/nil = unbound)

  local function violate(msg)
    log.violations[#log.violations + 1] = msg
  end

  local C4impl = {}

  function C4impl:AddVariable(name, value, vtype, readonly, hidden)
    if type(name) ~= "string" or name == "" then
      error("AddVariable: identifier should be a string", 2)
    end
    if variables[name] then return false end
    variables[name] = {
      value = tostring(value), type = vtype,
      readonly = readonly, hidden = hidden,
    }
    return true
  end

  function C4impl:SetVariable(name, value)
    if type(name) ~= "string" and type(name) ~= "number" then
      -- Mirrors Director: "identifier should be a number/string"
      error("identifier should be a number/string", 2)
    end
    local v = variables[name]
    if not v then
      violate("SetVariable on uncreated variable '" .. tostring(name) .. "' (no-op on Director)")
      return
    end
    v.value = tostring(value)
  end

  function C4impl:GetVariable(_deviceId, name)
    local v = variables[name]
    return v and v.value or nil
  end

  -- Properties live outside env so they survive h.reload(), as they do on
  -- Director across a driver update.
  local props = {}

  function C4impl:UpdateProperty(name, value)
    props[name] = value
  end

  function C4impl:SendToProxy(id, cmd, params, mode)
    log.proxy[#log.proxy + 1] = { id = id, cmd = cmd, params = params, mode = mode }
  end

  function C4impl:FireEvent(name)
    if not declaredEvents[name] then
      violate("FireEvent '" .. tostring(name) .. "' not declared in driver.xml <events>")
    end
    log.events[#log.events + 1] = name
  end

  -- Registered history tuples: "deviceId|category|subcategory|type" -> true
  local registered = {}

  local function xmlUnescape(str)
    return (str:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
               :gsub("&apos;", "'"):gsub("&amp;", "&"))
  end

  function C4impl:RecordHistory(...)
    local n = select("#", ...)
    local args = { ... }
    if n ~= 4 then
      violate("RecordHistory called with " .. n .. " args (only the 4-arg form is proven to store)")
      log.history_rejected[#log.history_rejected + 1] = { n = n, args = args }
      return nil
    end
    -- Must match a registration against THIS driver's proxy device.
    local key = table.concat({ tostring(M.proxyDeviceIdOf(opts.proxyDevices)),
                               tostring(args[3]), tostring(args[4]), tostring(args[2]) }, "|")
    if not registered[key] then
      violate("RecordHistory tuple not registered via RegisterEvents (stored but invisible in app): "
              .. key)
    end
    local uuid = string.format("00000000-0000-0000-0000-%012d", nextUuid)
    nextUuid = nextUuid + 1
    log.history[#log.history + 1] = {
      severity = args[1], type = args[2], category = args[3], subcategory = args[4],
      uuid = uuid,
    }
    return uuid
  end

  -- Parses the <events><device/><categories>... shape used by frigate and
  -- c4-conventions §2. Returns 0 (Director's success code).
  function C4impl:RegisterEvents(xml)
    log.registered_events[#log.registered_events + 1] = xml
    local dev = xml:match('<device%s+id="([^"]*)"')
    if not dev or dev == "" or dev == "nil" then
      violate("RegisterEvents XML has no device id")
    end
    for catName, catBody in xml:gmatch('<category%s+name="([^"]*)">(.-)</category>') do
      for subName, subBody in catBody:gmatch('<subcategory%s+name="([^"]*)">(.-)</subcategory>') do
        for typeName in subBody:gmatch('<type%s+name="([^"]*)"') do
          registered[table.concat({ tostring(dev), xmlUnescape(catName),
                                    xmlUnescape(subName), xmlUnescape(typeName) }, "|")] = true
        end
      end
    end
    return 0
  end

  function C4impl:AddTimer(interval, units, rep)
    nextTimer = nextTimer + 1
    timers[nextTimer] = { interval = interval, units = units, rep = rep }
    return nextTimer
  end

  function C4impl:KillTimer(id)
    timers[id] = nil
  end

  function C4impl:GetDeviceID() return opts.deviceId or 42 end
  -- Frigate (validated on OS 3.4.3) treats the return as a table keyed by
  -- proxy device id. opts.proxyDevices lets a test return another shape.
  function C4impl:GetProxyDevices()
    if opts.proxyDevices ~= nil then return opts.proxyDevices end
    return { [43] = true }
  end

  function C4impl:GetBoundProviderBinding(_deviceId, bindingId)
    return bindings[bindingId] or 0
  end

  -- -------------------------------------------------------------------------
  -- Auto-update surface (issue #5). Models what control4-frigate validated on
  -- OS 3.4.3: FileSetDir is locked until the esphome handshake, urlGet calls
  -- back (ticketId, body, status, headers, err), TCP client is callback-based.
  -- -------------------------------------------------------------------------

  local HANDSHAKE = "c29tZXNwZWNpYWxrZXk=++11"
  local fsUnlocked, fsDir = false, nil
  local files = {}          -- "DIR/name" -> contents
  local openFiles = {}      -- handle -> { path=, data= }
  local nextFile = 0
  local persist = {}

  function C4impl:FileSetDir(dir)
    if dir == HANDSHAKE then fsUnlocked = true return true end
    if not fsUnlocked then error("Restricted path specified", 2) end
    fsDir = dir
    return true
  end
  local function fpath(name) return tostring(fsDir) .. "/" .. tostring(name) end
  function C4impl:FileExists(name) return files[fpath(name)] ~= nil end
  function C4impl:FileDelete(name) files[fpath(name)] = nil return true end
  -- FileOpen does NOT truncate an existing file (that's why the updater
  -- deletes first): writing a shorter body over a longer file would leave the
  -- old tail behind. opts.fileOpenFails makes FileOpen return -1.
  function C4impl:FileOpen(name)
    if opts.fileOpenFails then return -1 end
    nextFile = nextFile + 1
    openFiles[nextFile] = { path = fpath(name), data = files[fpath(name)] or "", pos = 0 }
    return nextFile
  end
  function C4impl:FileSetPos(h, pos)
    if openFiles[h] then openFiles[h].pos = pos end
    return true
  end
  -- Signature is (handle, length, data): length BEFORE data (c4-conventions §3a).
  function C4impl:FileWrite(h, len, data)
    local f = openFiles[h]
    if not f then error("bad file handle", 2) end
    if type(len) ~= "number" or type(data) ~= "string" then
      error("FileWrite(handle, length, data): wrong argument order/types", 2)
    end
    local chunk = data:sub(1, len)
    f.data = f.data:sub(1, f.pos) .. chunk .. f.data:sub(f.pos + #chunk + 1)
    f.pos = f.pos + #chunk
    return len
  end
  function C4impl:FileClose(h)
    local f = openFiles[h]
    if f then files[f.path] = f.data; openFiles[h] = nil end
  end

  function C4impl:PersistGetValue(k) return persist[k] end
  function C4impl:PersistSetValue(k, v) persist[k] = v end

  -- urlGet requests queue up; the test answers them with h.respond().
  local requests = {}
  function C4impl:urlGet(url, headers, _cache, cb)
    requests[#requests + 1] = { url = url, headers = headers, cb = cb }
    return #requests
  end

  -- TCP client: records connect target and written bytes. Connect() succeeds
  -- synchronously unless opts.tcpFails.
  local tcp = {}
  function C4impl:CreateTCPClient()
    local c = { written = {}, closed = false }
    tcp[#tcp + 1] = c
    local obj = {}
    function obj:OnConnect(fn) c.onConnect = fn return obj end
    function obj:OnError(fn) c.onError = fn return obj end
    function obj:OnResolve(fn) return obj end
    function obj:OnDisconnect(fn) return obj end
    function obj:OnRead(fn) return obj end
    function obj:Write(data) c.written[#c.written + 1] = data return obj end
    function obj:Close() c.closed = true return obj end
    function obj:Connect(host, port)
      c.host, c.port = host, port
      if opts.tcpFails then
        if c.onError then c.onError(obj, 1, "connection refused") end
      elseif c.onConnect then
        c.onConnect(obj)
      end
      return obj
    end
    return obj
  end

  -- Strict proxy: record every call; unknown methods raise.
  local C4 = setmetatable({}, {
    __index = function(_, k)
      local f = C4impl[k]
      if not f then
        error("mock C4: unmodelled API C4:" .. tostring(k), 2)
      end
      return function(self, ...)
        log.calls[#log.calls + 1] = { name = k, args = { ... } }
        return f(self, ...)
      end
    end,
  })

  for k, v in pairs(propDefaults) do props[k] = v end
  if opts.properties then
    for k, v in pairs(opts.properties) do props[k] = v end
  end

  -- Build a fresh global environment for one load of driver.lua. Called again
  -- by h.reload() to model a driver update in place: all Lua state is lost,
  -- but Director keeps variables, properties and bindings.
  local function freshEnv()
    local e = {}
    e.__C4impl = C4impl   -- tests may override behaviour per case
    e.C4 = C4
    e.Properties = props
    e.print = function(...)
      local parts = {}
      for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
      log.printed[#log.printed + 1] = table.concat(parts, "\t")
    end
    return setmetatable(e, { __index = _G })
  end
  env = freshEnv()

  -- -------------------------------------------------------------------------
  -- Test-side handle
  -- -------------------------------------------------------------------------
  local h = {
    env = env, log = log, variables = variables, timers = timers,
    registered = registered,
    files = files, persist = persist, requests = requests, tcp = tcp,
    bindings = bindings, xml = xmlText, declaredEvents = declaredEvents,
  }

  -- opts.driverVersion rewrites the `local DRIVER_VERSION = "..."` line before
  -- loading, so tests can run the real driver as if any version were installed.
  function h.load()
    local src = readFile(M.ROOT .. "/driver.lua")
    if opts.driverVersion then
      local n
      src, n = src:gsub('\nlocal DRIVER_VERSION = "[^"]*"',
                        '\nlocal DRIVER_VERSION = "' .. opts.driverVersion .. '"', 1)
      assert(n == 1, "DRIVER_VERSION line not found in driver.lua")
    end
    local chunk
    if setfenv then
      chunk = assert(loadstring(src, "=driver.lua"))
      setfenv(chunk, env)
    else
      chunk = assert(load(src, "=driver.lua", "t", env))
    end
    chunk()
    return h
  end

  -- Model a driver update in place (Composer "Update Driver", or the
  -- auto-updater's UpdateProjectC4i): driver.lua is re-run in a brand-new Lua
  -- state, timers die with the old VM, while variables, properties and
  -- bindings persist in Director. Then the normal init sequence runs.
  function h.reload()
    if env.OnDriverDestroyed then env.OnDriverDestroyed() end
    for id in pairs(timers) do timers[id] = nil end
    env = freshEnv()
    h.env = env
    return h.boot()
  end

  -- Simulate Director's init sequence.
  function h.boot()
    h.load()
    env.OnDriverInit()
    if env.OnDriverLateInit then env.OnDriverLateInit() end
    return h
  end

  function h.bind(bindingId, provider)
    bindings[bindingId] = provider or 1
    env.OnBindingChanged(bindingId, "", true)
  end

  function h.var(name)
    local v = variables[name]
    return v and v.value or nil
  end

  -- Fire one specific timer id (as Director would on expiry).
  function h.fire(id)
    assert(timers[id], "timer " .. tostring(id) .. " is not active")
    if not timers[id].rep then timers[id] = nil end
    env.OnTimerExpired(id)
  end

  -- Fire the most recently created active timer.
  function h.fireLatest()
    local best
    for id in pairs(timers) do if not best or id > best then best = id end end
    assert(best, "no active timers")
    h.fire(best)
  end

  function h.activeTimerCount()
    local n = 0
    for _ in pairs(timers) do n = n + 1 end
    return n
  end

  -- Last SendToProxy to a binding (optionally filtered by command).
  function h.lastProxy(id, cmd)
    for i = #log.proxy, 1, -1 do
      local p = log.proxy[i]
      if p.id == id and (cmd == nil or p.cmd == cmd) then return p end
    end
  end

  -- Answer the oldest pending urlGet whose URL contains `match`.
  function h.respond(match, body, status, err)
    for i, r in ipairs(requests) do
      if not r.answered and r.url:find(match, 1, true) then
        r.answered = true
        r.cb(i, body, status or 200, {}, err)
        return r
      end
    end
    error("no pending urlGet matching " .. tostring(match))
  end

  function h.pending(match)
    local n = 0
    for _, r in ipairs(requests) do
      if not r.answered and (match == nil or r.url:find(match, 1, true)) then n = n + 1 end
    end
    return n
  end

  function h.clearLogs()
    for _, k in ipairs({ "calls", "printed", "proxy", "events", "history",
                         "history_rejected" }) do
      log[k] = {}
    end
  end

  return h
end

return M
