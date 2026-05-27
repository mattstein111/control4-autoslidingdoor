# Auto Sliding Door — Experience Button Driver Design

**Status:** Approved for implementation
**Date:** 2026-05-26
**Project:** `control4-autoslidingdoor`
**Driver artifact:** `autoslidingdoor.c4z`

---

## v2 amendment (2026-05-26)

After installing v1, the user evaluated the cost of wiring the gesture state machine (single / double / long-press) in keypad button programming and decided to push the decoder into the driver. v2 adds, on top of the existing v1 surface:

- **Two new actions:** `On Button Pressed`, `On Button Released`. Caller wires their physical button's Press event → On Button Pressed and Release event → On Button Released. No custom timers or variables required on the caller side.
- **Two new properties:** `Long Press Threshold (ms)` (default 1000) and `Double Click Window (ms)` (default 400).
- **Internal gesture state machine** (in `driver.lua`) decodes:
  - Single press (no second press within double-click window) → if MODE == Off, call `OpenForN`; else call `SetMode("Off")`.
  - Double press → `SetMode("Auto")`.
  - Long press → `SetMode("Hold")` the moment the threshold elapses (before release).
- Existing granular actions (`Open Door`, `Set Mode to X`, `Cancel Pending Open`) remain available for voice, scenes, and advanced programming. Granular and gesture surfaces coexist; nothing was removed.

The original §3 "only granular actions" decision was overturned by user pivot. The gesture decoder is layered on top, not a replacement.

---

## 1. Use case

A residential sliding door with motion-driven auto-opening, controlled from Control4 via two relays and a contact sensor. Need a single Navigator/Composer surface that exposes door behavior as three sustained modes plus a one-shot timed-open action, and provides clean programming hooks (events, conditions, actions) so a physical keypad button can drive the door and other programming can react to mode changes (announcements, lights).

### Physical model

| Wire | Direction | Behavior |
|---|---|---|
| Open Door relay | C4 → door | Closed = door slides open. Open = door slides closed. Holding closed keeps door open. |
| Arm Motion relay | C4 → door | Closed = door's built-in motion sensors armed (they then trigger door open on their own). |
| Door Contact sensor | door → C4 | Reports actual door position (open/closed). |

The Open Door relay and the door's motion-sensor output are wired in parallel — either triggers physical open. The driver only sees its own relay.

---

## 2. State model

One mode variable, three values:

```
MODE ∈ { Off, Hold, Auto }
```

Plus a derived door-position variable from the contact sensor:

```
DOOR_STATE ∈ { Open, Closed, Unknown }
```

### Mode semantics

| Mode | Open Door relay | Arm Motion relay | Door behavior |
|---|---|---|---|
| **Off** | Open | Open | Door closes (or stays closed). Motion sensors disarmed. |
| **Hold** | Closed | Open | Door slides open and stays open until mode changes or Hold Duration elapses. |
| **Auto** | Open | Closed | Motion sensors armed — door auto-opens on detected motion, auto-closes when motion stops. |

### Relay computation (single source of truth)

Both relays are recomputed from state on every transition — they are **never** driven directly by action handlers:

```
Open Door relay closed   ⇔   (MODE == Hold)  OR  (open_for_N timer is running)
Arm Motion relay closed  ⇔   (MODE == Auto)
```

This makes Hold and Open-for-N compose cleanly: an Open-for-N timer running underneath Hold is harmless (relay already closed); a mode change always recomputes outputs from scratch.

---

## 3. Action API

All actions are callable from Control4 programming, voice, scenes, and keypads. The driver exposes only granular actions — gesture logic (single/double/long-press behavior on a physical button) lives in the caller's programming.

| Action | Param | Behavior |
|---|---|---|
| `Open for N Seconds` | `seconds` (optional; defaults to property `Default Open Duration`) | Closes Open Door relay for N seconds then releases. Fires regardless of current mode. If called while a previous Open-for-N timer is running, **resets** the timer (intuitive "keep it open longer"). Does NOT change MODE. |
| `Set Mode → Off` | — | Sets `MODE = Off`. Cancels any running open timer. Recomputes relays (both → open). Cancels any Hold-duration timer. |
| `Set Mode → Hold` | — | Sets `MODE = Hold`. Cancels any running open timer (timer becomes meaningless once Hold owns the relay). Recomputes relays (Open relay closed, Arm relay open). If `Hold Duration > 0`, starts an auto-release timer. |
| `Set Mode → Auto` | — | Sets `MODE = Auto`. Recomputes relays (Open relay open, Arm relay closed). |
| `Cancel Pending Open` | — | If an Open-for-N timer is running, stop it. Mode unchanged. |

