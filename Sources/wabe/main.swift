import Darwin
import Foundation

// wabe — control surface for the daemon.
//
//   wabe watch [--raw]     stream poses, pretty or raw JSON
//   wabe recenter          zero the relative heading
//   wabe status            is the service up, and what is it reporting
//   wabe install           install + start the launchd agent (per-user, no root)
//   wabe uninstall         stop + remove it
//
// Global: --sock <path> (default /tmp/wabe.sock)

let LABEL = "dev.wabe.wabed"
let home = FileManager.default.homeDirectoryForCurrentUser
let plistPath = home.appendingPathComponent("Library/LaunchAgents/\(LABEL).plist")
let binDir = home.appendingPathComponent(".local/bin")
let installedDaemon = binDir.appendingPathComponent("wabed")
let installedCLI = binDir.appendingPathComponent("wabe")
let logPath = home.appendingPathComponent("Library/Logs/wabe.log")

var sockPath = "/tmp/wabe.sock"
var raw = false
var command = "status"
var args = ArraySlice(CommandLine.arguments.dropFirst())
while let a = args.popFirst() {
    switch a {
    case "watch", "recenter", "status", "install", "uninstall": command = a
    case "--sock": sockPath = args.popFirst() ?? sockPath
    case "--raw": raw = true
    case "--help", "-h":
        print("""
        wabe — MacBook orientation service

          wabe watch [--raw]   live pose readout
          wabe recenter        zero the relative heading
          wabe status          service state
          wabe install         start at login (launchd, no root)
          wabe uninstall       stop and remove

        options: --sock <path>   (default /tmp/wabe.sock)
        """)
        exit(0)
    default:
        FileHandle.standardError.write(Data("unknown argument: \(a)\n".utf8))
        exit(2)
    }
}

// MARK: - socket

func connectToDaemon() -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { rawBuf in
        sockPath.utf8CString.withUnsafeBufferPointer { src in
            rawBuf.copyBytes(from: UnsafeRawBufferPointer(start: src.baseAddress,
                                                          count: min(src.count, rawBuf.count - 1)))
        }
    }
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if ok != 0 {
        close(fd)
        return nil
    }
    return fd
}

func requireDaemon() -> Int32 {
    guard let fd = connectToDaemon() else {
        FileHandle.standardError.write(Data(
            "no daemon on \(sockPath) — run `wabe install`, or `swift run wabed` for a foreground one\n".utf8))
        exit(1)
    }
    return fd
}

struct Pose: Decodable {
    let t: Double
    let q: [Double]
    let rpy: [Double]
    let lid: Double
    let n: [Double]
    let stat: Bool
}

/// Read newline-delimited poses, handing each to `body` until it returns false.
func streamPoses(_ fd: Int32, _ body: (Pose, String) -> Bool) {
    var buf = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { return }
        buf.append(contentsOf: chunk[0..<n])
        while let nl = buf.firstIndex(of: 0x0A) {
            let line = buf.prefix(upTo: nl)
            buf.removeSubrange(...nl)
            let text = String(decoding: line, as: UTF8.self)
            guard let p = try? JSONDecoder().decode(Pose.self, from: line) else { continue }
            if !body(p, text) { return }
        }
    }
}

// MARK: - launchd

func run(_ path: String, _ arguments: [String]) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = arguments
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    guard (try? p.run()) != nil else { return (-1, "") }
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return (p.terminationStatus, out)
}

var serviceTarget: String { "gui/\(getuid())/\(LABEL)" }

func agentLoaded() -> Bool {
    run("/bin/launchctl", ["print", serviceTarget]).status == 0
}

