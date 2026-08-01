import Foundation
import libwabe


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
struct LidReading {
    let t: Double
    let deg: Double
}
var accel: [wabe_sample] = []
var gyro: [wabe_sample] = []
var lid: [LidReading] = []
var rate = Double(WABE_DEFAULT_SENSOR_HZ)
for line in data.split(separator: UInt8(ascii: "\n")) {
    guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
          let s = obj["s"] as? String else { continue }
    switch s {
    case "a", "g":
        guard let t = obj["t"] as? Double, let v = obj["v"] as? [Double], v.count == 3 else { continue }
        let sample = wabe_sample(t: t, v: (v[0], v[1], v[2]))
        if s == "a" { accel.append(sample) } else { gyro.append(sample) }
    case "l":
        guard let t = obj["t"] as? Double, let d = obj["d"] as? Double else { continue }
        lid.append(LidReading(t: t, deg: d))
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
print(String(format: "capture: %.1f s, %d accel + %d gyro + %d lid samples @ %.0f Hz nominal",
             gyro.last!.t - t0, accel.count, gyro.count, lid.count, rate))
if lid.isEmpty {
    print("no hinge readings in this capture — screen normal stays zero")
} else if lid.first!.t > gyro.last!.t || lid.last!.t < t0 {
    let msg = "capture stamps its hinge readings on a different clock from its samples "
        + "(lid \(String(format: "%.0f", lid.first!.t)) vs IMU \(String(format: "%.0f", t0)))\n"
        + "  it predates the single-clock recorder; re-record with probes/session.py\n"
    FileHandle.standardError.write(Data(msg.utf8))
    exit(1)
}

// --- replay through libwabe in ~30 Hz slices ---
let w = wabe_replay(rate)!
defer { wabe_stop(w) }

struct Snap {
    let t: Double
    let q: [Double]
    let rpy: SIMD3<Double>
    let n: SIMD3<Double>
    let lidDeg: Double
    let bias: SIMD3<Double>
    let still: Bool
}
var snaps: [Snap] = []
var ai = 0
var gi = 0
var li = 0

/// Advances the estimate to `t` by feeding every sample before it.
func feed(upTo t: Double) {
    var gj = gi
    while gj < gyro.count, gyro[gj].t < t { gj += 1 }
    var aj = ai
    while aj < accel.count, accel[aj].t < t { aj += 1 }
    guard gj > gi || aj > ai else { return }
    accel[ai..<aj].withUnsafeBufferPointer { ab in
        gyro[gi..<gj].withUnsafeBufferPointer { gb in
            wabe_feed(w, ab.baseAddress, ab.count, gb.baseAddress, gb.count)
        }
    }
    ai = aj
    gi = gj
}

var sliceEnd = t0
while gi < gyro.count {
    sliceEnd += 1.0 / 30
    while li < lid.count, lid[li].t < sliceEnd {
        feed(upTo: lid[li].t)
        wabe_set_lid(w, lid[li].deg)
        li += 1
    }
    feed(upTo: sliceEnd)
    if gi > 0 {
        var p = wabe_orientation()
        wabe_read(w, &p)
        snaps.append(Snap(t: gyro[gi - 1].t,
                          q: [p.q.0, p.q.1, p.q.2, p.q.3],
                          rpy: SIMD3(p.rpy.0, p.rpy.1, p.rpy.2),
                          n: SIMD3(p.n.0, p.n.1, p.n.2),
                          lidDeg: p.lid_deg,
                          bias: SIMD3(p.bias.0, p.bias.1, p.bias.2),
                          still: p.at_rest != 0))
    }
}

var stem = URL(fileURLWithPath: capturePath).deletingPathExtension().lastPathComponent
if capturePath.hasSuffix(".gz") { stem = URL(fileURLWithPath: stem).deletingPathExtension().lastPathComponent }
let outPath = "\(outDir)/\(stem).replay.jsonl"
// Same fields in the same order as the daemon publishes, so anything reading one reads the other.
let lineFormat = "{\"t\":%.4f,\"q\":[%.6f,%.6f,%.6f,%.6f],\"rpy\":[%.3f,%.3f,%.3f],\"lid\":%.2f,"
    + "\"n\":[%.4f,%.4f,%.4f],\"bias\":[%.5f,%.5f,%.5f],\"stat\":%@}\n"
var buf = ""
for s in snaps {
    buf += String(format: lineFormat,
                  s.t - t0, s.q[0], s.q[1], s.q[2], s.q[3], s.rpy.x, s.rpy.y, s.rpy.z, s.lidDeg,
                  s.n.x, s.n.y, s.n.z, s.bias.x, s.bias.y, s.bias.z,
                  s.still ? "true" : "false")
}
try? buf.write(toFile: outPath, atomically: true, encoding: .utf8)
print("replayed -> \(outPath)")

// --- still segments from the filter's rest flag ---
struct Segment {
    var start: Double
    var end: Double
    // Settled values: mean over the segment's last second.
    var yaw = 0.0
    var lid = -1.0
    /// Angle of the screen normal above horizontal. The composition of attitude and hinge angle,
    /// which is the one number a capture can regress that neither half yields alone.
    var elevation = 0.0
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
    let n = Double(max(1, tail.count))
    segments[i].yaw = tail.map(\.rpy.z).reduce(0, +) / n
    segments[i].bias = tail.map(\.bias).reduce(SIMD3(), +) / n
    let withLid = tail.filter { $0.lidDeg >= 0 }
    if !withLid.isEmpty {
        let m = Double(withLid.count)
        segments[i].lid = withLid.map(\.lidDeg).reduce(0, +) / m
        segments[i].elevation = withLid.map { asin(max(-1, min(1, $0.n.z))) * 180 / .pi }
            .reduce(0, +) / m
    }
}

print("\nstill segments (>= 2 s, filter rest flag), settled values:")
for (i, seg) in segments.enumerated() {
    var line = String(format: "%2d  %6.1fs–%6.1fs (%5.1fs)  yaw %+9.3f°", i, seg.start - t0,
                      seg.end - t0, seg.end - seg.start, seg.yaw)
    if seg.lid >= 0 {
        line += String(format: "   lid %7.2f°   screen %+7.2f° above horizontal",
                       seg.lid, seg.elevation)
    }
    print(line)
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
