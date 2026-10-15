--[[
  Issue #5 — self-installing auto-update from GitHub Releases.

  Everything up to "the right bytes were written to C4Z_ROOT and the right
  SOAP envelope was sent to Director on 127.0.0.1:5020" is provable offline.
  Whether Director then hot-reloads the driver can only be proven on the
  controller (two-release smoke test, see README → Auto Update).

  The mock enforces the platform rules frigate learned the hard way:
  FileSetDir is locked until the esphome handshake, FileWrite takes
  (handle, length, data), urlGet reports the pre-redirect status code.
--]]

local OPEN_RELAY, ARM_RELAY, SENSOR = 100, 101, 200
local ALL = { OPEN_RELAY, ARM_RELAY, SENSOR }

local REPO      = "mattstein111/control4-autoslidingdoor"
local API_URL   = "https://api.github.com/repos/" .. REPO .. "/releases"
local ASSET     = "autoslidingdoor.c4z"
-- A minimal "complete zip" as far as the updater checks: local-file header
-- magic up front, end-of-central-directory record (PK\5\6 + 18 bytes) at the
-- end, binary bytes (NUL, 0xFF) in between.
local C4Z_BYTES = "PK\3\4" .. string.rep("x", 64) .. "\0binary\255tail"
                  .. "PK\5\6" .. string.rep("\0", 18)

-- ---------------------------------------------------------------------------
-- GitHub Releases API fixture. Field order and nesting follow the real
-- /repos/{owner}/{repo}/releases response: author object before tag_name,
-- draft/prerelease after it, assets (with nested uploader objects) and the
-- markdown body last. Newest first, as GitHub returns them.
-- ---------------------------------------------------------------------------
local function releaseJson(r)
  local size = r.size or #C4Z_BYTES
  local assets = {}
  for _, name in ipairs(r.assets or { ASSET }) do
    assets[#assets + 1] = string.format([[
      {
        "url": "https://api.github.com/repos/%s/releases/assets/1",
        "id": 1,
        "name": "%s",
        "label": "",
        "uploader": { "login": "github-actions[bot]", "id": 41898282, "type": "Bot", "site_admin": false },
        "content_type": "application/zip",
        "state": "uploaded",
        "size": %d,
        "browser_download_url": "https://github.com/%s/releases/download/%s/%s"
      }]], REPO, name, size, REPO, r.tag, name)
  end
  return string.format([[
  {
    "url": "https://api.github.com/repos/%s/releases/123",
    "html_url": "https://github.com/%s/releases/tag/%s",
    "id": 123,
    "author": { "login": "mattstein111", "id": 1, "html_url": "https://github.com/mattstein111", "type": "User" },
    "node_id": "RE_x",
    "tag_name": "%s",
    "target_commitish": "main",
    "name": "%s",
    "draft": %s,
    "immutable": false,
    "prerelease": %s,
    "created_at": "2026-10-15T00:00:00Z",
    "published_at": "2026-10-15T00:00:00Z",
    "assets": [%s
    ],
    "tarball_url": "https://api.github.com/repos/%s/tarball/%s",
    "zipball_url": "https://api.github.com/repos/%s/zipball/%s",
    "body": "## What's Changed\r\n* Fix {thing} in \"draft\": true mode by @mattstein111\r\n"
  }]], REPO, REPO, r.tag, r.tag, r.tag,
       tostring(r.draft == true), tostring(r.prerelease == true),
       table.concat(assets, ","), REPO, r.tag, REPO, r.tag)
end

local function releasesJson(list)
  local parts = {}
  for i, r in ipairs(list) do parts[i] = releaseJson(r) end
  return "[" .. table.concat(parts, ",") .. "\n]"
end

local function printed(h, needle)
  for _, line in ipairs(h.log.printed) do
    if line:find(needle, 1, true) then return true end
  end
  return false
end