### Action behavior rules

1. **Idempotent mode setters:** calling `Set Mode → X` when already in mode X is a no-op — no event fires, no relay re-pulse, no LED re-update. Prevents announcement/light-flash spam.
2. **Mode change cancels Open-for-N timer:** any mode transition stops any pending Open-for-N timer for predictability.
3. **Default duration is a single source of truth:** the `Default Open Duration` property is used when `Open for N Seconds` is called with no parameter. Change once, everything follows.

---

## 4. Events

Fire only on actual state transitions:

| Event | When |
|---|---|
| `Mode Changed to Off` | MODE transitions to Off |
| `Mode Changed to Hold` | MODE transitions to Hold |
| `Mode Changed to Auto` | MODE transitions to Auto |
| `Door Opened` | Door contact sensor reports door is now open (post-debounce) |
| `Door Closed` | Door contact sensor reports door is now closed (post-debounce) |
| `Still Open` | Only fires if `Still Open Time > 0`. Door has been continuously open this long. |

---

## 5. Conditions (for IF blocks in programming)

| Condition | Test |
|---|---|
| `Mode is X` | X ∈ {Off, Hold, Auto} — compares against current MODE |
| `Door is X` | X ∈ {Open, Closed, Unknown} — compares against current DOOR_STATE |

---

## 6. Variables

Exposed for programming and Navigator inspection:

| Variable | Type | Values |
|---|---|---|
| `MODE` | STRING | "Off" / "Hold" / "Auto" |
| `DOOR_STATE` | STRING | "Open" / "Closed" / "Unknown" |

---

## 7. Properties (Composer-configurable)

| Property | Type | Default | Purpose |
|---|---|---|---|
| Driver Version | STRING (readonly) | auto | Set by Lua on init |
| Debug Mode | LIST (Off/On) | Off | Verbose Lua output |
| Default Open Duration (s) | RANGED_INTEGER 1–600 | 5 | Used by `Open for N Seconds` when no parameter supplied |
| Hold Duration (s) | RANGED_INTEGER 0–3600 | 0 | **0 = unlimited.** If non-zero, Hold auto-releases to Off after this many seconds. Safety against accidentally-held-open doors. |
| Invert Open Relay | LIST (Yes/No) | No | For normally-closed wiring |
| Invert Arm Motion Relay | LIST (Yes/No) | No | Same |
| Invert Door Contact | LIST (Yes/No) | No | For NC contact sensors |
| Door Contact Debounce (ms) | RANGED_INTEGER 1–1000 | 250 | Anti-glitch on sensor input |
| Still Open Time (s) | RANGED_INTEGER 0–3600 | 0 | **0 = disabled.** Fires `Still Open` event after door has been open this long. |
| Off LED Color | COLOR_SELECTOR | 0,0,200 (blue) | Bound keypad LED color when MODE = Off |
| Hold LED Color | COLOR_SELECTOR | 200,200,0 (amber) | Bound keypad LED color when MODE = Hold |
| Auto LED Color | COLOR_SELECTOR | 0,200,0 (green) | Bound keypad LED color when MODE = Auto |
| Mode (readonly) | STRING (readonly) | "Off" | Mirrors MODE variable for at-a-glance Composer visibility |
| Door State (readonly) | STRING (readonly) | "Unknown" | Mirrors DOOR_STATE |
| Contact Status (readonly) | STRING (readonly) | auto | Reports whether the door sensor binding is wired |

All Invert properties apply at the wire level; the rest of the code reasons in logical "closed = active" terms.

---

## 8. Composer surface

### Proxy

One proxy: `uibutton` (experience button). Same proxy type used by the stock `door_relay_control` driver.

