import CWabeSensor
import Darwin
import Foundation
import simd

/// Owns the C sensor core, runs the filter, publishes newline-JSON poses on a unix socket.
/// Protocol v0: every line the daemon sends is one pose object; every line a client sends is a
/// command (currently just "recenter").
public final class WabeService {
    public struct Config {
        public var sensorHz: Int
        public var publishHz: Double
        public var socketPath: String
        public init(sensorHz: Int = 795, publishHz: Double = 30, socketPath: String = "/tmp/wabe.sock") {
            self.sensorHz = sensorHz
            self.publishHz = publishHz
            self.socketPath = socketPath
        }
    }

    private let cfg: Config
    private let filter = MahonyFilter()
    private var clients: [Int32] = []
    private let lock = NSLock()
    private var serverFD: Int32 = -1
    private var lidDeg: Double = -1

    public init(_ cfg: Config) { self.cfg = cfg }

    public func run() throws {
        let interval = max(1, 1_000_000 / max(1, cfg.sensorHz))
        // WABE_NO_WAKE: stall experiment — skip the driver property writes (sensors must already
        // be awake). Testing whether the ReportInterval rewrite races the accel stream start.
        guard ProcessInfo.processInfo.environment["WABE_NO_WAKE"] != nil || ws_wake(Int32(interval)) > 0 else {
            throw WabeError("SPU wake failed — no AppleSPUHIDDriver services accepted properties")
        }
        guard ws_start() == 0 else {
            throw WabeError("sensor reader failed to start (accel/gyro not openable)")
        }
        // The accel stream is stochastically dead per process instance and nothing in-process
        // revives it (see NOTES.md). Callers re-exec on this error for a fresh roll.
        guard ws_opened_mask() & 1 != 0 else {
            ws_stop()
            throw WabeError.accelDead
        }
        try listen()
        FileHandle.standardError.write(Data("wabed: \(cfg.sensorHz) Hz sensors, \(cfg.publishHz) Hz publish, socket \(cfg.socketPath)\n".utf8))

        // Lid poll at 10 Hz on a background queue; IMU drain + publish on the main loop.
        DispatchQueue.global().async { [weak self] in
            while let self {
                let d = ws_lid_deg()
                if d >= 0 { self.lidDeg = d }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }

        var accelBuf = [ws_sample](repeating: ws_sample(), count: 2048)
        var gyroBuf = [ws_sample](repeating: ws_sample(), count: 2048)
        var lastPub = 0.0
        let pubInterval = 1.0 / cfg.publishHz
        let debug = ProcessInfo.processInfo.environment["WABE_DEBUG"] != nil
        var dbgA = 0
        var dbgG = 0
        var dbgLast = Date().timeIntervalSince1970
        var lastAccel: SIMD3<Double>?

        while true {
            let na = accelBuf.withUnsafeMutableBufferPointer { ws_read_accel($0.baseAddress, $0.count) }
            let ng = gyroBuf.withUnsafeMutableBufferPointer { ws_read_gyro($0.baseAddress, $0.count) }
            if debug {
                dbgA += Int(na)
                dbgG += Int(ng)
                let nowD = Date().timeIntervalSince1970
                if nowD - dbgLast >= 1 {
                    FileHandle.standardError.write(Data("debug: accel \(dbgA)/s gyro \(dbgG)/s, clients=\(clients.count), lid=\(lidDeg)\n".utf8))
                    dbgA = 0
                    dbgG = 0
                    dbgLast = nowD
                }
            }

            // Timestamp-merge the two streams: gyro samples drive filter updates (propagation),
            // accel samples update a zero-order hold used for the gravity correction.
            var ai = 0
            for gi in 0..<Int(ng) {
                let g = gyroBuf[gi]
                while ai < Int(na), accelBuf[ai].t <= g.t {
                    lastAccel = accelChipToBase(SIMD3(Double(accelBuf[ai].x), Double(accelBuf[ai].y), Double(accelBuf[ai].z)))
                    ai += 1
                }
                if let acc = lastAccel {
                    filter.update(accel: acc, gyroDegS: gyroChipToBase(SIMD3(Double(g.x), Double(g.y), Double(g.z))), t: g.t)
                }
            }
            while ai < Int(na) {
                lastAccel = accelChipToBase(SIMD3(Double(accelBuf[ai].x), Double(accelBuf[ai].y), Double(accelBuf[ai].z)))
                ai += 1
            }
            let n = ng

            let now = Date().timeIntervalSince1970
            if n > 0, now - lastPub >= pubInterval {
                lastPub = now
                publish(t: now)
            }
            acceptAndReadClients()
            usleep(2000)
        }
    }

    // MARK: pose serialization

    private func publish(t: Double) {
        let q = filter.q
        let rpy = filter.rollPitchYaw * (180 / .pi)
        let n = ScreenPose.screenNormal(baseQ: q, lidDeg: lidDeg)
        let b = filter.gyroBias
        let line = String(
            format: "{\"t\":%.4f,\"q\":[%.6f,%.6f,%.6f,%.6f],\"rpy\":[%.3f,%.3f,%.3f],\"lid\":%.2f,\"n\":[%.4f,%.4f,%.4f],\"bias\":[%.5f,%.5f,%.5f],\"stat\":%@}\n",
            t, q.real, q.imag.x, q.imag.y, q.imag.z,
            rpy.x, rpy.y, rpy.z, lidDeg, n.x, n.y, n.z,
            b.x, b.y, b.z,
            filter.stationary ? "true" : "false")
        broadcast(line)
    }

    // MARK: unix socket plumbing (nonblocking accept + client reads, blocking-ish writes)

    private func listen() throws {
        unlink(cfg.socketPath)
        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else { throw WabeError("socket() failed") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            cfg.socketPath.utf8CString.withUnsafeBufferPointer { src in
                raw.copyBytes(from: UnsafeRawBufferPointer(start: src.baseAddress, count: min(src.count, raw.count - 1)))
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(serverFD, $0, size) }
        }
        guard bound == 0, Darwin.listen(serverFD, 8) == 0 else {
            throw WabeError("bind/listen failed on \(cfg.socketPath): \(String(cString: strerror(errno)))")
        }
        chmod(cfg.socketPath, 0o666)
        fcntl(serverFD, F_SETFL, O_NONBLOCK)
    }

    private func acceptAndReadClients() {
        while true {
            let fd = accept(serverFD, nil, nil)
            if fd < 0 { break }
            fcntl(fd, F_SETFL, O_NONBLOCK)
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            lock.lock()
            clients.append(fd)
            lock.unlock()
        }
        // Poll clients for commands.
        var cmdBuf = [UInt8](repeating: 0, count: 256)
        lock.lock()
        for fd in clients {
            let n = read(fd, &cmdBuf, cmdBuf.count)
            guard n > 0, let s = String(bytes: cmdBuf[0..<n], encoding: .utf8) else { continue }
            if s.contains("recenter") { filter.recenter() }
        }
        lock.unlock()
    }

    private func broadcast(_ line: String) {
        let bytes = Array(line.utf8)
        lock.lock()
        clients.removeAll { fd in
            let sent = bytes.withUnsafeBufferPointer { send(fd, $0.baseAddress, $0.count, 0) }
            if sent < 0 && errno != EAGAIN {
                close(fd)
                return true
            }
            return false
        }
        lock.unlock()
    }
}

public struct WabeError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ s: String) { description = s }
    public static let accelDead = WabeError("accel stream dead in this process instance")
}
