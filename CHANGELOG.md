# Changelog

## v2.2.0-beta.2 — 2026-10-15

- Version-only bump: release **N+1** for the on-hardware auto-update smoke test ([#5](https://github.com/mattstein111/control4-autoslidingdoor/issues/5)). Install `v2.2.0-beta.1` from its release asset, set `Auto Update` = Beta, and the driver should update itself to this release. No functional changes.
- Driver `<version>` 8 → 9.

## v2.2.0-beta.1 — 2026-10-15

- **New [#5](https://github.com/mattstein111/control4-autoslidingdoor/issues/5): self-installing auto-update from GitHub Releases.** Install once through Composer; new releases then install themselves in place, keeping bindings, properties and programming. Ported from control4-frigate's updater (single-driver variant) with the frigate #33 improvements.
  - `Auto Update` property: **Off** (default) / Release / Beta. Checks at startup, on change and every 24 hours.
  - Actions: **Check for Updates Now** (report-only while Off) and **Install Latest Release (Force)**.
  - Read-only status: `Latest Available Version`, `Update Download URL`, `Last Update Check` (time and outcome).
  - Safety: complete-file check before writing (ZIP signature, end-of-archive record, size matches GitHub's), no reload if the write fails, 5-minute anti-loop guard on every automatic path, one install at a time, never downgrades (Force included), persistence and SOAP faults contained.
  - Picks the channel's **highest** version, not GitHub's newest-by-date. Version comparison handles any number of parts (`0.9.1.9 > 0.9.1.8`), numeric prerelease segments (`beta.10 > beta.9`), `V`/case, and ignores `+build`.
  - Release walker fixes a frigate bug where the release after a rejected one (draft / wrong channel) was skipped.
- **New release pipeline** `.github/workflows/release.yml`: pushing `v*` checks the tag equals `DRIVER_VERSION`, runs the test suite, builds, and attaches `autoslidingdoor.c4z`. Any tag with a `-` becomes a prerelease.
- `build.sh` / `tests/run_tests.sh` find `luac5.1` / `lua5.1` where plain `luac` / `lua` aren't installed (Ubuntu CI).
- README: Auto Update section, the release checklist, an on-hardware smoke-test procedure, and a corrected Versioning section (`<version>` is +1 per release, not `git rev-list --count`). The release badge now tracks the latest release automatically.
- Tests: new `tests/test_autoupdate.lua` (49 cases; 83 total). Every hardening rule is pinned by a test that fails when the rule is removed (mutation-checked).
- Driver `<version>` 7 → 8.

## v2.1.1 — 2026-10-15

- **Fix [#4](https://github.com/mattstein111/control4-autoslidingdoor/issues/4): device history now shows in the Control4 app.** The driver never called `C4:RegisterEvents`, and Navigator only renders history whose (category, subcategory, type) is registered. It also recorded with a five-argument `C4:RecordHistory` (a description string as the fifth argument), which isn't the proven form. Now:
  - every type is registered at startup against the proxy device;
  - every record uses the four-argument form through one `recordHistory()` helper, and a `nil` UUID (not stored) is always logged;
  - category/subcategory changed `Motorization` / `Sliding Door` → **`Locks & Sensors` / `Sliding Door`** (the category Control4's stock relay door drivers use; their subcategories are e.g. `Door (Relay)`);
  - types are now self-describing, since `eventType` is the text the app shows: `Mode Changed to Off/Hold/Auto`, `Door Opened`, `Door Closed`, and `Door Still Open` (now severity **Warning**). Previously: `Off`/`Hold`/`Auto`/`Open`/`Closed`/`Still Open`.
- History and registration calls are `pcall`-guarded, so a history fault can't abort a mode or door-state handler.
- Test suite: the mock now fails any non-four-argument `RecordHistory` and any unregistered history tuple. New `tests/test_history.lua` (13 cases; 34 total).
- Driver `<version>` 6 → 7.

## v2.1.0 — 2026-10-15

- **Fix [#3](https://github.com/mattstein111/control4-autoslidingdoor/issues/3): `MODE` and `DOOR_STATE` are now real Director variables.** They have been documented since v1, but the driver only ever called `C4:SetVariable` and never `C4:AddVariable`, so every write was a silent no-op and the variables never appeared in Composer. They're now created in `OnDriverInit` as read-only `STRING` variables, seeded on every init, and kept in step with the `Mode` / `Door State` properties. Other drivers can now watch the mode (unblocks [control4-mqttmirror #1](https://github.com/mattstein111/control4-mqttmirror/issues/1)).
- Variable writes go through a `pcall`-guarded `setVar()`, so a variable fault can no longer abort the tile-icon / keypad-LED update behind it.
- New offline test suite: `./tests/run_tests.sh` runs the real `driver.lua` against a mock Control4 environment under LuaJIT (Lua 5.1) and stock Lua. See README → Testing.
- Driver `<version>` 5 → 6.

## v2.0.1 — 2026-05-27

- **Fix [#1](https://github.com/mattstein111/control4-autoslidingdoor/issues/1):** driver was inert after install when bindings already existed. `OnBindingChanged` is not re-fired for pre-existing bindings when Composer reloads a driver; the driver now queries `C4:GetBoundProviderBinding` in `OnDriverLateInit` to seed binding state, then pushes desired relay outputs and queries sensor state.

## v2 — 2026-05-26

- **New: built-in gesture decoder.** Two new Actions (`On Button Pressed`, `On Button Released`) let a physical button drive the door without any custom timer/variable programming. Internal state machine maps:
  - Single press → Open Door (if Off) / Set Mode to Off (if Hold or Auto)
  - Double press → Set Mode to Auto
  - Long press → Set Mode to Hold
- New properties: `Long Press Threshold (ms)` (default 1000) and `Double Click Window (ms)` (default 400) to tune the decoder.
- All v1 granular actions remain available for voice / scenes / advanced programming.

## v1 — 2026-05-26

Initial release.

- Three-mode experience button (Off / Hold / Auto) for motion-sensor-enabled sliding doors.
- Granular Actions: Open Door, Open Door for N Seconds, Set Mode to Off / Hold / Auto, Cancel Pending Open.
- Events: Mode Changed to Off/Hold/Auto, Door Opened, Door Closed, Still Open.
- Conditions: Mode is X, Door State is X.
- Variables: MODE, DOOR_STATE.
- Configurable Default Open Duration, Hold Duration (auto-release), Still Open watchdog, contact debounce, per-mode keypad LED colors.
- Per-mode Navigator tile icons (gray Off / amber Hold / green Auto).
- Inversion support for both relays and the door contact.
- Compatible with Control4 OS 2.9.0+.