```xml
<proxy proxybindingid="5001" name="Auto Sliding Door" image_source="c4z"
       large_image="icons/device_lg.png"
       small_image="icons/device_sm.png">uibutton</proxy>
```

### Connections wired in Composer

| Connection name | Direction | Class | Required | Notes |
|---|---|---|---|---|
| Open Door Relay | output | RELAY | Yes | Closed by driver to open / hold door |
| Arm Motion Relay | output | RELAY | Yes | Closed by driver to arm motion sensors |
| Door Contact | input | CONTACT_SENSOR | Recommended | If unwired, DOOR_STATE stays "Unknown" and door events don't fire |
| Open (BUTTON_LINK) | optional | BUTTON_LINK | No | Keypad-drag target → calls `Open for N Seconds` |
| Off (BUTTON_LINK) | optional | BUTTON_LINK | No | Keypad-drag target → calls `Set Mode → Off` |
| Hold (BUTTON_LINK) | optional | BUTTON_LINK | No | Keypad-drag target → calls `Set Mode → Hold` |
| Auto (BUTTON_LINK) | optional | BUTTON_LINK | No | Keypad-drag target → calls `Set Mode → Auto` |

All BUTTON_LINK connections are `<autobind>False</autobind>` — only used if an integrator explicitly drags a keypad button onto them. Most integrations are expected to put programming on a button press that calls the granular actions directly.

### Composer categorization

```xml
<capabilities>
  <DeviceType>Door</DeviceType>
</capabilities>
<composer_categories>
  <category>Motorization</category>
</composer_categories>
```

### Navigator presence

Appears as an experience button in any room toggled visible (Room Properties → Navigator Tab → Device Visibility). Tile icon swaps based on MODE via `<navigator_display_option><state id="...">` — three states: `Mode_Off`, `Mode_Hold`, `Mode_Auto`.

**Tile tap behavior:** taps on the Navigator tile always call `Open for N Seconds` with the default duration. Tile tap **never** changes mode — keeps the tile guest-friendly and predictable. Mode is changed only via keypad/voice/programming.

---

## 9. Runtime behavior

### Single state-transition function

All paths that change MODE funnel through one function:

```
SetMode(newMode):
  1. if newMode == current MODE: return (no-op, no event)
  2. Cancel any pending Open-for-N timer
  3. Cancel any Hold-duration timer
  4. Update MODE variable + "Mode" property
  5. Recompute Open Door relay: closed iff (newMode == Hold) OR (open_timer running — false here)
  6. Recompute Arm Motion relay: closed iff (newMode == Auto)
  7. Update Navigator tile state (Mode_Off / Mode_Hold / Mode_Auto)
  8. Update bound keypad LED colors
  9. Fire "Mode Changed to <newMode>" event
  10. C4:RecordHistory with mode-change message
  11. If newMode == Hold and Hold Duration > 0: start auto-release timer
```

### Open-for-N path

Separate from SetMode and never touches MODE:

```
OpenForN(seconds):
  1. Cancel previous Open-for-N timer if any (reset semantics)
  2. Close Open Door relay (no-op if already closed by Hold)
  3. Start N-second timer
  On expiry:
    - Recompute Open Door relay (open it unless Hold still wants it closed)
```

### Sensor handler

Triggered when the CONTACT_SENSOR binding state changes:

```
OnDoorSensorChange(rawState):
  1. Apply "Invert Door Contact" property
  2. Apply debounce per "Door Contact Debounce" property
  3. If logical position actually changed:
     a. Update DOOR_STATE variable + "Door State" property
     b. Update Navigator tile (if door-state ever shown there — v1: no)
     c. Fire "Door Opened" or "Door Closed" event
     d. Start or cancel "Still Open" watchdog timer
     e. C4:RecordHistory
```

### Driver lifecycle hooks

