# Changelog

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
