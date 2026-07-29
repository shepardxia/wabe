#!/bin/bash
# Power cost of the four states a pose daemon can actually be in. Only powermetrics needs root; every
# sensor operation here is unprivileged. Results are teed to files so they can be read back directly.
#
# Phases: sensors asleep / awake but unsubscribed / awake + 100Hz subscriber / awake + 795Hz subscriber
set -u
cd "$(dirname "$0")"
[ "$(id -u)" = "0" ] || { echo "run: sudo bash $0" >&2; exit 1; }

DUR=24
INTERVAL=2000
N=$((DUR * 1000 / INTERVAL))
USERID="${SUDO_USER:-nobody}"

# Sensor control and streaming as the real user, to keep proving privilege is not needed.
asuser() { sudo -u "$USERID" "$@"; }

capture() { # capture <label>
	powermetrics --samplers cpu_power -i $INTERVAL -n $N > "pm2-$1.txt" 2>&1
	echo "  -> pm2-$1.txt"
}

echo "### phase 1/4: sensors ASLEEP, no subscriber"
asuser ./setinterval 0 0 0 > /dev/null
capture asleep

echo "### phase 2/4: sensors AWAKE (1000us), NO subscriber"
asuser ./setinterval 1000 1 1 > /dev/null
capture awake-idle

echo "### phase 3/4: AWAKE at 10000us + subscriber (~100Hz)"
asuser ./setinterval 10000 1 1 > /dev/null
asuser ./imu100 $((DUR + 4)) --quiet > sub-100.txt 2>&1 &
P=$!
sleep 1
capture sub-100hz
wait $P 2>/dev/null
tail -3 sub-100.txt

echo "### phase 4/4: AWAKE at 1000us + subscriber (~795Hz)"
asuser ./setinterval 1000 1 1 > /dev/null
asuser ./imu100 $((DUR + 4)) --quiet > sub-795.txt 2>&1 &
P=$!
sleep 1
capture sub-795hz
wait $P 2>/dev/null
tail -3 sub-795.txt

echo "### restoring awake default (1000us)"
asuser ./setinterval 1000 1 1 > /dev/null

echo
echo "################ RESULTS ################"
python3 - <<'PY'
import re, statistics

PHASES = [("asleep", "sensors asleep"), ("awake-idle", "awake, no subscriber"),
          ("sub-100hz", "awake + 100Hz sub"), ("sub-795hz", "awake + 795Hz sub")]

def readings(path):
    out = []
    for line in open(path, errors="replace"):
        m = re.search(r"Combined Power \(CPU \+ GPU \+ ANE\):\s*([\d.]+)\s*mW", line)
        if m:
            out.append(float(m.group(1)))
    return out

base = None
print(f"{'phase':24s} {'n':>3s} {'median':>9s} {'mean':>9s} {'min':>7s} {'max':>7s} {'vs asleep':>11s}")
for key, label in PHASES:
    try:
        v = readings(f"pm2-{key}.txt")
    except FileNotFoundError:
        print(f"{label:24s}  (missing)")
        continue
    if not v:
        print(f"{label:24s}  (no readings parsed)")
        continue
    med = statistics.median(v)
    if base is None:
        base = med
    print(f"{label:24s} {len(v):3d} {med:9.1f} {sum(v)/len(v):9.1f} "
          f"{min(v):7.1f} {max(v):7.1f} {med - base:+11.1f}")

print("\nIdle power on this machine swings by hundreds of mW on its own. If the deltas are")
print("smaller than each phase's own min-max spread, the sensor cost is below the noise floor")
print("and rate/sleep toggling is not worth building for power reasons.")
PY
