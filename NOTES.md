# Sensor findings — Mac16,6 (M4 Pro MBP), macOS 26.5, 2026-07-28

Everything below was measured on this machine with the probes in `probes/`. Where it contradicts
the public repos (olvvier/taigrr `apple-silicon-accelerometer`), the public repos are wrong or
outdated — this was verified directly.

## Device map (SPU transport, IOKit HID)

| page   | usage | device                | report                              |
|--------|-------|-----------------------|-------------------------------------|
| 0xFF00 | 3     | accelerometer (BMI286)| 22 B input, x/y/z int32 LE @ 6/10/14, ÷65536 → g |
| 0xFF00 | 9     | gyroscope (BMI286)    | same format, ÷65536 → deg/s         |
| 0xFF00 | 4     | ALS (presumed, unconfirmed) | 122 B input, streams unprivileged |
| 0xFF00 | 5, 0xFF | unknown             | 14 B / 1 B, silent                  |
| 0xFF0C | 1, 5  | unknown               | 5 B / 100 B, 0xFF0C/1 streams sparse events |
| 0x0020 | 0x8A  | lid angle sensor      | see below                           |

## Key discoveries

### 1. No root needed — anywhere (contradicts both public repos)

The IMU is asleep by default. Waking it = setting three registry properties on every
`AppleSPUHIDDriver` service:

```
SensorPropertyReportingState = 1
SensorPropertyPowerState     = 1
ReportInterval               = <µs>   (1000 → ~795 Hz actual)
```

`IORegistryEntrySetCFProperty` for these succeeds as uid 501. Device open, input-report
callbacks, GetReport: all unprivileged. Both public repos claim sudo is required; it is not
(at least on this OS/hardware). Full sleep→silence→wake→795 Hz round trip verified as
normal user (`probes/setinterval.c`).

The wake persists after the setting process exits (registry state, not per-client).

### 2. Real rate is ~795 Hz, not 100 Hz

Public repos report ~100 Hz because they decimate by 8 in userspace *after* delivery
(saves no wakeups, no power). `ReportInterval` is the only real rate lever:
1000 µs → 795 Hz measured; 10000 µs → 99.5 Hz measured.

### 3. Lid angle at 0.01° resolution, unprivileged

LAS (0x20/0x8A) exposes input report 1 = whole degrees (3 B: `[01, lo, hi]`) — this is what
all public LAS projects read. Input report 7 (usage 0x545, unit exponent −2) carries the same
angle at 0.01°: `[07, lo, hi, 00, 00]`, e.g. 0x2B51 = 110.89°.

Gotcha: `IOHIDDeviceGetValue` on report-7's element returns 0. `IOHIDDeviceGetReport`
(input type, id 7) returns live data. Poll via GetReport.

LAS works fully unprivileged, always-on, no wake needed.

### 4. Screensaver sandbox blocks all of it

`.saver` bundles run inside `legacyScreenSaver.appex` (`com.apple.security.app-sandbox`, no
`device.*` entitlements). Under that sandbox `IOHIDDeviceOpen` → `0xe00002e2` on every SPU
device (enumeration still works). Verified with an ad-hoc-signed sandboxed binary mirroring
the appex entitlements.

Fallback proven: the sandbox *can* read arbitrary paths
(`temporary-exception.files.absolute-path.read-only = /`), so an outside process writing
`/tmp/...` is readable from a saver. Network client/server entitlements also present.

Note: programmatic screensaver triggering is dead on this OS (`ScreenSaverEngine -module`
and legacy `moduleDict` both ignored; selection lives in the wallpaper Index.plist store).

### 5. Accel stream stall (driver bug, workaround required)

The accelerometer (0xFF00/3) input stream fails to start on roughly 40% of device opens:
`IOHIDDeviceOpen` succeeds, callbacks never fire. Gyro was never observed to stall (0/30+ runs);
lid (polled GetReport) unaffected. Measured properties:

- decided at open time — streams that start never die mid-run
- sticky per process instance: close+reopen never revived (12/12 dead, twice); driver
  ReportingState bounce and seize-open don't help either; a fresh IOHIDManager + reopen
  revived a few instances at attempt 2, most stay dead
- a NEW process rolls fresh dice — the very next launch typically streams fine
- reproduces in any process (probes included), any thread, wake or no wake, either open order

Workaround in `wabed`: verify reports flow within 250 ms of open (3 attempts, fresh manager
each); if accel stays dry, `execv` self (capped, `WABE_RESPAWN` env counts). 15/15 launches
healthy with this in place.

Separate observation: putting the machine screen-face-down on the desk (lid ~90°) stopped IMU
streaming entirely and something re-asserted sensor sleep; recovered on returning level. Not yet
characterized — possibly the same lid/display heuristic that gates SPU reporting.

## Measurements (this unit)

- accel scale: mean |v| = 0.989 g at rest → ~1.1% scale error (six-position tumble would fix)
- gyro noise at rest: ~0.2 deg/s RMS-ish magnitude
- gyro bias (5 s / 3976-sample average): x +0.125, y −0.103, z +0.011 deg/s
- yaw drift after bias subtraction, static 90 s: 0.05° total (−0.03°/min). Yaw is the
  *least* drifty axis here (roll −0.22°/min, pitch −0.05°/min)
- power (medians, n=12, noisy — spreads ≫ deltas, treat as upper-bound ordering):
  asleep → awake-idle +7 mW, → 100 Hz sub +45 mW, → 795 Hz sub +76 mW. All negligible;
  rate/sleep toggles are not a battery feature.

## Verified end-to-end (2026-07-28 session)

- axis maps: accel base = −chip, gyro base = +chip (left-handed readout); pitch label sign
  confirmed by live lift test (+15° physical = +15° published)
- screen-normal composition: n_z zero-crossing at lid = 90° + base pitch (measured 91.4° at
  pitch +0.35°, n_z = sin 1.7°); spot-checks across 20°–131° agree to <0.01
- stationary bias refresh: converges to independently-measured chip bias in ~16 s; steady-state
  yaw wander ~0.01°/min
- magic-window demo: correct counter-rotation feel at 30 Hz publish, no prediction needed yet
- IMU keeps streaming at lid 20° — the screen-face-down stall is not a lid-angle threshold

## Open items

- gyro scale-factor error: needs a known-reference rotation (turn 90° against a stop)
- thermal bias drift: needs a long soak under CPU load
- confirm 0xFF00/4 is actually the ALS (diff its 122 B payload against lighting changes)
- identify 0xFF0C devices
- absolute yaw: unobservable without magnetometer (none present) or camera. Relative yaw
  + stationary bias refresh + recenter is the design
- position: double-integration diverges in seconds; out of scope without VIO

## Prior art

- `olvvier/apple-silicon-accelerometer` (Python, 2026-02, 1.2k★) — sensor demo dashboard;
  wire format + Mahony source
- `taigrr/apple-silicon-accelerometer` (Go, 2026-02, active) — daemon/shm architecture;
  the `wakeSPUDrivers` property-write sequence came from here
- `samhenrigold/LidAngleSensor` (Swift, 2025-09) — original LAS reverse engineering
- None compose base attitude ⊕ lid angle into a screen-frame pose. That composition is
  this project's reason to exist.
