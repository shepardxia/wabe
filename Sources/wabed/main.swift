import Foundation
import WabeCore

var cfg = WabeService.Config()
var args = ArraySlice(CommandLine.arguments.dropFirst())
while let a = args.popFirst() {
    switch a {
    case "--rate": cfg.sensorHz = Int(args.popFirst() ?? "") ?? cfg.sensorHz
    case "--pub": cfg.publishHz = Double(args.popFirst() ?? "") ?? cfg.publishHz
    case "--sock": cfg.socketPath = args.popFirst() ?? cfg.socketPath
    case "--help", "-h":
        print("wabed [--rate hz] [--pub hz] [--sock path]")
        exit(0)
    default:
        FileHandle.standardError.write(Data("unknown arg: \(a)\n".utf8))
        exit(2)
    }
}

do {
    try WabeService(cfg).run()
} catch let e as WabeError where e == .accelDead {
    // Sticky per-process driver stall — replace ourselves with a fresh process (fresh dice).
    let respawns = Int(ProcessInfo.processInfo.environment["WABE_RESPAWN"] ?? "0") ?? 0
    guard respawns < 5 else {
        FileHandle.standardError.write(Data("wabed: accel dead after \(respawns) respawns, giving up\n".utf8))
        exit(1)
    }
    FileHandle.standardError.write(Data("wabed: accel dead, re-exec (\(respawns + 1)/5)\n".utf8))
    setenv("WABE_RESPAWN", String(respawns + 1), 1)
    var exePath = [CChar](repeating: 0, count: 4096)
    var size = UInt32(exePath.count)
    _NSGetExecutablePath(&exePath, &size)
    let argv: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) } + [nil]
    execv(String(cString: exePath), argv)
    FileHandle.standardError.write(Data("wabed: execv failed\n".utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data("wabed: \(error)\n".utf8))
    exit(1)
}
