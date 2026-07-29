import Foundation
import libwabe

// wabe-replay <capture.jsonl> [--out dir]
//
// Replays a raw chip-frame capture (wabed --record) through the libwabe filter — the exact
// code path the live daemon runs — and reports:
// - a trajectory file (<out>/<capture-stem>.replay.jsonl @ ~30 Hz)
// - still segments (filter rest detection) with settled yaw
// - per-motion-segment integrated raw gyro rotation (bias-subtracted) — the scale-calibration
//   number: an edge-aligned integer-turn spin should integrate to a multiple of ±360° about z.

var capturePath: String?
var outDir = "."
var args = ArraySlice(CommandLine.arguments.dropFirst())
while let a = args.popFirst() {
    switch a {
    case "--out": outDir = args.popFirst() ?? outDir
    case "--help", "-h":
        print("wabe-replay <capture.jsonl[.gz]> [--out dir]")
        exit(0)
    default: capturePath = a
    }
}
/// Captures are published gzipped; read either form.
func readCapture(_ path: String) -> Data? {
    guard path.hasSuffix(".gz") else { return FileManager.default.contents(atPath: path) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
    p.arguments = ["-c", path]
    let pipe = Pipe()
    p.standardOutput = pipe
    guard (try? p.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return p.terminationStatus == 0 ? data : nil
}

guard let capturePath, let data = readCapture(capturePath) else {
    FileHandle.standardError.write(Data("usage: wabe-replay <capture.jsonl[.gz]> — file must exist\n".utf8))
    exit(2)
}

// --- parse capture ---
var accel: [wabe_sample] = []
var gyro: [wabe_sample] = []
var rate = 795.0
for line in data.split(separator: UInt8(ascii: "\n")) {
    guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
          let s = obj["s"] as? String else { continue }
    switch s {
    case "a", "g":
        guard let t = obj["t"] as? Double, let v = obj["v"] as? [Double], v.count == 3 else { continue }
        let sample = wabe_sample(t: t, v: (v[0], v[1], v[2]))
        if s == "a" { accel.append(sample) } else { gyro.append(sample) }
    case "meta":
        if let r = obj["rate"] as? Double { rate = r }
        if let r = obj["rate"] as? Int { rate = Double(r) }
    default: break
    }
}
guard gyro.count > Int(rate), !accel.isEmpty else {
    FileHandle.standardError.write(Data("capture too short: \(accel.count) accel, \(gyro.count) gyro samples\n".utf8))
    exit(1)
}
let t0 = gyro[0].t
print(String(format: "capture: %.1f s, %d accel + %d gyro samples @ %.0f Hz nominal",
             gyro.last!.t - t0, accel.count, gyro.count, rate))

// --- replay through libwabe in ~30 Hz slices ---
let filter = wabe_filter_new(rate)!
defer { wabe_filter_free(filter) }

struct Snap {
    let t: Double
    let rpy: SIMD3<Double>
    let bias: SIMD3<Double>
    let still: Bool
}
var snaps: [Snap] = []
var ai = 0
var gi = 0
var sliceEnd = t0
while gi < gyro.count {
    sliceEnd += 1.0 / 30
    var gj = gi
    while gj < gyro.count, gyro[gj].t < sliceEnd { gj += 1 }
    var aj = ai
    while aj < accel.count, accel[aj].t < sliceEnd { aj += 1 }
    accel[ai..<aj].withUnsafeBufferPointer { ab in
        gyro[gi..<gj].withUnsafeBufferPointer { gb in
            wabe_filter_feed(filter, ab.baseAddress, ab.count, gb.baseAddress, gb.count)
        }
    }
    ai = aj
    gi = gj
    if gi > 0 {
        var p = wabe_pose()
        wabe_filter_pose(filter, gyro[gi - 1].t, &p)
        snaps.append(Snap(t: gyro[gi - 1].t,
                          rpy: SIMD3(p.rpy.0, p.rpy.1, p.rpy.2),
                          bias: SIMD3(p.bias.0, p.bias.1, p.bias.2),
                          still: p.stationary != 0))
    }
}

var stem = URL(fileURLWithPath: capturePath).deletingPathExtension().lastPathComponent
if capturePath.hasSuffix(".gz") { stem = URL(fileURLWithPath: stem).deletingPathExtension().lastPathComponent }
let outPath = "\(outDir)/\(stem).replay.jsonl"
var buf = ""
for s in snaps {
    buf += String(format: "{\"t\":%.4f,\"rpy\":[%.3f,%.3f,%.3f],\"bias\":[%.5f,%.5f,%.5f],\"stat\":%@}\n",
                  s.t - t0, s.rpy.x, s.rpy.y, s.rpy.z, s.bias.x, s.bias.y, s.bias.z,
                  s.still ? "true" : "false")
}
try? buf.write(toFile: outPath, atomically: true, encoding: .utf8)
print("replayed -> \(outPath)")

// --- still segments from the filter's rest flag ---
struct Segment {
    var start: Double
    var end: Double
    var yaw = 0.0   // settled: mean over last second
    var bias = SIMD3<Double>()
}
var segments: [Segment] = []
var current: Segment?
for s in snaps {
    if s.still {
        if current == nil { current = Segment(start: s.t, end: s.t) }
        current!.end = s.t
    } else if let seg = current {
        if seg.end - seg.start >= 2 { segments.append(seg) }
        current = nil
    }
}
if let seg = current, seg.end - seg.start >= 2 { segments.append(seg) }
for i in segments.indices {
    let tail = snaps.filter { $0.t >= segments[i].end - 1 && $0.t <= segments[i].end }
    segments[i].yaw = tail.map(\.rpy.z).reduce(0, +) / Double(max(1, tail.count))
    segments[i].bias = tail.map(\.bias).reduce(SIMD3(), +) / Double(max(1, tail.count))
}

print("\nstill segments (>= 2 s, filter rest flag), settled yaw:")
for (i, seg) in segments.enumerated() {
    print(String(format: "%2d  %6.1fs–%6.1fs (%5.1fs)  yaw %+9.3f°", i, seg.start - t0, seg.end - t0,
                 seg.end - seg.start, seg.yaw))
}

// --- integrated raw gyro between still segments (bias-subtracted, base frame = +chip) ---
if segments.count > 1 {
    print("\nintegrated raw gyro over motion segments (bias-subtracted):")
    for i in 0..<(segments.count - 1) {
        let a = segments[i]
        let b = segments[i + 1]
        let bias = (a.bias + b.bias) * 0.5
        var integral = SIMD3<Double>()
        var lastT: Double?
        for g in gyro where g.t > a.end && g.t < b.start {
            if let lt = lastT {
                let dt = g.t - lt
                if dt > 0, dt < 0.5 { integral += (SIMD3(g.v.0, g.v.1, g.v.2) - bias) * dt }
            }
            lastT = g.t
        }
        print(String(
            format: "motion %6.1fs–%6.1fs (%5.1f s): ∫gyro = [%+9.2f %+9.2f %+9.2f]°  |z|/360 = %.4f turns",
            a.end - t0, b.start - t0, b.start - a.end, integral.x, integral.y, integral.z,
            abs(integral.z) / 360))
    }
}
