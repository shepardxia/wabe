#!/usr/bin/env python3
"""Compare two imucapture runs and report which byte offsets encode orientation.

A byte is interesting when its range in one run does not overlap its range in the other: that means
the physical change moved it beyond its own idle jitter. Also tries int16 LE/BE readings at each
interesting offset, since accelerometer axes are usually signed 16-bit.
"""
import sys
from collections import defaultdict


def load(path):
    """-> {(page, usage, reportID): [list of byte-lists]}"""
    runs = defaultdict(list)
    with open(path) as f:
        for line in f:
            parts = line.split()
            if len(parts) < 4:
                continue
            key = (parts[0], parts[1], parts[2])
            runs[key].append([int(b, 16) for b in parts[3:]])
        return runs


def ranges(samples):
    """Per-offset (min, max) across samples."""
    if not samples:
        return []
    width = min(len(s) for s in samples)
    return [(min(s[i] for s in samples), max(s[i] for s in samples)) for i in range(width)]


def s16(lo, hi):
    v = lo | (hi << 8)
    return v - 65536 if v >= 32768 else v


def main():
    a_path, b_path, a_label, b_label = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
    a, b = load(a_path), load(b_path)

    for key in sorted(set(a) | set(b)):
        page, usage, rid = key
        sa, sb = a.get(key, []), b.get(key, [])
        print(f"\n=== page={page} usage={usage} reportID={rid} "
              f"| {a_label}: {len(sa)} reports, {b_label}: {len(sb)} reports ===")
        if not sa or not sb:
            print(f"  only present in one run -> device reports only when {a_label if sa else b_label}")
            continue

        ra, rb = ranges(sa), ranges(sb)
        moved = []
        for i in range(min(len(ra), len(rb))):
            (amin, amax), (bmin, bmax) = ra[i], rb[i]
            if amax < bmin or bmax < amin:  # disjoint ranges
                moved.append((i, ra[i], rb[i]))

        if not moved:
            print("  no byte moved beyond its idle jitter")
            continue

        print(f"  {len(moved)} byte(s) moved beyond idle jitter:")
        for i, (amin, amax), (bmin, bmax) in moved:
            print(f"    byte[{i:3d}]  {a_label}: {amin:3d}-{amax:3d}   {b_label}: {bmin:3d}-{bmax:3d}")

        # Signed 16-bit readings at each moved offset, both endiannesses.
        print("  int16 interpretations (mean over samples):")
        for i, _, _ in moved:
            for off in (i - 1, i):
                if off < 0 or off + 1 >= min(len(ra), len(rb)):
                    continue
                for name, f in (("LE", lambda s: s16(s[off], s[off + 1])),
                                ("BE", lambda s: s16(s[off + 1], s[off]))):
                    ma = sum(f(s) for s in sa) / len(sa)
                    mb = sum(f(s) for s in sb) / len(sb)
                    if abs(ma - mb) > 100:
                        print(f"    @{off:3d} {name}: {a_label}={ma:9.1f}  {b_label}={mb:9.1f}  "
                              f"delta={mb - ma:+.1f}")


if __name__ == "__main__":
    main()
