# Changelog

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
