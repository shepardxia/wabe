# wabe

> *'Twas brillig, and the slithy toves*
> *Did gyre and gimble in the wabe*

**wabe** (n., per Humpty Dumpty): the grass plot around a sundial — the fixed frame in which
all the gyring and gimbling happens.

A pose service for Apple Silicon MacBooks. Your laptop has an undocumented IMU (Bosch BMI286
accelerometer + gyroscope, ~800 Hz) and a lid-angle encoder (0.01° resolution). wabe reads both,
fuses them, and serves the machine's orientation in the world frame over a unix socket —
including the **screen-plane pose**, composed from base attitude ⊕ lid hinge angle.

A phone knows where *it* points. A MacBook is a two-body hinged system with an absolute encoder
on the hinge — wabe knows where the *screen* points. No other library does this composition.

**No root. No entitlements. No kernel extension.** Just IOKit HID from userspace. The engine is
a plain C library (`libwabe`); read it over a socket from any language, or link it directly.

## Demo

```
swift run wabed        # terminal 1: the daemon
swift run wabe-demo    # terminal 2: the magic window
```

Pick up your laptop and turn it — the screen becomes a window into a fixed room. Three modes on
the `m` key:

- **screen-rotation** *(default)* — view bolted to the screen plane; tilting the lid pans the
  view at 0.01° resolution
