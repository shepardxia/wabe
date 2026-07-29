# wabe

**An orientation service for Apple Silicon MacBooks, including where the screen faces.**

<!-- DEMO GIF -->

A phone is one rigid body. A laptop is two on a hinge, and the hinge angle is readable to 0.01°.
Compose base attitude with lid angle and you get the orientation of the *display plane*: not
where the machine points, where the **screen** points. Underneath are the undocumented SPU
sensors (Bosch BMI286, 795 Hz) and the lid encoder. No root, no entitlements, no kext.

## Install

```bash
swift build -c release
.build/release/wabe install    # launchd agent, starts at login, still no root
```

`wabe status` shows what it sees, `wabe watch` streams a live readout, `wabe uninstall` reverses
all of it.

## Demo

```bash
swift run --package-path examples/magic-window   # m: mode · r: recenter · q: quit
```

Pick the laptop up and turn it: the screen becomes a window onto a room that stays put. Separate
package, so installing the service does not build it.

## Usage

`wabed` publishes newline JSON on `/tmp/wabe.sock`. Write `recenter\n` to zero your heading, or
`rate 60\n` to pick your update rate. Both are per connection. One client cannot move another
client's world or dictate its frame rate.

```json
{"q":[0.9997,-0.0237,0.0009,0.0000], "rpy":[0.109,2.718,-0.000], "lid":108.54,
 "n":[0.0007,-0.9320,0.3626], "bias":[0.153,0.001,0.000], "stat":true}
```

`q` is base to world (X right, Y toward hinge, Z up). **`n` is the screen normal in world
frame**, the field the project exists for. In `rpy`, roll and pitch are absolute, measured
against gravity. Macs ship no magnetometer, so nothing plays that role for yaw: it is relative
to your last `recenter`, not a compass heading.

Or link the C library and skip the socket:

```c
wabe *w = wabe_start(NULL, NULL);   // opens the sensors, tracks in the background

wabe_orientation o;                 // pull: newest value, any thread
wabe_read(w, &o);                   // o.q, o.rpy, o.n, o.at_rest

wabe_on_update(w, 60, queue, handler, ctx);   // or push, on a queue you choose
wabe_stop(w);
```

`wabe_serve()` is that plus the socket, and `wabe_replay()` is the same tracker fed from a file.
Full API in [`Sources/libwabe/include/wabe.h`](Sources/libwabe/include/wabe.h).

## Replay

[VQF](https://github.com/dlaidig/vqf) turns the accelerometer and gyroscope readings into
orientation. Vendored, MIT.

`wabed --record` writes raw samples, and `wabe-replay` runs them back through the same code the
live daemon uses. Sessions are recorded with one laptop edge flush against a straightedge at
start and finish, so the true heading is known and any drift is measured, not guessed:

```bash
curl -L -o session.jsonl.gz \
  https://github.com/shepardxia/wabe/releases/download/captures-v1/session.jsonl.gz
swift run wabe-replay session.jsonl.gz
```

Measurements and the sensor reverse engineering: [NOTES.md](NOTES.md).

## Credits

- [samhenrigold](https://github.com/samhenrigold/LidAngleSensor) reverse engineered the lid sensor
- [olvvier](https://github.com/olvvier/apple-silicon-accelerometer) found the IMU and its wire format
- [taigrr](https://github.com/taigrr/apple-silicon-accelerometer) ported it to Go. The driver
  wake sequence came from there
- [dlaidig](https://github.com/dlaidig/vqf) wrote VQF

Apple Silicon MacBook, macOS 13+. Verified on an M4 Pro. MIT.