| Hook | Responsibility |
|---|---|
| `OnDriverInit` | Register handlers, populate Driver Version property, init internal state (MODE = Off, DOOR_STATE = Unknown), no I/O yet. |
| `OnDriverLateInit` | Call FileSetDir handshake (per c4-conventions §3a) for future self-update capability. Defensively open both relays. Call `SetMode("Off")` to publish initial state. Request current sensor state. |
| `OnBindingChanged(idBinding, strClass, bIsBound)` | When sensor binding is wired/unwired, update "Contact Status" property and request current sensor state. |
| `OnPropertyChanged(sProperty)` | Per-property handler; Invert and Debounce changes recompute current outputs immediately. |
| `OnDriverDestroyed` | Cancel all timers. Release relays to Open. |
| `ReceivedFromProxy` | Handle Navigator tile interaction. `DO_CLICK` → call `Open for N Seconds` with default duration. |
| `ExecuteCommand` | Action dispatch. Each action maps to an `EX_CMDS.<name>` handler. |

### Director restart recovery

After Director restart, driver wakes up with `MODE = Off` and both relays opened. If Hold was active and Director crashes, the door slides closed — safe default. Any "restore previous state on restart" behavior is the integrator's responsibility (handled in their own startup programming).

### Edge cases (canonical answers)

| Scenario | Behavior |
|---|---|
| `Open for N` called while in Hold | Timer runs but relay stays closed (Hold owns it). Timer expires uneventfully. |
| `Open for N` called while in Auto | Open relay closes for N sec, then releases. Auto mode unchanged; motion-sensor relay stays armed. |
| `Open for N` called while another timer running | New call resets the timer to N from now. |
| `Set Mode → Hold` called while Open-for-N running | Timer cancelled. Relay stays closed (now owned by Hold). |
| `Set Mode → Off` while Hold-duration timer running | Hold-duration timer cancelled. |
| `Set Mode → X` when already X | No-op. No event, no relay re-pulse, no LED flash. |
| Sensor binding unwired | DOOR_STATE = "Unknown". Door Opened/Closed and Still Open events don't fire. Other behavior unaffected. |
| Relay binding unwired | Driver still tracks state and fires events. Relay write becomes a Director no-op. Debug log warning. |
| Hold Duration > 0 elapses | Driver calls `SetMode("Off")` — fires "Mode Changed to Off" event. |

---

## 10. File layout

```
control4-autoslidingdoor/
├── driver.xml                     # Composer-facing definition
├── driver.lua                     # Runtime logic
├── README.md                      # Public-facing repo readme
├── CHANGELOG.md
├── build.sh                       # Builds autoslidingdoor.c4z
├── www/
│   ├── documentation.html         # In-Composer help text
│   └── icons/
│       ├── icon_padded.svg        # Source SVG, padded wrapper per c4-conventions §1
│       ├── device_sm.png          # 16×16 (NOT 32, per §1)
│       ├── device_lg.png          # 32×32 (NOT 64, per §1)
│       ├── experience_20.png      # …full ladder: 20,30,40,50,60,70,80,90,100,110,120,130,140,300,512,1024
│       └── device/
│           ├── mode_off/          experience_{70,90,300,512,1024}.png
│           ├── mode_hold/         experience_{70,90,300,512,1024}.png
│           └── mode_auto/         experience_{70,90,300,512,1024}.png
└── docs/
    └── superpowers/
        └── specs/
            └── 2026-05-26-auto-sliding-door-experience-button-design.md
```

---

## 11. Build & versioning

### Build command

```sh
zip -r autoslidingdoor.c4z driver.xml driver.lua www/ -x '*.DS_Store' '.*'
```

Wrapped as `./build.sh`. Output is one `.c4z` artifact at repo root.

### Version scheme

