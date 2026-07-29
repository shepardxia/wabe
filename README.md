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

**No root. No entitlements. No kernel extension.** Just IOKit HID from userspace.

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

Roll and pitch are absolute and drift-free (gravity is the reference). Yaw is unobservable
without a magnetometer (Macs have none), so wabe makes it *honestly relative*: gyro-integrated,
with bias re-estimated in every stationary window. Measured steady-state wander: ~0.01°/min.

## What's inside

```
Sources/CWabeSensor/   C: IOKit HID reader — SPU wake, 795 Hz ring buffers, lid poll
Sources/WabeCore/      Swift: Mahony filter + stationary bias refresh + socket service
Sources/wabed/         daemon
Sources/wabe-cli/      watch / recenter
Sources/wabe-demo/     SceneKit magic window (three modes)
probes/                standalone C probes used to characterize everything
NOTES.md               the findings — read this before touching sensor code
```

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

wabe stands on those shoulders and adds: the no-root finding, the 0.01° lid report, the stall
characterization + workaround, physically-verified axis conventions, the screen-plane
composition, and the pose service itself.

## License

MIT