- **anamorphic window** — the Holbein mode: scene fixed in the room, viewer's eye fixed in front
  of the machine, and each frame rebuilds an off-axis frustum through the physical glass
  ([Kooima's generalized perspective projection](http://160592857366.free.fr/joe/ebooks/ShareData/Generalized%20Perspective%20Projection.pdf)).
  Tilt the screen and the image *shears* so the world stays put — *The Ambassadors*' skull,
  continuously
- **base-rotation** — view bolted to the base; lid motion does nothing (comparison mode)

`r` recenters heading, `[` `]` adjusts eye distance, `q` quits.

## Consuming poses

`wabed` publishes newline-delimited JSON at 30 Hz (configurable) on `/tmp/wabe.sock`:

```json
{"t":1785292089.01, "q":[0.9997,-0.0237,0.0009,0.0000],
 "rpy":[0.109,2.718,-0.000], "lid":108.54,
 "n":[0.0007,-0.9320,0.3626], "bias":[0.153,0.001,0.000], "stat":true}
```

| field | meaning |
|---|---|
| `q` | base→world quaternion (w, x, y, z). Base frame: X right, Y toward hinge, Z up |
| `rpy` | roll/pitch absolute (gravity-referenced), yaw **relative** to last recenter, degrees |
| `lid` | hinge angle, 0.01° resolution |
| `n` | screen-plane normal in world frame (base ⊕ lid — where the display points) |
| `bias` | current gyro bias estimate, °/s |
| `stat` | stationary flag |

Send `recenter\n` on the same socket to zero the heading. `wabe-cli watch` gives a live readout.

## Embedding it

The socket is the language-agnostic path; the whole engine is also a plain C library with no
Swift or Objective-C in the call path. `libwabe` is the sensor I/O, the fusion, and the daemon
— Swift in this repo is only the demo, the CLI, and the offline tools.

```c
#include <wabe.h>

wabe_filter *f = wabe_filter_new(795.0);
wabe_filter_feed(f, accel, n_accel, gyro, n_gyro);  // chip-frame batches, time-ascending
wabe_filter_set_lid(f, 108.54);

wabe_pose p;
wabe_filter_pose(f, t, &p);      // p.q, p.rpy, p.n, p.bias, p.stationary
```

The filter half is pure computation, so it runs equally well on recorded samples — that's all
`wabe-replay` is. `wabe_service_run(&cfg)` is the whole daemon behind one call. Full API in
[`Sources/libwabe/include/wabe.h`](Sources/libwabe/include/wabe.h).

## Accuracy

Roll and pitch are absolute and drift-free — gravity is the reference. Yaw has no absolute
reference (Macs have no magnetometer), so wabe serves it as honest relative heading from the
last `recenter`, and the question that matters is how fast it degrades.

Ground truth here is edge alignment: the machine sits flat with one edge flush against a
straightedge, so every return to that position has a known true heading, and an integer-turn
spin has a known true angle. `probes/session.py` walks the protocol, `wabed --record` captures
raw samples, `wabe-replay` runs them back through the exact filter path the daemon uses.

| condition | yaw error |
|---|---|
| parked (still segments, 21–77 s) | ≤ 0.07° peak-to-peak, drift under 0.1°/min |
| picked up, handled hard 30 s, set back down | 2.2° |
| across a 1080° flat spin (3 turns) | 0.28° |
| across a 720° flat spin (2 turns) | 0.08° |

Gyro z-axis scale error measured ≤0.2% from those spins, with the two directions disagreeing by
more than the alignment precision — so no scale correction is applied; it isn't the limiting
term.

## What's inside

```
Sources/libwabe/       the engine, in C: SPU sensor I/O (795 Hz rings, lid poll), sample
                       merge + VQF fusion, pose extraction, daemon service
Sources/wabed/         daemon: thin C shell (args + the accel-stall re-exec)
Sources/wabe-cli/      watch / recenter (Swift socket client)
Sources/wabe-demo/     SceneKit magic window, three modes (Swift)
Sources/wabe-replay/   offline: replay a raw capture through the live filter path
probes/                C characterization probes + session.py recording protocol
NOTES.md               the findings — read this before touching sensor code
```

Orientation fusion is [VQF](https://github.com/dlaidig/vqf) (Laidig & Seel 2023, vendored, MIT).
An error-state EKF and a Mahony filter were built and benchmarked against it on the edge-aligned
sessions above; VQF beat both by roughly 10× on every dynamic metric, so they were deleted
rather than kept as options. The comparison is recorded in [NOTES.md](NOTES.md).

Filter work is reproducible offline: `wabed --record raw.jsonl` writes chip-frame samples, and
`wabe-replay raw.jsonl` runs them back through the same code the daemon executes, reporting
still segments, settled yaw, and integrated spin angles. Nothing about a filter change needs to
be evaluated by waving a laptop twice.

Highlights from [NOTES.md](NOTES.md), all measured on Mac16,6 / macOS 26.5:

- **The IMU needs no root** — contrary to all prior art. It's asleep by default; three registry
  property writes on `AppleSPUHIDDriver` wake it, and they're permitted from userspace
  (`SensorPropertyReportingState`, `SensorPropertyPowerState`, `ReportInterval`)
- **Native rate is ~795 Hz** — the "100 Hz" in existing libraries is their own decimation
- **The lid angle has a hidden 0.01° report** — input report 7; everyone else reads the 1° one
  (and `IOHIDDeviceGetValue` on it returns 0 — you must use `GetReport`)
- **The accel stream stalls stochastically at open** (~40% of opens, sticky per process, driver
  bug); wabed detects a dry stream in 250 ms and re-execs itself — 15/15 clean launches
- Total power cost of the whole pipeline at full rate: below the measurement noise floor
  (~tens of mW)

## Requirements

- Apple Silicon MacBook (developed and verified on M4 Pro; the SPU devices exist on M1+,
  reports vary by generation)
- macOS 13+, Xcode command line tools

## Prior art

- [samhenrigold/LidAngleSensor](https://github.com/samhenrigold/LidAngleSensor) — original lid
  sensor reverse engineering
- [olvvier/apple-silicon-accelerometer](https://github.com/olvvier/apple-silicon-accelerometer)
  — found the IMU, documented the wire format
- [taigrr/apple-silicon-accelerometer](https://github.com/taigrr/apple-silicon-accelerometer)
  — Go port; the driver wake sequence came from here
- [dlaidig/vqf](https://github.com/dlaidig/vqf) — the orientation filter (vendored C++, MIT)

wabe stands on those shoulders and adds: the no-root finding, the 0.01° lid report, the stall
characterization + workaround, physically-verified axis conventions, the screen-plane
composition, and the pose service itself.

## License

MIT