- `<version>` in `driver.xml` = `git rev-list --count HEAD` (monotonic integer, per c4-conventions §4 — `YYYYMMDDHHMM` overflows Composer's int).
- `<modified>` set to current date on each release.
- Initial release: `<version>1</version>`.

### Auto-update (deferred to v2)

GitHub-release self-install (per c4-conventions §3 and §3a) is **out of scope for v1**. The hook would be `OnDriverLateInit` calling the FileSetDir handshake then checking GitHub Releases. Lua scaffolding for the handshake is included in v1 (so the unlock is in place) but the actual update-check is deferred.

---

## 12. Manual test plan (run after each `.c4z` rebuild)

Pre-flight:
- [ ] `luac -p driver.lua` (syntax check)
- [ ] `xmllint --noout driver.xml` (XML validity)
- [ ] `.c4z` loads in Composer without warnings
- [ ] Driver Version property auto-populates

Wiring:
- [ ] All 3 required connections (2 relays + sensor) can be bound to physical hardware
- [ ] "Contact Status" property updates when sensor binding is added/removed
- [ ] All 4 BUTTON_LINK connections appear in Composer connection picker

Modes:
- [ ] On install, MODE = Off, both relays open
- [ ] Set Mode → Hold: open relay closes, door opens, "Mode Changed to Hold" event fires, tile icon swaps
- [ ] Set Mode → Hold again: no event re-fire (idempotent)
- [ ] Set Mode → Auto from Hold: arm relay closes, open relay opens. "Mode Changed to Auto" fires immediately. As the door physically closes, "Door Closed" fires asynchronously once the sensor confirms.
- [ ] Set Mode → Off from Auto: arm relay opens, "Mode Changed to Off" fires

Open-for-N:
- [ ] Call Open for 5 Seconds from Off: open relay closes for ~5s, then releases. Door opens then closes.
- [ ] Call Open for 5 Seconds with no parameter: uses Default Open Duration property
- [ ] Call Open for 10 Seconds while in Hold: visible behavior = nothing (relay stays closed). Timer expires silently.
- [ ] Call Open for 5 Seconds while in Auto: open relay closes for 5s, door opens, releases. Arm relay stays closed.
- [ ] Call Open for 5 Seconds twice within 3 seconds: second call extends to 5s from second call (reset semantics)
- [ ] Cancel Pending Open while timer running: timer stops, relay opens immediately

Hold auto-release:
- [ ] Set Hold Duration to 10. Set Mode → Hold. After ~10s, MODE returns to Off, "Mode Changed to Off" fires.
- [ ] Set Hold Duration to 0 (default). Set Mode → Hold. Stays in Hold indefinitely.

Sensor:
- [ ] Manually open door: "Door Opened" event fires post-debounce, DOOR_STATE updates
- [ ] Manually close door: "Door Closed" event fires, DOOR_STATE updates
- [ ] Bounce sensor rapidly: only one event fires within debounce window
- [ ] Invert Door Contact = Yes: logical state flips

Still Open:
- [ ] Set Still Open Time = 15. Open door, wait 15s: "Still Open" event fires.
- [ ] Close door before 15s: timer cancels, no Still Open event.

Director restart:
- [ ] Put driver in Hold. Restart Director. After restart: MODE = Off, both relays open.

Programming integration (manual end-to-end with the user's physical button):
- [ ] Single press → action programmed to either Open-for-N or Set-Mode→Off based on current mode
- [ ] Double press → Set Mode → Auto (announcement fires, light color changes)
- [ ] Long press → Set Mode → Hold (announcement fires, light color changes)

---

## 13. Out of scope (explicitly deferred)

- **Auto-update from GitHub Releases.** v1 is manually installed via Composer. v2 can add the self-install pattern per c4-conventions §3, §3a.
- **Door-state-aware Navigator icon.** v1 tile shows only mode (3 icons). Composing door-position into the tile (e.g., overlay badge or 6-icon matrix) is future work.
- **Per-action LED colors.** v1 colors keypad LEDs by mode only. Per-action flash on action invocation is future work.
- **Multiple sliding doors per driver.** v1 is one driver per door. Multi-door support would require a different proxy model.
- **Voice integration beyond C4 actions.** Voice grammar surfaces the granular actions; no additional voice scaffolding in v1.

---

## 14. Naming summary

| Surface | Name |
|---|---|
| Project folder | `control4-autoslidingdoor` |
| GitHub repo (when created) | `mattstein111/control4-autoslidingdoor` |
| Driver name in Composer driver browser | `Auto Sliding Door` |
| `<proxy name>` (default device name) | `Auto Sliding Door` |
| Artifact filename | `autoslidingdoor.c4z` |
| C4 controller-relative URI base | `controller://driver/autoslidingdoor/` |
| Composer category | `Motorization` |
| DeviceType capability | `Door` |

In Navigator, the integrator typically renames the device to its install location (e.g. "Back Patio Door") — the driver's default name is just a starting point.
