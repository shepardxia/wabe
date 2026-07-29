# wabe

**An orientation service for Apple Silicon MacBooks — including where the screen faces.**

<!-- DEMO GIF -->

A phone is one rigid body. A laptop is two on a hinge, and the hinge angle is readable to 0.01°.
Compose base attitude with lid angle and you get the orientation of the *display plane*: not
where the machine points, where the **screen** points. Underneath are the undocumented SPU
sensors (Bosch BMI286, 795 Hz) and the lid encoder — no root, no entitlements, no kext.

## Get started

```bash
swift build -c release
.build/release/wabe install    # launchd agent, starts at login, still no root
wabe status                    # running? what does it see?
wabe watch                     # live readout — tilt the lid, watch `n` swing
swift run wabe-demo            # magic window · m: mode · r: recenter · q: quit
```

Pick it up and turn it: the screen becomes a window onto a room that stays put. `wabe uninstall`
removes everything.

## Consuming it

`wabed` publishes newline JSON at 30 Hz on `/tmp/wabe.sock`; write `recenter\n` back to zero the
heading.

```json
{"q":[0.9997,-0.0237,0.0009,0.0000], "rpy":[0.109,2.718,-0.000], "lid":108.54,
 "n":[0.0007,-0.9320,0.3626], "bias":[0.153,0.001,0.000], "stat":true}
```

`q` is base→world (X right, Y toward hinge, Z up). **`n` is the screen normal in world frame** —
the field the project exists for. The engine is a C library with no Swift in the call path, so
you can skip the socket entirely:

```c
wabe_filter *f = wabe_filter_new(795.0);
wabe_filter_feed(f, accel, n_accel, gyro, n_gyro);   // chip-frame batches
wabe_filter_pose(f, t, &p);                          // p.q, p.rpy, p.n, p.stationary
```

Full API in [`Sources/libwabe/include/wabe.h`](Sources/libwabe/include/wabe.h).

## The filter

Roll and pitch are absolute, because gravity is a reference you always have. Yaw isn't — no Mac
ships a magnetometer — so it's relative to the last `recenter`, and the only question that
matters is how fast it rots while you're actually handling the machine.

That makes the filter the whole game. I wrote an error-state EKF for it, tuned it over an
afternoon, and it lost by about 10× to [VQF](https://github.com/dlaidig/vqf) — so VQF is
vendored (MIT) and my EKF is deleted.

You don't have to take that on faith. Sessions are recorded with edge-aligned endpoints — one
laptop edge flush against a straightedge at the start and again at the finish — so yaw error is
measured against known truth rather than estimated. Replay the same one, or point your own
filter at the samples:

```bash
curl -L -o session.jsonl.gz \
  https://github.com/shepardxia/wabe/releases/download/captures-v1/session.jsonl.gz
swift run wabe-replay session.jsonl.gz
```

Numbers, the full comparison, and the sensor reverse engineering: [NOTES.md](NOTES.md).

## Credit

[samhenrigold](https://github.com/samhenrigold/LidAngleSensor) reverse engineered the lid sensor;
[olvvier](https://github.com/olvvier/apple-silicon-accelerometer) found the IMU and its wire
format; [taigrr](https://github.com/taigrr/apple-silicon-accelerometer)'s Go port is where the
driver wake sequence came from; [dlaidig](https://github.com/dlaidig/vqf) wrote the filter. wabe
adds the screen-plane composition, the service, and the findings in NOTES.md — among them that
the sensors run at 795 Hz rather than the usual 100, that the lid angle has a hidden 0.01°
report, and that none of it needs `sudo`.

Apple Silicon MacBook, macOS 13+. Verified on an M4 Pro. MIT.
