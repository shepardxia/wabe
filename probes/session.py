#!/usr/bin/env python3
"""Guided calibration/comparison recording session for wabe.

Restarts wabed with raw capture on, walks you through the protocol with voice + printed
prompts, and writes time markers (epoch + CLOCK_MONOTONIC, the clock sensor samples use)
so analysis can align phases exactly.

Usage: python3 probes/session.py [outdir]
Env:   FAST=1 (3 s phases, for dry runs)  SAY=0 (mute voice)
"""
import json
import os
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WABED = f"{REPO}/.build/debug/wabed"
OUTDIR = sys.argv[1] if len(sys.argv) > 1 else REPO
CAP = f"{OUTDIR}/session.jsonl"
MARKS = f"{OUTDIR}/session-markers.jsonl"
FAST = os.environ.get("FAST") == "1"
VOICE = os.environ.get("SAY") != "0"

def t(sec):
    return 3 if FAST else sec

marks = open(MARKS, "w", buffering=1)

def mark(name):
    marks.write(json.dumps({"phase": name, "epoch": time.time(),
                            "mono": time.clock_gettime(time.CLOCK_MONOTONIC)}) + "\n")

def say(text):
    print(f"\n>>> {text}", flush=True)
    if VOICE:
        subprocess.run(["say", text])

def hold(sec):
    for remaining in range(sec, 0, -1):
        print(f"\r    {remaining:3d} s ", end="", flush=True)
        time.sleep(1)
    print("\r    done   ")

print("wabe recording session")
print(f"capture: {CAP}\nmarkers: {MARKS}")
input("\nLaptop FLAT on desk, edge FLUSH against your straightedge. Press Enter to start... ")

subprocess.run(["pkill", "-f", "debug/wabed"], capture_output=True)
time.sleep(1)
log = open(f"{OUTDIR}/session-wabed.log", "a")
subprocess.Popen([WABED, "--record", CAP], stdout=log, stderr=log,
                 start_new_session=True)
time.sleep(3)
if not os.path.exists(CAP) or os.path.getsize(CAP) < 10000:
    print("recorder not producing data — aborting (check session-wabed.log)")
    sys.exit(1)
mark("recording_start")

say(f"Phase 1. Hands off. {t(30)} seconds still.")
mark("still_aligned_start")
hold(t(30))

mark("wave_start")
say(f"Phase 2. Pick it up. Wave and tilt hard for {t(30)} seconds.")
if FAST:
    hold(t(30))
else:
    hold(25)
    say("Five seconds. Get ready to set it down.")
    hold(5)
say("Set it down flush against the edge. Then hands off for one minute.")
mark("setdown_called")
hold(t(60))
mark("post_wave_still_end")

say("Phase 3. Spin it flat on the desk: three full turns counter-clockwise. "
    "Re-align flush, then gently press Enter.")
input("    3x CCW, re-align, Enter... ")
mark("ccw_aligned")
say(f"Hands off. {t(20)} seconds.")
hold(t(20))

say("Phase 4. Three full turns clockwise. Re-align flush, then gently press Enter.")
input("    3x CW, re-align, Enter... ")
mark("cw_aligned")
say(f"Hands off. {t(20)} seconds.")
hold(t(20))

mark("session_end")
say("Done. Recording stopped.")
subprocess.run(["pkill", "-f", "debug/wabed"], capture_output=True)
time.sleep(1)
# restore the live daemon
subprocess.Popen([WABED], stdout=log, stderr=log, start_new_session=True)
size = os.path.getsize(CAP) / 1e6
print(f"\ncapture complete: {CAP} ({size:.1f} MB) — tell claude it's done")
