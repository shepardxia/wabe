# Sensor findings

What the SPU sensors on an Apple Silicon MacBook actually do, measured on a Mac16,6 (M4 Pro,
14-inch) running macOS 26.5. Where this contradicts the public repos
(olvvier/taigrr `apple-silicon-accelerometer`), it was checked directly on hardware. The one-off
probes that produced these numbers were deleted once the numbers were written down; `probes/`
keeps only what is still run.

## Device map

SPU transport, reached through IOKit HID.

| page   | usage   | device                      | report |
|--------|---------|-----------------------------|--------|
| 0xFF00 | 3       | accelerometer (BMI286)      | 22 B input, x/y/z int32 LE at 6/10/14, ÷65536 → g |
| 0xFF00 | 9       | gyroscope (BMI286)          | same format, ÷65536 → deg/s |
| 0xFF00 | 4       | ALS (presumed, unconfirmed) | 122 B input, streams unprivileged |
| 0xFF00 | 5, 0xFF | unknown                     | 14 B / 1 B, silent |
| 0xFF0C | 1, 5    | unknown                     | 5 B / 100 B, 0xFF0C/1 streams sparse events |
| 0x0020 | 0x8A    | lid angle sensor            | see below |

## Getting at the IMU

**No root, anywhere.** Both public repos say sudo is required. It is not. The IMU is asleep by
default; waking it means setting three registry properties on every `AppleSPUHIDDriver` service:

```
SensorPropertyReportingState = 1
SensorPropertyPowerState     = 1
ReportInterval               = <µs>   (1000 → ~795 Hz actual)
```

`IORegistryEntrySetCFProperty` succeeds as uid 501, and device open, input-report callbacks and
GetReport are all unprivileged. Full sleep → silence → wake → 795 Hz round trip verified as a
normal user (`probes/setinterval.c`). The wake outlives the process that set it: this is registry
state, not a per-client subscription.

**Native rate is ~795 Hz, not 100.** The public repos report ~100 Hz because they decimate by 8
in userspace *after* delivery, which saves neither wakeups nor power. `ReportInterval` is the only
real lever: 1000 µs measured 795 Hz, 10000 µs measured 99.5 Hz.

## Lid angle

Input report 1 carries whole degrees (3 B, `[01, lo, hi]`) and is what every public LAS project
reads. Input report 7 (usage 0x545, unit exponent −2) carries the same angle at **0.01°**:
`[07, lo, hi, 00, 00]`, e.g. 0x2B51 = 110.89°. A third path exists — feature report 1, whole
degrees, which is what pybooklid uses. All three answer on this machine; libwabe probes them
finest-first and takes whichever responds plausibly.

Trap: `IOHIDDeviceGetValue` on report 7's element returns 0. `IOHIDDeviceGetReport` returns live
data. Poll via GetReport.

The encoder is unprivileged, always on, and needs no wake. It is a **separate part from the IMU**
with separate model coverage, so a machine can have orientation and no screen normal.

**Precise, not fast.** 0.01° of resolution buys nothing in time: the value only changes on a
~100 ms grid. Over 919 polls at 172 Hz the median gap between changes was **100.5 ms**, p90
104.4 ms, about 17 identical reads per change — a mean change rate near 9.4 Hz. Polling harder
returns the same number more often and nothing else. That period is `WABE_LID_PERIOD` in
`internal.h`, and it is why `lid_filter.c` reconstructs the angle instead of holding it: published
raw at 120 Hz the composed screen normal steps 8.7° in a single frame on an ordinary pivot.
Encoder noise at rest, over 51 ticks, is 0.031° — the other input to the filter's gains.

## The accelerometer stall

The accelerometer input stream fails to start on roughly 40% of opens: `IOHIDDeviceOpen`
succeeds, callbacks never fire. The gyro was never observed to stall (0/30+ runs); the polled lid
is unaffected.

- decided at open time — a stream that starts never dies mid-run
- sticky per process: close and reopen never revived it (12/12 dead, twice), nor did bouncing
  driver ReportingState, nor seize-open. A fresh IOHIDManager revived a few at attempt 2
- a new process rolls fresh dice, and the next launch usually streams
- reproduces in any process, any thread, wake or not, either open order

Workaround: verify reports flow within 250 ms of open (3 attempts, fresh manager each), and if
the stream stays dry, `execv` self. Capped via `WABE_RESPAWN`. 15/15 launches healthy since.

Under launchd this makes a restart take ~5 s, because the re-exec attempts happen first. Don't
conclude the agent is broken before ~10 s.

