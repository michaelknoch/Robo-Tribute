import Foundation
import Darwin

nonisolated struct SSHTunnelError: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// SSH port forwarding through the system OpenSSH client, so ~/.ssh/config, the agent and known_hosts all apply.
nonisolated final class SSHTunnel {
    private let settings: SSHSettings
    private let secrets: ConnectionSecrets
    private let remoteHost: String
    private let remotePort: Int
    private let timeoutSeconds: Int
    private let configFile: String?
    private var process: Process?
    private var askPassDirectory: URL?
    private var secretPath: String?
    private(set) var localPort = 0

    /// `configFile` replaces ~/.ssh/config (tests use /dev/null so they cannot touch the user's agent or keychain).
    init(settings: SSHSettings, secrets: ConnectionSecrets, remoteHost: String, remotePort: Int, timeoutSeconds: Int, configFile: String? = nil) {
        self.timeoutSeconds = max(timeoutSeconds, 5)
        self.configFile = configFile
        self.settings = settings
        self.secrets = secrets
        self.remoteHost = remoteHost
        self.remotePort = remotePort
    }

    deinit { stop() }

    func start() throws {
        localPort = try Self.freePort()
        let configArgs = configFile.map { ["-F", $0] } ?? []
        var args = configArgs + [
            "-N",
            "-L", "127.0.0.1:\(localPort):\(remoteHost):\(remotePort)",
            "-p", "\(settings.port)",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ConnectTimeout=\(timeoutSeconds)",
        ]
        let destination = settings.userName.isEmpty ? settings.host : "\(settings.userName)@\(settings.host)"
        // ssh takes the first value it sees, so a stricter setting in ~/.ssh/config must not be overridden.
        if !hostKeyCheckingIsStrict(configArgs: configArgs, destination: destination) {
            args += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        var environment = ProcessInfo.processInfo.environment
        let secret: String
        if settings.usesPublicKey {
            if !settings.privateKeyFile.isEmpty {
                args += ["-i", (settings.privateKeyFile as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"]
            }
            args += ["-o", "PreferredAuthentications=publickey"]
            secret = secrets.sshPassphrase
        } else {
            args += ["-o", "PreferredAuthentications=password,keyboard-interactive", "-o", "PubkeyAuthentication=no"]
            secret = secrets.sshPassword
        }
        if !secret.isEmpty {
            // An owner-only FIFO keeps the secret off disk and out of the long-lived ssh process environment.
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("robo-tribute-ssh-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let secretFile = directory.appendingPathComponent("secret")
            guard mkfifo(secretFile.path, 0o600) == 0 else {
                throw SSHTunnelError(message: "Unable to prepare SSH authentication")
            }
            Self.serveOnce(secret, at: secretFile.path)
            secretPath = secretFile.path
            let script = directory.appendingPathComponent("askpass")
            let body = "#!/bin/sh\n[ -p '\(secretFile.path)' ] && cat '\(secretFile.path)' 2>/dev/null\nexit 0\n"
            guard FileManager.default.createFile(atPath: script.path, contents: Data(body.utf8), attributes: [.posixPermissions: 0o700]) else {
                throw SSHTunnelError(message: "Unable to prepare SSH authentication")
            }
            askPassDirectory = directory
            environment["SSH_ASKPASS"] = script.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = environment["DISPLAY"] ?? ":0"
        } else {
            args += ["-o", "BatchMode=yes"]
        }
        args += ["--", destination]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = args
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        self.process = process
        Log.info("SSH tunnel: 127.0.0.1:\(localPort) -> \(remoteHost):\(remotePort) via \(settings.host)")

        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds + 5))
        while Date() < deadline {
            if !process.isRunning {
                let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                stop()
                throw SSHTunnelError(message: "SSH tunnel failed: " + message.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if Self.canConnect(port: localPort) {
                // A long-lived ssh blocks once nobody reads its stderr and the pipe fills up.
                stderr.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { handle.readabilityHandler = nil; return }
                    Log.warning("SSH: " + String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
                }
                return
            }
            usleep(100_000)
        }
        stop()
        throw SSHTunnelError(message: "SSH tunnel timed out connecting to \(settings.host):\(settings.port)")
    }

    private func hostKeyCheckingIsStrict(configArgs: [String], destination: String) -> Bool {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        probe.arguments = configArgs + ["-G", "-p", "\(settings.port)", "--", destination]
        let output = Pipe()
        probe.standardOutput = output
        probe.standardError = FileHandle.nullDevice
        guard (try? probe.run()) != nil else { return false }
        let config = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        probe.waitUntilExit()
        return config.split(separator: "\n").contains { $0 == "stricthostkeychecking true" || $0 == "stricthostkeychecking yes" }
    }

    func stop() {
        if let process, process.isRunning { process.terminate() }
        process = nil
        if let secretPath {
            // Releases a writer still blocked in open() when ssh never asked for the secret.
            let fd = open(secretPath, O_RDONLY | O_NONBLOCK)
            if fd >= 0 { close(fd) }
        }
        secretPath = nil
        if let askPassDirectory { try? FileManager.default.removeItem(at: askPassDirectory) }
        askPassDirectory = nil
    }

    /// Hands `secret` to the first reader of the FIFO, then unlinks it so later askpass calls get nothing.
    private static func serveOnce(_ secret: String, at path: String) {
        let data = Array((secret + "\n").utf8)
        Thread.detachNewThread {
            let fd = open(path, O_WRONLY)
            unlink(path)
            guard fd >= 0 else { return }
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
            _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            close(fd)
        }
    }

    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SSHTunnelError(message: "Unable to allocate a local port") }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        guard bound else { throw SSHTunnelError(message: "Unable to allocate a local port") }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    private static func canConnect(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = UInt16(port).bigEndian
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
}
