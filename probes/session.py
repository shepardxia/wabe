#!/usr/bin/env python3
"""Record a wabe calibration session: guided protocol, raw capture, time markers.

Produces a capture that can be replayed offline (`wabe-replay`) to evaluate any orientation
filter against known ground truth. Ground truth comes from edge alignment — the laptop sits
flat with one edge flush against a straightedge, so returning to that position has a known
true heading, and an integer-turn spin has a known true angle.

Usage: probes/session.py [name]
Env:   FAST=1  three-second phases, for dry runs
       SAY=0   no voice prompts
"""
import json
import os
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WABED = f"{REPO}/.build/release/wabed"
if not os.path.exists(WABED):
    WABED = f"{REPO}/.build/debug/wabed"
FAST = os.environ.get("FAST") == "1"
VOICE = os.environ.get("SAY") != "0"

NAME = sys.argv[1] if len(sys.argv) > 1 else "session"
OUTDIR = f"{REPO}/captures"
CAP = f"{OUTDIR}/{NAME}.jsonl"
MARKS = f"{OUTDIR}/{NAME}-markers.jsonl"

# (marker, spoken instruction, seconds to hold | None = wait for Enter)
PROTOCOL = [
    ("still_aligned", "Hands off. Thirty seconds still.", 30),
    ("wave", "Pick it up. Wave and tilt it hard.", 30),
    ("setdown", "Set it down flush against the edge. Hands off for one minute.", 60),
    ("spin_ccw", "Spin it flat on the desk: three full turns counter-clockwise, "
                 "then re-align flush and press Enter.", None),
    ("spin_ccw_rest", "Hands off. Twenty seconds.", 20),
    ("spin_cw", "Three full turns clockwise, re-align flush, press Enter.", None),
    ("spin_cw_rest", "Hands off. Twenty seconds.", 20),
]


def say(text):
    print(f"\n>>> {text}", flush=True)
    if VOICE:
        subprocess.run(["say", text], check=False)


def hold(seconds):
    for remaining in range(seconds, 0, -1):
        print(f"\r    {remaining:3d} s ", end="", flush=True)
        time.sleep(1)
    print("\r    done   ")


def start_daemon(args, log):
    return subprocess.Popen([WABED] + args, stdout=log, stderr=log, start_new_session=True)


def main():
    if not os.path.exists(WABED):
        sys.exit("wabed not built — run `swift build -c release` first")
    os.makedirs(OUTDIR, exist_ok=True)

    print(f"wabe recording session: {NAME}")
    print(f"  capture {CAP}\n  markers {MARKS}")
    input("\nLaptop FLAT on the desk, one edge FLUSH against a straightedge. Enter to start... ")

    subprocess.run(["pkill", "-f", "wabed"], capture_output=True, check=False)
    time.sleep(1)
    log = open(f"{OUTDIR}/{NAME}-wabed.log", "a")
    start_daemon(["--record", CAP], log)
    time.sleep(3)
    if not os.path.exists(CAP) or os.path.getsize(CAP) < 10_000:
        sys.exit(f"recorder produced no data — check {OUTDIR}/{NAME}-wabed.log")

    marks = open(MARKS, "w", buffering=1)

    def mark(phase):
        # Both clocks: samples are stamped CLOCK_MONOTONIC, humans read epoch.
        marks.write(json.dumps({"phase": phase, "epoch": time.time(),
                                "mono": time.clock_gettime(time.CLOCK_MONOTONIC)}) + "\n")

    try:
        mark("recording_start")
        for phase, instruction, seconds in PROTOCOL:
            mark(phase)
            say(instruction)
            if seconds is None:
                input("    Enter when re-aligned... ")
            elif FAST:
                hold(3)
            elif seconds > 10:
                hold(seconds - 5)
                say("Five seconds.")
                hold(5)
            else:
                hold(seconds)
        mark("session_end")
        say("Done.")
    finally:
        marks.close()
        subprocess.run(["pkill", "-f", "wabed"], capture_output=True, check=False)
        time.sleep(1)
        start_daemon([], log)  # restore the ordinary daemon

    raw = os.path.getsize(CAP)
    subprocess.run(["gzip", "-kf", CAP], check=True)
    gz = os.path.getsize(CAP + ".gz")
    print(f"\ncapture: {CAP} ({raw/1e6:.1f} MB, {gz/1e6:.1f} MB gzipped)")
    print(f"replay:  swift run wabe-replay {CAP}.gz")


if __name__ == "__main__":
    main()
