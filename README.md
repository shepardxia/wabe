# wabe

**An orientation service for Apple Silicon MacBooks — including where the screen faces.**

> *'Twas brillig, and the slithy toves / Did gyre and gimble in the wabe.* The **wabe** is the
> grass plot around a sundial: the fixed frame all the gyring happens in.

<!-- DEMO GIF -->

## The idea

Your MacBook has an undocumented IMU (Bosch BMI286 accelerometer + gyroscope) and an absolute
encoder on the hinge. Existing libraries read one or the other.

A phone is a single rigid body, so its orientation is one number set. A laptop is **two bodies
on a hinge** — and the hinge angle is directly measurable. Compose base attitude with lid angle
and you get the orientation of the *display plane*: not where the machine points, where the
**screen** points.

That composition is what wabe adds. Everything else here exists to make it dependable: a C
core, a filter chosen by measurement rather than taste, and a way for you to check the numbers
yourself.

## Get started

```bash
swift build -c release
.build/release/wabe install     # launchd agent, starts at login, no root
wabe status                     # is it up, and what does it see
wabe watch                      # live readout — tilt the lid and watch `n` swing
```

`wabe install` puts the daemon in `~/.local/bin`, registers a per-user launchd agent, and waits
for the socket before reporting success. `wabe uninstall` removes all of it. No `sudo` at any
point — not for the install, not for the sensors.

Then the demo:

```bash
swift run wabe-demo             # m: mode · r: recenter · [ ]: eye distance · q: quit
```

Pick the laptop up and turn it. The screen becomes a window onto a room that stays put.

### Check the numbers yourself

The accuracy claims below come from one recorded session, and you can replay it:

```bash
curl -L -o session.jsonl.gz \
  https://github.com/shepardxia/wabe/releases/download/captures-v1/session.jsonl.gz
swift run wabe-replay session.jsonl.gz
```

That capture is raw 795 Hz accelerometer and gyroscope samples in the chip frame, recorded with
`wabed --record` during an **edge-aligned** protocol (`probes/session.py` walks you through
recording your own): the laptop sits flat with one edge flush against a straightedge, gets
handled, and returns to the same edge. Start and end headings are physically identical, so the
true yaw error is known at every re-alignment — and an integer-turn spin has a known true angle.

`wabe-replay` runs a capture through the exact code path the live daemon uses and reports still
segments, settled yaw, and integrated spin angles. Point your own filter at the same file and
you have a like-for-like comparison.

## Fact sheet

Measured on a Mac16,6 (M4 Pro), macOS 26.5.

| | |
|---|---|
| IMU | Bosch BMI286, accelerometer + gyroscope, **795 Hz** |
| Lid angle | absolute, **0.01°** resolution |
| Privileges | none — no root, no entitlements, no kernel extension |
| CPU | ~2% of one core, full rate |
| Power | tens of mW — below the noise floor of the measurement |
| Publish rate | 30 Hz over a unix socket (configurable) |
| Roll, pitch | absolute, gravity-referenced, drift-free |
| Yaw | relative to the last `recenter` — no Mac has a magnetometer |
| Yaw at rest | ≤ 0.07° peak-to-peak, drift under 0.1°/min |
| Yaw after 30 s of hard handling | 2.2° |
| Yaw across a 1080° spin | 0.28° |
| Yaw across a 720° spin | 0.08° |
| Accelerometer stream | dies on ~40% of opens (driver bug); the daemon detects a dry stream in 250 ms and re-execs |

Orientation fusion is [VQF](https://github.com/dlaidig/vqf) (Laidig & Seel 2023, vendored, MIT).
An error-state EKF and a Mahony complementary filter were also written and run against the same
edge-aligned captures; VQF beat both by roughly 10× on every dynamic measure, so they were
deleted instead of kept as options. The comparison is in [NOTES.md](NOTES.md).

## Using it

`wabed` publishes newline-delimited JSON on `/tmp/wabe.sock`:

```json
{"t":1785292089.01, "q":[0.9997,-0.0237,0.0009,0.0000],
 "rpy":[0.109,2.718,-0.000], "lid":108.54,
 "n":[0.0007,-0.9320,0.3626], "bias":[0.153,0.001,0.000], "stat":true}
```

| field | meaning |
|---|---|
| `q` | base→world quaternion (w, x, y, z). Base frame: X right, Y toward hinge, Z up |
| `rpy` | roll, pitch, yaw in degrees |
| `lid` | hinge angle |
| `n` | **screen-plane normal** in the world frame — where the display points |
| `bias` | gyroscope bias estimate, °/s |
| `stat` | at rest |

Write `recenter\n` to the same socket to zero the heading.

The engine underneath is a plain C library with no Swift in the call path — Swift here is only
the CLI, the demo, and the offline tools. Link it directly and skip the socket:

```c
#include <wabe.h>

wabe_filter *f = wabe_filter_new(795.0);
wabe_filter_feed(f, accel, n_accel, gyro, n_gyro);   // chip-frame batches
wabe_filter_set_lid(f, 108.54);

wabe_pose p;
wabe_filter_pose(f, t, &p);        // p.q, p.rpy, p.n, p.bias, p.stationary
```

The filter half is pure computation, which is why the same code serves the live daemon and the
offline replay. `wabe_service_run(&cfg)` is the entire daemon behind one call. Full API in
[`Sources/libwabe/include/wabe.h`](Sources/libwabe/include/wabe.h).

## Requirements

Apple Silicon MacBook, macOS 13+, Xcode command line tools. Developed and verified on an M4 Pro;
the SPU sensors exist on M1 and later, but report formats vary by generation and only this one
has been confirmed.

## Credit

- [samhenrigold/LidAngleSensor](https://github.com/samhenrigold/LidAngleSensor) — the original
  lid-angle reverse engineering
- [olvvier/apple-silicon-accelerometer](https://github.com/olvvier/apple-silicon-accelerometer)
  — found the IMU and documented its wire format
- [taigrr/apple-silicon-accelerometer](https://github.com/taigrr/apple-silicon-accelerometer) —
  Go port; the driver wake sequence came from here
- [dlaidig/vqf](https://github.com/dlaidig/vqf) — the orientation filter

Built on top of that work, wabe adds the screen-plane composition, the pose service, and a set
of findings recorded in [NOTES.md](NOTES.md): the sensors run at 795 Hz rather than the 100 Hz
usually reported, the lid angle has a hidden 0.01° report alongside the whole-degree one, the
accelerometer's stochastic stall at open and how to survive it — and that none of it needs
`sudo`.

## License

MIT
