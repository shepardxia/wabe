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
// The demo is not here: it is a separate package, run from a checkout with `make demo`.
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
var daemonPath: String?
var args = ArraySlice(CommandLine.arguments.dropFirst())
while let a = args.popFirst() {
    switch a {
    case "watch", "recenter", "status", "install", "uninstall": command = a
    case "--sock": sockPath = args.popFirst() ?? sockPath
    case "--daemon": daemonPath = args.popFirst()
    case "--raw": raw = true
    case "--help", "-h":
        print("""
        wabe — MacBook orientation service

          wabe watch [--raw]   live pose readout
          wabe recenter        zero the relative heading
          wabe status          service state
          wabe install         start at login (launchd, no root)
          wabe uninstall       stop and remove

        options: --sock <path>     (default /tmp/wabe.sock)
                 --daemon <path>   wabed to install (default: the one beside this binary)
        """)
        exit(0)
    default:
        FileHandle.standardError.write(Data("unknown argument: \(a) — see `wabe --help`\n".utf8))
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
            "no daemon on \(sockPath) — run `make install`, or `make && ./build/wabed`\n".utf8))
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

    var angles: String {
        String(format: "roll %+7.2f°  pitch %+7.2f°  yaw %+7.2f°", rpy[0], rpy[1], rpy[2])
    }
    /// Machines without a hinge encoder publish a negative angle; say so once instead of
    /// printing -1.00 forever.
    var hinge: String { lid < 0 ? "  (no hinge encoder)" : String(format: "  lid %6.2f°", lid) }
}

/// Read newline-delimited poses, handing each to `body` until it returns false.
func streamPoses(_ fd: Int32, _ body: (Pose, String) -> Bool) {
    var buf = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    var warnedUndecodable = false
    while true {
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { return }
        buf.append(contentsOf: chunk[0..<n])
        while let nl = buf.firstIndex(of: 0x0A) {
            let line = buf.prefix(upTo: nl)
            buf.removeSubrange(...nl)
            let text = String(decoding: line, as: UTF8.self)
            guard let p = try? JSONDecoder().decode(Pose.self, from: line) else {
                // Say it once. This struct is typed by hand against the daemon's writer, so a
                // renamed field reads as a daemon that publishes nothing at all.
                if !warnedUndecodable {
                    warnedUndecodable = true
                    let msg = "wabe: cannot decode a published line — the daemon's schema does "
                        + "not match this build of `wabe`:\n  \(text)\n"
                    FileHandle.standardError.write(Data(msg.utf8))
                }
                continue
            }
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
    let here = URL(fileURLWithPath: CommandLine.arguments[0])
        .resolvingSymlinksInPath().deletingLastPathComponent()
    // Whoever builds the daemon names it: `make` passes --daemon build/wabed, and on its own this
    // installs the copy beside itself, which is what re-running an installed `wabe install` means.
    // Never searched relative to the working directory — that would let the daemon under launchd
    // depend on where the command happened to be typed.
    let built = daemonPath.map { URL(fileURLWithPath: $0) } ?? here.appendingPathComponent("wabed")
    guard FileManager.default.fileExists(atPath: built.path) else {
        FileHandle.standardError.write(Data(
            "no wabed at \(built.path) — run `make install` from the checkout root\n".utf8))
        exit(1)
    }

    try? FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: plistPath.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    // Install the daemon and this control binary together — `wabe status` after `wabe install`
    // should work from anywhere, not only from the build directory.
    let toInstall = [(built, installedDaemon), (here.appendingPathComponent("wabe"), installedCLI)]
    for (src, dst) in toInstall {
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
    // Everything install put in ~/.local/bin, including this binary.
    for f in [installedDaemon, installedCLI] {
        try? FileManager.default.removeItem(at: f)
    }
    print("wabe uninstalled: agent stopped, \(binDir.path) binaries removed")
}

func doStatus() {
    let loaded = agentLoaded()
    print("agent    \(loaded ? "loaded" : "not installed")  (\(LABEL))")
    guard let fd = connectToDaemon() else {
        print("socket   \(sockPath): not responding")
        // Loaded-but-silent is a crashing daemon, not a missing install, and re-installing
        // will not fix it.
        if loaded {
            print("\nthe agent is loaded but nothing is answering, so the daemon is failing to start.")
            print("see \(logPath.path)")
        } else {
            print("\nstart it with `make install`, or `make && ./build/wabed` for a foreground one")
        }
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
    // The hinge encoder is a separate part from the IMU and some machines lack it, in which
    // case orientation still works and the screen normal does not.
    if p.lid < 0 { print("hinge    absent on this machine: no screen normal") }
    print("pose     " + p.angles + p.hinge + (p.stat ? "  at rest" : "  moving"))
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
            let normal = p.lid < 0 ? "" : String(format: "  n [%+.3f %+.3f %+.3f]",
                                                 p.n[0], p.n[1], p.n[2])
            print("\u{1B}[2K\r" + p.angles + p.hinge + normal + (p.stat ? " ·" : " ≈"),
                  terminator: "")
            fflush(stdout)
        }
        return true
    }
    print()
default:
    break
}