local function downloads(h)
  local n = 0
  for _, r in ipairs(h.requests) do
    if r.url:find("/releases/download/", 1, true) then n = n + 1 end
  end
  return n
end

local function updater(opts)
  opts = opts or {}
  local props = opts.properties or {}
  if opts.channel then props["Auto Update"] = opts.channel end
  return opts.T.driver({ bound = ALL, properties = props,
                         driverVersion = opts.installed, tcpFails = opts.tcpFails })
end

-- Boot on the Beta channel with a persisted last-install-attempt timestamp,
-- as Director would after the auto-updater's own SOAP reload.
local function mockBootWithPersist(T, attemptTime)
  local h = T.driver({ noBoot = true, bound = ALL, properties = { ["Auto Update"] = "Beta" } })
  h.persist["last_install_attempt"] = tostring(attemptTime)
  h.env.OnDriverInit()
  h.env.OnDriverLateInit()
  return h
end

return function(T)

  -- -------------------------------------------------------------------------
  -- Defaults and the Off channel
  -- -------------------------------------------------------------------------

  T.test("#5: Auto Update defaults to Off, and Off makes no network calls at boot", function()
    local h = T.driver({ bound = ALL })
    T.eq(h.env.Properties["Auto Update"], "Off")
    T.eq(#h.requests, 0)
    T.eq(h.activeTimerCount(), 0, "no update timer while Off")
  end)

  T.test("#5: the FileSetDir handshake runs at boot (C4Z_ROOT unlocked)", function()
    local h = T.driver({ bound = ALL })
    local ok = pcall(function() h.env.C4:FileSetDir("C4Z_ROOT") end)
    T.ok(ok, "C4Z_ROOT still locked: handshake missing from OnDriverLateInit")
  end)

  T.test("#5: Check for Updates Now while Off probes Release and reports, never installs", function()
    local h = updater({ T = T, installed = "2.2.0-beta.1" })
    h.env.ExecuteCommand("LUA_ACTION", { ACTION = "CHECK_UPDATES" })
    h.respond(API_URL, releasesJson({
      { tag = "v2.3.0-beta.1", prerelease = true },
      { tag = "v2.2.0" },
    }))
    T.eq(h.env.Properties["Latest Available Version"], "v2.2.0", "Off probes the Release channel")
    T.ok(h.env.Properties["Update Download URL"]:find("/releases/tag/v2.2.0", 1, true))
    T.eq(downloads(h), 0, "must not download while Auto Update is Off")
    T.ok(h.env.Properties["Last Update Check"]:find("update available", 1, true),
         "Last Update Check: " .. tostring(h.env.Properties["Last Update Check"]))
  end)

  -- -------------------------------------------------------------------------
  -- Channel selection
  -- -------------------------------------------------------------------------

  T.test("#5: Release channel skips drafts and prereleases", function()
    local h = updater({ T = T, installed = "2.0.0", channel = "Release" })
    h.respond(API_URL, releasesJson({
      { tag = "v9.0.0", draft = true },
      { tag = "v3.0.0-beta.1", prerelease = true },
      { tag = "v2.5.0" },
    }))
    T.eq(h.env.Properties["Latest Available Version"], "v2.5.0")
  end)

  T.test("#5: Beta channel takes the newest non-draft, prerelease or not", function()
    local h = updater({ T = T, installed = "2.0.0", channel = "Beta" })
    h.respond(API_URL, releasesJson({
      { tag = "v9.0.0", draft = true },
      { tag = "v3.0.0-beta.1", prerelease = true },
      { tag = "v2.5.0" },
    }))
    T.eq(h.env.Properties["Latest Available Version"], "v3.0.0-beta.1")
  end)

  T.test("#5: no matching release on the channel reports (none)", function()
    local h = updater({ T = T, installed = "2.0.0", channel = "Release" })
    h.respond(API_URL, releasesJson({ { tag = "v3.0.0-beta.1", prerelease = true } }))
    T.eq(h.env.Properties["Latest Available Version"], "(none)")
    T.eq(downloads(h), 0)
  end)

  -- -------------------------------------------------------------------------
  -- Version ordering (through real updater behaviour: install or not)
  -- -------------------------------------------------------------------------

  local ORDER = {
    -- installed,      latest on channel,  should install?
    { "2.2.0-beta.1",  "v2.2.0-beta.2",    true  },
    { "2.2.0-beta.10", "v2.2.0-beta.9",    false },  -- numeric prerelease segments
    { "2.2.0-beta.9",  "v2.2.0-beta.10",   true  },
    { "0.9.1.8",       "v0.9.1.9",         true  },  -- 4-part (frigate #33)
    { "0.9.1.9",       "v0.9.1.8",         false },
    { "1.0",           "v1.0.0",           false },  -- zero-padding
    { "1.0.0-rc.1",    "v1.0.0",           true  },  -- release > its prerelease
    { "1.0.0",         "v1.0.0-rc.9",      false },
    { "2.2.0",         "v2.1.9",           false },
    { "2.2.0-beta.2",  "v2.2.0-beta.2",    false },  -- equal
    { "2.10.0",        "v2.9.0",           false },  -- numeric, not lexical
    { "2.2.0-alpha.3", "v2.2.0-beta.1",    true  },
    { "2.2.0-rc.1",    "V2.2.0-RC.2",      true  },  -- case-insensitive v / prerelease
    { "2.2.0",         "v2.2.0+build.7",   false },  -- build metadata ignored
    { "1.0.0-beta",    "v1.0.0-beta.1",    true  },  -- more segments = higher
    { "2.2.0",         "vgarbage",         false },  -- unparseable never installs
  }
  for _, c in ipairs(ORDER) do
    local installed, latest, expect = c[1], c[2], c[3]
    T.test(string.format("#5: version order: installed %s, latest %s -> %s",
                         installed, latest, expect and "install" or "stay"), function()
      local h = updater({ T = T, installed = installed, channel = "Beta" })
      h.respond(API_URL, releasesJson({ { tag = latest, prerelease = latest:find("-", 1, true) ~= nil } }))
      T.eq(downloads(h) == 1, expect, "download started")
    end)
  end

  -- -------------------------------------------------------------------------
  -- The install path
  -- -------------------------------------------------------------------------

  T.test("#5: API request: correct URL, User-Agent and GitHub Accept header", function()
    local h = updater({ T = T, installed = "2.2.0-beta.1", channel = "Beta" })
    local r = h.requests[1]
    T.eq(r.url, API_URL .. "?per_page=100")
    T.ok(r.headers["User-Agent"] and r.headers["User-Agent"]:find("v2.2.0-beta.1", 1, true),
         "User-Agent must be set (GitHub rejects requests without one)")
    T.eq(r.headers["Accept"], "application/vnd.github+json")
  end)

  T.test("#5: full install: download -> write C4Z_ROOT -> persist attempt -> SOAP self", function()
    local h = updater({ T = T, installed = "2.2.0-beta.1", channel = "Beta" })
    h.respond(API_URL, releasesJson({ { tag = "v2.2.0-beta.2", prerelease = true } }))

    local dl = h.requests[2]
    T.eq(dl.url, "https://github.com/" .. REPO .. "/releases/download/v2.2.0-beta.2/" .. ASSET)
    T.eq(dl.headers["Accept"], "application/octet-stream")
    T.ok(dl.headers["User-Agent"], "download User-Agent")

    -- GitHub answers 302 to its CDN; urlGet follows but reports the 302.
    h.respond("/releases/download/", C4Z_BYTES, 302)

    T.eq(h.files["C4Z_ROOT/" .. ASSET], C4Z_BYTES, "exact bytes written to C4Z_ROOT")
    T.ok(tonumber(h.persist["last_install_attempt"]), "anti-loop timestamp persisted")

    T.eq(#h.tcp, 1, "one SOAP connection")
    local c = h.tcp[1]
    T.eq(c.host, "127.0.0.1"); T.eq(c.port, 5020)
    T.eq(c.written[1],
      '<c4soap name="UpdateProjectC4i" session="0" operation="RWX" category="composer" async="0">'
      .. '<param name="name" type="string">' .. ASSET .. '</param></c4soap>\0',
      "SOAP envelope must match the validated form, null-terminated")
    T.ok(c.closed, "connection closed after write")
  end)

  T.test("#5: a non-zip body (e.g. an HTML error page) is never written", function()
    local h = updater({ T = T, installed = "2.2.0-beta.1", channel = "Beta" })
    h.respond(API_URL, releasesJson({ { tag = "v2.2.0-beta.2", prerelease = true } }))
    h.respond("/releases/download/", "<!DOCTYPE html><html>Not Found</html>", 200)
    T.eq(h.files["C4Z_ROOT/" .. ASSET], nil)
    T.eq(#h.tcp, 0)
    T.eq(h.persist["last_install_attempt"], nil)
  end)

  T.test("#5: download HTTP 404 or transport error aborts the install", function()
    for _, case in ipairs({ { 404, nil }, { 200, "timeout" } }) do
      local h = updater({ T = T, installed = "2.2.0-beta.1", channel = "Beta" })
      h.respond(API_URL, releasesJson({ { tag = "v2.2.0-beta.2", prerelease = true } }))
      h.respond("/releases/download/", C4Z_BYTES, case[1], case[2])
      T.eq(h.files["C4Z_ROOT/" .. ASSET], nil, "status " .. case[1])
      T.eq(#h.tcp, 0)
    end
  end)

  T.test("#5: release without the autoslidingdoor.c4z asset is skipped with a warning", function()
    local h = updater({ T = T, installed = "2.2.0-beta.1", channel = "Beta" })
    h.respond(API_URL, releasesJson({ { tag = "v2.2.0-beta.2", prerelease = true,
                                        assets = { "something-else.zip" } } }))
    T.eq(downloads(h), 0)
    T.ok(printed(h, "missing asset"), "warning expected")
  end)

  T.test("#5: GitHub API HTTP 403 (rate limit) is reported in Last Update Check", function()
    local h = updater({ T = T, installed = "2.2.0-beta.1", channel = "Beta" })
    h.respond(API_URL, '{"message":"API rate limit exceeded"}', 403)
    T.ok(h.env.Properties["Last Update Check"]:find("HTTP 403", 1, true),
         tostring(h.env.Properties["Last Update Check"]))
    T.eq(downloads(h), 0)
  end)

  T.test("#5: up to date clears the download URL and records the outcome", function()
    local h = updater({ T = T, installed = "2.2.0-beta.2", channel = "Beta" })
    h.respond(API_URL, releasesJson({ { tag = "v2.2.0-beta.2", prerelease = true } }))
    T.eq(h.env.Properties["Update Download URL"], "")
    T.ok(h.env.Properties["Last Update Check"]:find("up to date", 1, true))
    T.eq(downloads(h), 0)
  end)

  T.test("#5: SOAP connection error is logged, not raised", function()
    local h = updater({ T = T, installed = "2.2.0-beta.1", channel = "Beta", tcpFails = true })
    h.respond(API_URL, releasesJson({ { tag = "v2.2.0-beta.2", prerelease = true } }))
    h.respond("/releases/download/", C4Z_BYTES, 302)
    T.ok(printed(h, "Install SOAP error"), "SOAP error should be logged")
  end)

  -- -------------------------------------------------------------------------
  -- Anti-loop guard
  -- -------------------------------------------------------------------------

  T.test("#5: boot within 5 minutes of an install attempt skips the automatic check", function()
    local h = mockBootWithPersist(T, os.time() - 60)
    T.eq(h.pending(API_URL), 0, "no automatic check")
    T.ok(printed(h, "Skipping initial update check"), "explains why")
    -- Manual check still works.
    h.env.ExecuteCommand("LUA_ACTION", { ACTION = "CHECK_UPDATES" })
    T.eq(h.pending(API_URL), 1)
  end)

  T.test("#5: boot more than 5 minutes after an attempt checks normally", function()
    local h = mockBootWithPersist(T, os.time() - 600)
    T.eq(h.pending(API_URL), 1)
  end)

  T.test("#5: a throwing PersistGetValue cannot abort OnDriverLateInit", function()
    local h = T.driver({ noBoot = true, bound = ALL, properties = { ["Auto Update"] = "Beta" } })
    h.env.__C4impl.PersistGetValue = function() error("persist store unavailable") end
    h.env.OnDriverInit()
    h.env.OnDriverLateInit()
    T.eq(h.var("MODE"), "Off", "init completed")
    T.eq(#h.log.registered_events, 1, "history registration still ran")
  end)

  -- -------------------------------------------------------------------------
  -- Timer, property change, force install
  -- -------------------------------------------------------------------------

  T.test("#5: Beta/Release starts a repeating 24h check timer; firing it checks", function()
    local h = updater({ T = T, installed = "2.2.0-beta.2", channel = "Beta" })
    h.respond(API_URL, releasesJson({ { tag = "v2.2.0-beta.2", prerelease = true } }))
    local timerId
    for id, t in pairs(h.timers) do
      if t.interval == 86400 and t.units == "SECONDS" and t.rep == true then timerId = id end
    end
    T.ok(timerId, "expected a repeating 86400 SECONDS timer")
    h.fire(timerId)
    T.eq(h.pending(API_URL), 1, "timer triggers a check")
    T.ok(h.timers[timerId], "repeating timer still active after firing")
  end)

  T.test("#5: switching Auto Update to Beta checks immediately; back to Off kills the timer", function()
    local h = T.driver({ bound = ALL })
    h.env.Properties["Auto Update"] = "Beta"
    h.env.OnPropertyChanged("Auto Update")
    T.eq(h.pending(API_URL), 1, "immediate check")
    T.eq(h.activeTimerCount(), 1)
    h.env.Properties["Auto Update"] = "Off"
    h.env.OnPropertyChanged("Auto Update")
    T.eq(h.activeTimerCount(), 0)
  end)

  T.test("#5: Install Latest Release (Force) reinstalls even when up to date", function()
    local h = updater({ T = T, installed = "2.2.0" })
    h.env.ExecuteCommand("LUA_ACTION", { ACTION = "INSTALL_UPDATE" })
    h.respond(API_URL, releasesJson({ { tag = "v2.2.0" } }))
    T.eq(downloads(h), 1, "forced download")
    h.respond("/releases/download/", C4Z_BYTES, 302)
    T.eq(#h.tcp, 1, "forced SOAP")
  end)

  -- -------------------------------------------------------------------------
  -- Hardening added after the adversarial review of #5
  -- -------------------------------------------------------------------------

  T.test("#5: a truncated download (size mismatch) is never written", function()
    local h = updater({ T = T, installed = "2.2.0-beta.1", channel = "Beta" })
    h.respond(API_URL, releasesJson({ { tag = "v2.2.0-beta.2", prerelease = true } }))
    h.respond("/releases/download/", C4Z_BYTES:sub(1, 50), 302)
    T.eq(h.files["C4Z_ROOT/" .. ASSET], nil)
    T.eq(#h.tcp, 0)
  end)

  T.test("#5: a well-formed but wrong-sized body is rejected by the size check alone", function()
    local h = updater({ T = T, installed = "2.2.0-beta.1", channel = "Beta" })
    local body = "PK\3\4" .. "short" .. "PK\5\6" .. string.rep("\0", 18)  -- magic + EOCD ok
    h.respond(API_URL, releasesJson({ { tag = "v2.2.0-beta.2", prerelease = true } }))  -- size = #C4Z_BYTES
    h.respond("/releases/download/", body, 302)
    T.eq(h.files["C4Z_ROOT/" .. ASSET], nil)
    T.ok(h.env.Properties["Last Update Check"]:find("expected", 1, true),
         tostring(h.env.Properties["Last Update Check"]))
  end)

  T.test("#5: a zip with no end-of-archive record is never written (size unknown)", function()
    local h = updater({ T = T, installed = "2.2.0-beta.1", channel = "Beta" })
    local body = "PK\3\4" .. string.rep("y", 200)
    -- Asset size matches the body, so only the end-of-archive check can catch it.
    h.respond(API_URL, releasesJson({ { tag = "v2.2.0-beta.2", prerelease = true, size = #body } }))
    h.respond("/releases/download/", body, 302)
    T.eq(h.files["C4Z_ROOT/" .. ASSET], nil)
    T.eq(#h.tcp, 0)
  end)

  T.test("#5: an existing longer driver file is fully replaced (delete before write)", function()
    local h = updater({ T = T, installed = "2.2.0-beta.1", channel = "Beta" })
    h.files["C4Z_ROOT/" .. ASSET] = string.rep("OLD", 1000)
    h.respond(API_URL, releasesJson({ { tag = "v2.2.0-beta.2", prerelease = true } }))
    h.respond("/releases/download/", C4Z_BYTES, 302)
    T.eq(h.files["C4Z_ROOT/" .. ASSET], C4Z_BYTES, "no stale tail from the old file")
  end)

  T.test("#5: if the file can't be written, no SOAP is sent and a retry is possible", function()
    local h = T.driver({ bound = ALL, properties = { ["Auto Update"] = "Beta" },
                         driverVersion = "2.2.0-beta.1", fileOpenFails = true })
    h.respond(API_URL, releasesJson({ { tag = "v2.2.0-beta.2", prerelease = true } }))
    h.respond("/releases/download/", C4Z_BYTES, 302)
    T.eq(#h.tcp, 0, "must not SOAP-reload a file that was never written")
    T.eq(h.persist["last_install_attempt"], nil)
    h.env.ExecuteCommand("LUA_ACTION", { ACTION = "CHECK_UPDATES" })
    h.respond(API_URL, releasesJson({ { tag = "v2.2.0-beta.2", prerelease = true } }))
    T.eq(downloads(h), 2, "in-flight flag cleared after the failure")
  end)

  T.test("#5: a throwing PersistSetValue does not stop the install", function()
    local h = updater({ T = T, installed = "2.2.0-beta.1", channel = "Beta" })
    h.env.__C4impl.PersistSetValue = function() error("persist store unavailable") end
    h.respond(API_URL, releasesJson({ { tag = "v2.2.0-beta.2", prerelease = true } }))
    h.respond("/releases/download/", C4Z_BYTES, 302)
    T.eq(#h.tcp, 1)
  end)

  T.test("#5: only one install at a time (second trigger while downloading is ignored)", function()
    local h = updater({ T = T, installed = "2.2.0-beta.1", channel = "Beta" })
    h.respond(API_URL, releasesJson({ { tag = "v2.2.0-beta.2", prerelease = true } }))
    h.env.ExecuteCommand("LUA_ACTION", { ACTION = "CHECK_UPDATES" })
    h.respond(API_URL, releasesJson({ { tag = "v2.2.0-beta.2", prerelease = true } }))
    T.eq(downloads(h), 1)
    T.ok(printed(h, "Install already in progress"))
  end)

  T.test("#5: anti-loop guard also covers the timer path; manual check bypasses it", function()
    local h = updater({ T = T, installed = "2.2.0-beta.1", channel = "Beta" })
    h.respond(API_URL, releasesJson({ { tag = "v2.2.0-beta.1", prerelease = true } }))   -- boot: up to date
    h.persist["last_install_attempt"] = tostring(os.time() - 30)
    local timerId
    for id, t in pairs(h.timers) do if t.interval == 86400 then timerId = id end end
    h.fire(timerId)
    h.respond(API_URL, releasesJson({ { tag = "v2.2.0-beta.2", prerelease = true } }))
    T.eq(downloads(h), 0, "timer must respect the anti-loop guard")
    T.ok(h.env.Properties["Last Update Check"]:find("recent install attempt", 1, true))
    h.env.Properties["Auto Update"] = "Beta"
    h.env.OnPropertyChanged("Auto Update")
    h.respond(API_URL, releasesJson({ { tag = "v2.2.0-beta.2", prerelease = true } }))
    T.eq(downloads(h), 0, "property change must respect the anti-loop guard")
    h.env.ExecuteCommand("LUA_ACTION", { ACTION = "CHECK_UPDATES" })
    h.respond(API_URL, releasesJson({ { tag = "v2.2.0-beta.2", prerelease = true } }))
    T.eq(downloads(h), 1, "Check for Updates Now is the explicit retry")
  end)

  T.test("#5: Force while Off uses the Release channel", function()
    local h = updater({ T = T, installed = "2.2.0" })
    h.env.ExecuteCommand("LUA_ACTION", { ACTION = "INSTALL_UPDATE" })
    h.respond(API_URL, releasesJson({
      { tag = "v2.3.0-beta.1", prerelease = true },
      { tag = "v2.2.0" },
    }))
    T.eq(h.env.Properties["Latest Available Version"], "v2.2.0")
    T.eq(h.requests[2].url:find("/v2.2.0/", 1, true) ~= nil, true, "downloads the stable tag")
  end)

  T.test("#5: Force never downgrades (would strand the device on a pre-updater version)", function()
    local h = updater({ T = T, installed = "2.2.0-beta.1" })
    h.env.ExecuteCommand("LUA_ACTION", { ACTION = "INSTALL_UPDATE" })
    h.respond(API_URL, releasesJson({ { tag = "v2.0.1" } }))
    T.eq(downloads(h), 0)
    T.ok(h.env.Properties["Last Update Check"]:find("force refused", 1, true))
  end)

  T.test("#5: Beta picks the highest version, not the newest by date", function()
    -- A stable hotfix published after a beta comes first in GitHub's list.
    local h = updater({ T = T, installed = "2.1.1", channel = "Beta" })
    h.respond(API_URL, releasesJson({
      { tag = "v2.1.2" },
      { tag = "v2.2.0-beta.2", prerelease = true },
      { tag = "v2.2.0-beta.1", prerelease = true },
    }))
    T.eq(h.env.Properties["Latest Available Version"], "v2.2.0-beta.2")
  end)

  T.test("#5: a release with an empty assets list doesn't borrow the next release's asset", function()
    local h = updater({ T = T, installed = "2.2.0-beta.1", channel = "Beta" })
    h.respond(API_URL, releasesJson({
      { tag = "v2.2.0-beta.3", prerelease = true, assets = {} },
      { tag = "v2.2.0-beta.2", prerelease = true },
    }))
    T.eq(downloads(h), 0, "beta.3 is highest but has no asset: skip, don't fetch beta.2's file as beta.3")
  end)

  T.test("#5: update work does not disturb door behaviour (mode, relays, history)", function()
    local h = updater({ T = T, installed = "2.2.0-beta.1", channel = "Beta" })
    h.env.ExecuteCommand("SET_MODE_AUTO", {})
    h.respond(API_URL, releasesJson({ { tag = "v2.2.0-beta.1", prerelease = true } }))
    T.eq(h.var("MODE"), "Auto")
    T.eq(h.lastProxy(ARM_RELAY).cmd, "CLOSE")
  end)
end
