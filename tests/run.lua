--[[
  Minimal test runner for driver.lua against the mock C4 environment.

  Usage (from repo root):
    luajit tests/run.lua        # Lua 5.1 semantics — what Director runs
    lua    tests/run.lua        # stock Lua 5.2+

  Or just ./tests/run_tests.sh, which runs both plus the build lint.

  Each test file returns a function(T) that registers cases with T.test().
  After every case the runner asserts that the mock recorded no violations
  (silent-on-Director failures), unless the case opts out with T.allowViolations().
--]]

local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local mock = require("mock_c4")

local T = { cases = {} }

function T.test(name, fn) T.cases[#T.cases + 1] = { name = name, fn = fn } end

local function fmt(v)
  if type(v) == "string" then return string.format("%q", v) end
  return tostring(v)
end

function T.eq(actual, expected, msg)
  if actual ~= expected then
    error((msg and (msg .. ": ") or "") .. "expected " .. fmt(expected)
          .. ", got " .. fmt(actual), 2)
  end
end

function T.ok(cond, msg)
  if not cond then error(msg or "assertion failed", 2) end
end

function T.contains(list, value, msg)
  for _, v in ipairs(list) do if v == value then return end end
  error((msg and (msg .. ": ") or "") .. fmt(value) .. " not found", 2)
end

-- Fresh, booted driver with the given bindings wired.
-- bindings: list of binding ids to treat as bound before boot.
function T.driver(opts)
  opts = opts or {}
  local bindings = {}
  for _, id in ipairs(opts.bound or {}) do bindings[id] = 1 end
  local h = mock.new({ bindings = bindings, properties = opts.properties,
                       proxyDevices = opts.proxyDevices,
                       driverVersion = opts.driverVersion, tcpFails = opts.tcpFails,
                       fileOpenFails = opts.fileOpenFails })
  if opts.noBoot then h.load() else h.boot() end
  T._current = h
  return h
end

function T.allowViolations() T._allow = true end

local files = {
  "test_baseline",
  "test_variables",
  "test_history",
  "test_autoupdate",
}

for _, f in ipairs(files) do
  local register = require(f)
  register(T)
end

local passed, failed = 0, 0
for _, c in ipairs(T.cases) do
  T._current, T._allow = nil, false
  local ok, err = xpcall(c.fn, debug.traceback)
  if ok and T._current and not T._allow then
    local v = T._current.log.violations
    if #v > 0 then
      ok, err = false, "mock violations:\n    " .. table.concat(v, "\n    ")
    end
  end
  if ok then
    passed = passed + 1
    io.write("  ok   ", c.name, "\n")
  else
    failed = failed + 1
    io.write("  FAIL ", c.name, "\n    ", tostring(err):gsub("\n", "\n    "), "\n")
  end
end

io.write(string.format("\n%s: %d passed, %d failed\n",
  (jit and jit.version) or _VERSION, passed, failed))
os.exit(failed == 0 and 0 or 1)
