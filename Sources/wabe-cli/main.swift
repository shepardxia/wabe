import Darwin
import Foundation

// wabe watch [--sock path] [--raw]   — stream poses, pretty or raw JSON
// wabe recenter [--sock path]        — zero the relative heading

var sockPath = "/tmp/wabe.sock"
var raw = false
var command = "watch"
var args = ArraySlice(CommandLine.arguments.dropFirst())
while let a = args.popFirst() {
    switch a {
    case "watch", "recenter": command = a
    case "--sock": sockPath = args.popFirst() ?? sockPath
    case "--raw": raw = true
    default:
        FileHandle.standardError.write(Data("usage: wabe [watch|recenter] [--sock path] [--raw]\n".utf8))
        exit(2)
    }
}

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
withUnsafeMutableBytes(of: &addr.sun_path) { rawBuf in
    sockPath.utf8CString.withUnsafeBufferPointer { src in
        rawBuf.copyBytes(from: UnsafeRawBufferPointer(start: src.baseAddress, count: min(src.count, rawBuf.count - 1)))
    }
}
let ok = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard ok == 0 else {
    FileHandle.standardError.write(Data("cannot connect to \(sockPath) — is wabed running?\n".utf8))
    exit(1)
}

if command == "recenter" {
    _ = "recenter\n".withCString { send(fd, $0, 9, 0) }
    print("recentered")
    exit(0)
}

struct Pose: Decodable {
    let t: Double
    let q: [Double]
    let rpy: [Double]
    let lid: Double
    let n: [Double]
    let stat: Bool
}

var buf = Data()
var chunk = [UInt8](repeating: 0, count: 4096)
while true {
    let nr = read(fd, &chunk, chunk.count)
    if nr <= 0 { break }
    buf.append(contentsOf: chunk[0..<nr])
    while let nl = buf.firstIndex(of: 0x0A) {
        let line = buf.prefix(upTo: nl)
        buf.removeSubrange(...nl)
        if raw {
            print(String(decoding: line, as: UTF8.self))
            continue
        }
        guard let p = try? JSONDecoder().decode(Pose.self, from: line) else { continue }
        let bar = p.stat ? "·" : "≈"
        print(String(
            format: "\u{1B}[2K\rroll %+7.2f°  pitch %+7.2f°  yaw %+7.2f°  lid %6.2f°  n [%+.3f %+.3f %+.3f] %@",
            p.rpy[0], p.rpy[1], p.rpy[2], p.lid, p.n[0], p.n[1], p.n[2], bar),
            terminator: "")
        fflush(stdout)
    }
}
print()
