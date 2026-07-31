# wabe

**An orientation service for MacBooks to gyre and gimble in the wabe.**

<!-- DEMO GIF -->

Attitude comes from the SPU IMU (Bosch BMI286, 795 Hz) through [VQF](https://github.com/dlaidig/vqf);
the hinge reads to 0.01°. Compose them and you have the display plane, which is not the base the
laptop is sitting on, and is the one thing nothing else on the machine reports. Userspace HID.

macOS 13+ on an Apple Silicon MacBook. Runs as your own user; `sudo` is never needed.

## Install

```bash
make            # library and daemon: C, no Swift toolchain needed
make install    # launchd agent, starts at login, runs as you
```

`./build/wabed` runs it in the foreground if you would rather not install anything. `make install`
puts `wabe` and `wabed` in `~/.local/bin` and adds the control CLI: `wabe status`, `wabe watch`,
`wabe recenter`, `wabe uninstall`.

## Demo

```bash
make demo       # m: mode · l: lines · r: recenter · [ ]: eye · q: quit  (--help for the rest)
```

Brunelleschi's 1425 panel, run off the hinge: Piazza del Duomo is pinned to the room and the
screen is the picture plane. The horizon and vanishing point drawn on it are read back off the
projection, so they measure the screen normal rather than illustrate it.

## Usage

`wabed` publishes newline JSON on `/tmp/wabe.sock`. Write `recenter\n` to zero your heading, or
`rate 60\n` to set your update rate (30 Hz default, 200 Hz cap). Each connection keeps its own.

```json
{"t":1785423645.5060, "q":[0.9997,-0.0237,0.0009,0.0000], "rpy":[0.109,2.718,-0.000],
 "lid":108.54, "n":[0.0007,-0.9320,0.3626], "bias":[0.153,0.001,0.000], "stat":true}
```

- `t` seconds since the epoch
- `q` base to world rotation, `[w,x,y,z]`, in a frame with X right, Y toward the hinge, Z up
- `rpy` degrees; roll and pitch absolute against gravity, yaw relative to your last `recenter`
- `lid` hinge angle in degrees, or -1 on a machine with no hinge encoder
- **`n` screen normal in world frame**, zero whenever `lid` is -1
- `bias` gyroscope bias estimate, deg/s per axis
- `stat` true while the filter reads the machine as stationary

Or link the C library and skip the socket:

```c
wabe *w = wabe_start(NULL, NULL);   // opens the sensors, tracks in the background
wabe_orientation o;
wabe_read(w, &o);                   // pull: newest value, any thread
                                    // o.q, o.rpy, o.n, o.lid_deg, o.at_rest
wabe_recenter(w);                             // zero the heading
wabe_stop(w);
```

`wabe_serve()` is that plus the socket.
`wabe_replay()` replays recordings via `wabe_feed()`. See [`wabe.h`](Sources/libwabe/include/wabe.h).

## Replay

`wabed --record` writes raw samples and `wabe-replay` runs them back through the live code path.
`probes/session.py` records your own: 45 seconds by default, `--full` for the calibration
protocol. Both rest a laptop edge on a straightedge at each end, so drift is measured, not guessed:

```bash
curl -L -o session.jsonl.gz \
  https://github.com/shepardxia/wabe/releases/download/captures-v1/session.jsonl.gz
swift run wabe-replay session.jsonl.gz
```

## Hardware

Verified on one machine, a 14-inch M4 Pro; coverage below is secondhand, from other projects'
reports. Report offsets and the lid access path are discovered at startup, never hardcoded.

- IMU: MacBooks, M2 and later.
- Hinge encoder: 14- and 16-inch Pro, 15-inch Air, 13-inch Air from M2. The 13-inch Pro has none.
  Orientation still works without it: `lid` reads -1 and `n` stays zero, which is how you tell.

Yaw is relative to your last `recenter` rather than a compass heading, these Macs carrying no
magnetometer. At full rate the pipeline draws about 76 mW, near 1% of a charge across a working
day. Measurements and the sensor reverse engineering: [NOTES.md](NOTES.md).

## Credits

- [samhenrigold](https://github.com/samhenrigold/LidAngleSensor) reverse engineered the lid sensor
- [olvvier](https://github.com/olvvier/apple-silicon-accelerometer) found the IMU and its wire format
- [taigrr](https://github.com/taigrr/apple-silicon-accelerometer)'s Go port carried the wake sequence
- [tcsenpai](https://github.com/tcsenpai/pybooklid) documented the feature-report path to the lid
- [dlaidig](https://github.com/dlaidig/vqf) wrote VQF
