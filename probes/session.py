#!/usr/bin/env python3
"""Record a wabe session: guided protocol, raw capture, time markers.

Two lengths:

  quick (default, ~45 s)  sanity check. Does the pipeline work, and does orientation come
                          back where it started after you pick the machine up?
  full  (~3 min)          calibration. Adds flat spins through known angles, which is what
                          turns yaw error into a measurement rather than an impression.

Both use edge alignment for ground truth: rest one laptop edge flush against a straightedge
(a book, the desk edge, anything that stays put) so returning to it has a known true heading.

  probes/session.py                # quick
  probes/session.py --full         # calibration
  probes/session.py --name spins   # capture name
  probes/session.py --say          # speak the prompts as well as printing them
"""
import argparse
import json
import os
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTDIR = f"{REPO}/captures"

# (marker, prompt, seconds | None = wait for Enter)
QUICK = [
    ("still", "Hands off. 10 seconds.", 10),
    ("handling", "Pick it up, turn and tilt it. 15 seconds.", 15),
    ("setdown", "Set it back down against the edge. Hands off, 15 seconds.", 15),
]

FULL = [
    ("still", "Hands off. 20 seconds.", 20),
    ("handling", "Pick it up, wave and tilt it hard. 30 seconds.", 30),
    ("setdown", "Set it back down against the edge. Hands off, 40 seconds.", 40),
    ("spin_ccw", "Spin it flat, three full turns counter-clockwise, re-align, press Enter.", None),
    ("spin_ccw_rest", "Hands off. 20 seconds.", 20),
    ("spin_cw", "Three full turns clockwise, re-align, press Enter.", None),
    ("spin_cw_rest", "Hands off. 20 seconds.", 20),
]


def wabed_path():
    for build in ("release", "debug"):
        p = f"{REPO}/.build/{build}/wabed"
        if os.path.exists(p):
            return p
    sys.exit("wabed not built — run `swift build -c release` first")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--full", action="store_true", help="calibration protocol with spins")
    ap.add_argument("--name", default="session", help="capture name (default: session)")
    ap.add_argument("--say", action="store_true", help="speak prompts aloud")
    args = ap.parse_args()

    protocol = FULL if args.full else QUICK
    total = sum(s for _, _, s in protocol if s)
    cap = f"{OUTDIR}/{args.name}.jsonl"
    wabed = wabed_path()

    def say(text):
        print(f"\n>>> {text}", flush=True)
        if args.say:
            subprocess.run(["say", text], check=False)

    def hold(seconds):
        for left in range(seconds, 0, -1):
            print(f"\r    {left:3d} s ", end="", flush=True)
            time.sleep(1)
        print("\r    ok      ")

    print(f"{'calibration' if args.full else 'quick check'}: about {total} s, plus the pauses")
    print("Lay the laptop FLAT with one edge FLUSH against a straightedge.")
    input("Enter to start... ")

    os.makedirs(OUTDIR, exist_ok=True)
    subprocess.run(["pkill", "-f", "wabed"], capture_output=True, check=False)
    time.sleep(1)
    log = open(f"{OUTDIR}/{args.name}-wabed.log", "a")
    subprocess.Popen([wabed, "--record", cap], stdout=log, stderr=log, start_new_session=True)
    time.sleep(3)
    if not os.path.exists(cap) or os.path.getsize(cap) < 10_000:
        sys.exit(f"the daemon recorded nothing — see {OUTDIR}/{args.name}-wabed.log")

    marks = open(f"{OUTDIR}/{args.name}-markers.jsonl", "w", buffering=1)
    try:
        for phase, prompt, seconds in protocol:
            # Both clocks: samples carry CLOCK_MONOTONIC, humans read epoch.
            marks.write(json.dumps({"phase": phase, "epoch": time.time(),
                                    "mono": time.clock_gettime(time.CLOCK_MONOTONIC)}) + "\n")
            say(prompt)
            if seconds is None:
                input("    Enter when re-aligned... ")
            else:
                hold(seconds)
        marks.write(json.dumps({"phase": "end", "epoch": time.time(),
                                "mono": time.clock_gettime(time.CLOCK_MONOTONIC)}) + "\n")
    finally:
        marks.close()
        subprocess.run(["pkill", "-f", "wabed"], capture_output=True, check=False)
        time.sleep(1)
        subprocess.Popen([wabed], stdout=log, stderr=log, start_new_session=True)

    subprocess.run(["gzip", "-kf", cap], check=True)
    print(f"\ncaptured {os.path.getsize(cap) / 1e6:.1f} MB -> {cap}")
    print(f"replay it:  swift run wabe-replay {cap}.gz")


if __name__ == "__main__":
    main()
