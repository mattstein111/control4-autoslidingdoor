# control4-autoslidingdoor

Control4 DriverWorks experience-button driver for a motion-sensor-enabled sliding door.

The door is wired with **two relays** (one to open / hold the door open, one to arm its built-in motion sensors) and **one contact sensor** (door position). This driver exposes the whole thing as a single experience button in Composer / Navigator with three sustained modes:

| Mode | Behavior |
|---|---|
| **Off** | Door closed, motion sensors disarmed |
| **Hold** | Door slides open and stays open (relay held closed) |
| **Auto** | Motion sensors armed — door auto-opens when motion is detected |

Plus a one-shot **Open Door for N Seconds** action.

## Building

```sh
./build.sh
```

Produces `autoslidingdoor.c4z` at the repo root. Add it to your Control4 project in Composer.

## Installing

1. Build (above) or download the latest `.c4z`.
2. In Composer: **System Design → Search Drivers → Add Driver from File → autoslidingdoor.c4z**.
3. Drop the driver into a room.
4. Wire the connections in **Connections — Control/AV**:
   - `Open Door Relay` → physical relay output controlling the door's open trigger
   - `Arm Motion Relay` → physical relay output that arms the door's motion sensors
   - `Door Contact` → contact sensor on the door (recommended)
5. (Optional) bind a keypad button to one of the BUTTON_LINK targets (`Open / Off / Hold / Auto`).
6. Show the experience button in Navigator via **Room Properties → Navigator Tab → Device Visibility**.

See `www/documentation.html` (also shown in Composer's documentation pane) for full setup, action API, events, and conditions.

## Design

See `docs/superpowers/specs/2026-05-26-auto-sliding-door-experience-button-design.md` for the full design spec.

## License

MIT
