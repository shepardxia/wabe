// Orientation, straight off the daemon's socket. Newline JSON, one object per line.
import Foundation
import simd

final class PoseClient {
    private(set) var q = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)  // base -> world
    private(set) var lidDeg = 105.0
    private(set) var connected = false
    private(set) var hasPose = false
    private var fd: Int32 = -1
    private let path: String
    private let lock = NSLock()

    init(path: String) {
        self.path = path
        Thread.detachNewThread { [weak self] in self?.readLoop() }
    }

    func latest() -> (q: simd_quatd, lid: Double, connected: Bool, hasPose: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (q, lidDeg, connected, hasPose)
    }

    func recenter() {
        if fd >= 0 { _ = "recenter\n".withCString { send(fd, $0, 9, 0) } }
    }

    private var warnedDisconnected = false
    private var warnedUndecodable = false

    private func readLoop() {
        struct Pose: Decodable {
            let q: [Double]
            let lid: Double
        }
        while true {
            let s = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                path.utf8CString.withUnsafeBufferPointer { src in
                    raw.copyBytes(from: UnsafeRawBufferPointer(start: src.baseAddress,
                                                              count: min(src.count, raw.count - 1)))
                }
            }
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if ok != 0 {
                close(s)
                // Say it once, then retry quietly: an inert window with no output looks identical
                // to a broken demo.
                if !warnedDisconnected {
                    warnedDisconnected = true
                    let msg = "tavoletta: waiting for the wabe daemon on \(path)\n"
                        + "  start it with `make install`, or `make && ./build/wabed`\n"
                    FileHandle.standardError.write(Data(msg.utf8))
                }
                Thread.sleep(forTimeInterval: 1)
                continue
            }
            if warnedDisconnected {
                FileHandle.standardError.write(Data("tavoletta: connected\n".utf8))
                warnedDisconnected = false
            }
            warnedUndecodable = false
            fd = s
            // The daemon defaults to 30 Hz, half the render rate, which reads as lag on a fast lid
            // pivot. Ask for 120: the rate is per connection, so this costs no other client.
            _ = "rate 120\n".withCString { send(s, $0, 10, 0) }
            var buf = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(s, &chunk, chunk.count)
                if n <= 0 { break }
                buf.append(contentsOf: chunk[0..<n])
                while let nl = buf.firstIndex(of: 0x0A) {
                    let line = buf.prefix(upTo: nl)
                    buf.removeSubrange(...nl)
                    guard let p = try? JSONDecoder().decode(Pose.self, from: line), p.q.count == 4
                    else {
                        if !warnedUndecodable {
                            warnedUndecodable = true
                            let msg = "tavoletta: cannot decode the daemon's output — schema "
                                + "mismatch\n  \(String(decoding: line, as: UTF8.self))\n"
                            FileHandle.standardError.write(Data(msg.utf8))
                        }
                        continue
                    }
                    lock.lock()
                    q = simd_quatd(ix: p.q[1], iy: p.q[2], iz: p.q[3], r: p.q[0])
                    if p.lid >= 0 { lidDeg = p.lid }
                    connected = true
                    hasPose = true
                    lock.unlock()
                }
            }
            close(s)
            fd = -1
            lock.lock()
            connected = false
            lock.unlock()
            FileHandle.standardError.write(Data("tavoletta: daemon went away, reconnecting\n".utf8))
            warnedDisconnected = true
        }
    }
}