func doInstall() {
    // The daemon to install sits next to this binary (both come out of the same build).
    let here = URL(fileURLWithPath: CommandLine.arguments[0])
        .resolvingSymlinksInPath().deletingLastPathComponent()
    let built = here.appendingPathComponent("wabed")
    guard FileManager.default.fileExists(atPath: built.path) else {
        FileHandle.standardError.write(Data(
            "cannot find wabed next to \(here.path) — run `swift build -c release` first\n".utf8))
        exit(1)
    }

    try? FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: plistPath.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    // Install the daemon and this control binary together — `wabe status` after `wabe install`
    // should work from anywhere, not only from the build directory.
    for (src, dst) in [(built, installedDaemon),
                       (here.appendingPathComponent("wabe"), installedCLI)] {
        guard FileManager.default.fileExists(atPath: src.path) else { continue }
        try? FileManager.default.removeItem(at: dst)
        do {
            try FileManager.default.copyItem(at: src, to: dst)
        } catch {
            FileHandle.standardError.write(Data("cannot install to \(dst.path): \(error)\n".utf8))
            exit(1)
        }
    }

    // KeepAlive restarts the daemon if the accel stream is dead beyond its own re-exec budget.
    // No ProcessType key: "Background" throttles CPU/IO hard enough to drop the 30 Hz publish
    // rate to ~17 Hz (measured), and the default (Standard) does not.
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key><string>\(LABEL)</string>
        <key>ProgramArguments</key>
        <array>
            <string>\(installedDaemon.path)</string>
            <string>--sock</string><string>\(sockPath)</string>
        </array>
        <key>RunAtLoad</key><true/>
        <key>KeepAlive</key><true/>
        <key>StandardErrorPath</key><string>\(logPath.path)</string>
        <key>StandardOutPath</key><string>\(logPath.path)</string>
    </dict>
    </plist>
    """
    do {
        try plist.write(to: plistPath, atomically: true, encoding: .utf8)
    } catch {
        FileHandle.standardError.write(Data("cannot write \(plistPath.path): \(error)\n".utf8))
        exit(1)
    }

    _ = run("/bin/launchctl", ["bootout", serviceTarget])  // ignore: may not be loaded
    let boot = run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistPath.path])
    guard boot.status == 0 else {
        FileHandle.standardError.write(Data("launchctl bootstrap failed: \(boot.out)\n".utf8))
        exit(1)
    }

    // Wait for the socket rather than claiming success on launchctl's word.
    for _ in 0..<50 {
        if let fd = connectToDaemon() {
            close(fd)
            print("wabe installed and running")
            print("  daemon  \(installedDaemon.path)")
            print("  agent   \(plistPath.path)  (starts at login)")
            print("  socket  \(sockPath)")
            print("  log     \(logPath.path)")
            let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
            if !path.split(separator: ":").contains(where: { $0 == binDir.path }) {
                print("\nadd \(binDir.path) to your PATH to use `wabe` from anywhere:")
                print("  fish_add_path \(binDir.path)      # fish")
                print("  export PATH=\"\(binDir.path):$PATH\"   # bash/zsh")
            }
            exit(0)
        }
        usleep(100_000)
    }
    FileHandle.standardError.write(Data("agent loaded but no socket after 5 s — see \(logPath.path)\n".utf8))
    exit(1)
}

func doUninstall() {
    _ = run("/bin/launchctl", ["bootout", serviceTarget])
    try? FileManager.default.removeItem(at: plistPath)
    try? FileManager.default.removeItem(at: installedDaemon)
    print("wabe uninstalled (removed agent, daemon, and socket registration)")
}

func doStatus() {
    let loaded = agentLoaded()
    print("agent    \(loaded ? "loaded" : "not installed")  (\(LABEL))")
    guard let fd = connectToDaemon() else {
        print("socket   \(sockPath): not responding")
        print("\nstart it with `wabe install`, or `swift run wabed` for a foreground daemon")
        exit(1)
    }
    var count = 0
    var first: Double?
    var last: Pose?
    streamPoses(fd) { pose, _ in
        if first == nil { first = pose.t }
        last = pose
        count += 1
        return count < 30
    }
    close(fd)
    guard let p = last, let t0 = first, count > 1 else {
        print("socket   \(sockPath): connected but no poses")
        exit(1)
    }
    let hz = Double(count - 1) / max(1e-6, p.t - t0)
    print("socket   \(sockPath): \(String(format: "%.0f", hz)) Hz")
    print(String(format: "pose     roll %+.2f°  pitch %+.2f°  yaw %+.2f°  lid %.2f°  %@",
                 p.rpy[0], p.rpy[1], p.rpy[2], p.lid, p.stat ? "at rest" : "moving"))
}

// MARK: - dispatch

switch command {
case "install":
    doInstall()
case "uninstall":
    doUninstall()
case "status":
    doStatus()
case "recenter":
    let fd = requireDaemon()
    _ = "recenter\n".withCString { send(fd, $0, 9, 0) }
    print("recentered")
case "watch":
    let fd = requireDaemon()
    streamPoses(fd) { p, text in
        if raw {
            print(text)
        } else {
            print(String(
                format: "\u{1B}[2K\rroll %+7.2f°  pitch %+7.2f°  yaw %+7.2f°  lid %6.2f°  n [%+.3f %+.3f %+.3f] %@",
                p.rpy[0], p.rpy[1], p.rpy[2], p.lid, p.n[0], p.n[1], p.n[2], p.stat ? "·" : "≈"),
                terminator: "")
            fflush(stdout)
        }
        return true
    }
    print()
default:
    break
}