Separately: putting the machine face down on the desk stops IMU streaming entirely and something
re-asserts sensor sleep. It recovers on returning level. Not a lid-angle threshold, since the IMU
streams fine at lid 20°. Uncharacterized.

## Measurements

- accelerometer scale: mean |v| = 0.989 g at rest, so ~1.1% scale error (a six-position tumble
  would fix it)
- gyroscope noise at rest: ~0.2 deg/s
- gyroscope bias: order 0.1 deg/s per axis, stable enough that a still window measures it
- raw yaw drift after subtracting bias, static 90 s: 0.05° total. Yaw is the *least* drifty axis
  on this chip (roll −0.22°/min, pitch −0.05°/min)
- power, medians of n=12 and noisy enough that spreads exceed the deltas: asleep → awake-idle
  +7 mW, → 100 Hz subscription +45 mW, → 795 Hz +76 mW. Rate and sleep toggles are not a battery
  feature

## Orientation

**Axis maps**, physically verified: accelerometer base = −chip, gyroscope base = +chip, because
the readout triad is left-handed and a gyro is a pseudo-vector. Base frame is X right, Y toward
the hinge, Z up. Pitch sign confirmed by a live lift test (+15° physical read +15° published).

**Screen normal** (base attitude ⊕ lid angle): n_z crosses zero at lid = 90° + base pitch,
measured 91.4° at pitch +0.35°, and spot checks from 20° to 131° agree to <0.01.

**Filter comparison.** An error-state Kalman filter and a Mahony complementary filter were
written and benchmarked against VQF on recorded sessions with edge-aligned endpoints (one laptop
edge flush against a straightedge at start and finish, so true yaw error is known):

| | ESKF | Mahony | VQF |
|---|---|---|---|
| yaw error after 30 s of hard handling | +30.0° | −8.3° | **−2.2°** |
| yaw shift across a 1080° flat spin | −19.2° | −17.7° | **−0.28°** |

ESKF and Mahony fail the spin for the same reason: centripetal acceleration is constant in the
body frame and tilts apparent gravity a few degrees, and both chase it while yaw winds through
three turns. VQF low-passes acceleration in a near-inertial frame, where centripetal averages
out. VQF is now the only filter; the other two were deleted.

Parked yaw under VQF holds within 0.07° peak to peak, drifting under 0.1°/min.

**Gyro z scale factor**, from the integer-turn spins: −0.195% (3 turns CCW) and −0.043% (2 turns
CW). Both ≤0.2%, and they disagree by more than the alignment precision, so no correction is
applied — scale is not the limiting term.

## Running as a service

- Never set `ProcessType = Background` in the LaunchAgent plist. It throttles CPU and IO enough
  to drop a 30 Hz publish loop to ~17 Hz; the same binary in the foreground held 28–30. Omit the
  key and the default (Standard) behaves.
- The publish deadline must advance on a fixed grid (`last_pub += interval`). Resetting it to the
  current time folds each cycle's overshoot into the next period, which cost ~4 Hz at a nominal
  30. Resync to now only when a full period behind.

## Hardware coverage

Secondhand — only Mac16,6 was tested here.

- **IMU**: M2 and later. olvvier lists the M1 MacBook Pro (2020) and the Mac Studio M4 Max as
  incompatible, so it is laptops only and postdates M1.
- **Lid encoder**: per community survey (samhenrigold/LidAngleSensor#36), the 14- and 16-inch Pro
  across all generations, the 15-inch Air, and the 13-inch Air from M2. The 13-inch Pro has none.
- **Wire format**: the 22-byte layout is documented by olvvier on M3 Pro and measured here on
  M4 Pro, so it holds across at least those. libwabe discovers the offsets at runtime rather than
  trusting this.

## Open items

- gyroscope x/y scale factor (z is ≤0.2%; only matters if tilted-motion yaw disappoints)
- thermal bias drift, which needs a long soak under CPU load
- absolute yaw is unobservable without a magnetometer (none present) or a camera; relative yaw
  plus recenter is the design
- position: double integration diverges in seconds, out of scope without VIO

## Prior art

- `olvvier/apple-silicon-accelerometer` (Python) — found the IMU, documented the wire format
- `taigrr/apple-silicon-accelerometer` (Go) — the `wakeSPUDrivers` property sequence came from here
- `samhenrigold/LidAngleSensor` (Swift) — original lid-angle reverse engineering
- `tcsenpai/pybooklid` (Python) — the feature-report path to the lid angle

None of them compose base attitude with lid angle into a screen-frame orientation. That
composition is why this project exists.
