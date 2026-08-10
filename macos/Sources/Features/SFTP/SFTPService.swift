import Foundation
import Combine

/// SFTP/SSH 相关错误。
enum SFTPError: Error, LocalizedError {
    case invalidConnection
    case commandNotFound(String)
    case listingFailed(String)
    case transferFailed(String)
    case helperSetupFailed
    case unsupportedAuth

    var errorDescription: String? {
        switch self {
        case .invalidConnection: return "Invalid SSH connection".localized
        case .commandNotFound(let cmd): return L("Command not found: %@", cmd)
        case .listingFailed(let msg): return L("Failed to list directory: %@", msg)
        case .transferFailed(let msg): return L("Transfer failed: %@", msg)
        case .helperSetupFailed: return "Failed to create password helper script".localized
        case .unsupportedAuth: return "Unsupported authentication method".localized
        }
    }
}

/// 负责执行远程命令和 rsync 传输。
actor SFTPService {
    static let shared = SFTPService()
    private init() {}

    // MARK: - 目录列表

    /// 列出远程目录内容。优先使用 `find -printf`；失败时回退到 `ls -la`。
    func listDirectory(
        connection: SSHConnection,
        path: String,
        showHidden: Bool
    ) async throws -> [SFTPFileItem] {
        let escapedPath = path.singleQuotedShellArgument()
        // find 输出格式: <类型>\t<大小>\t<名称>\t<权限八进制>\t<修改时间epoch>
        let findCmd = "cd \(escapedPath) && find . -maxdepth 1 -mindepth 1 -printf '%y\\t%s\\t%f\\t%m\\t%T@\\n'"
        let output: String
        do {
            output = try await SSHCommandExecutor.shared.execute(remoteCommand: findCmd, connection: connection)
        } catch {
            // 回退到 ls -la
            let lsCmd = "ls -la \(escapedPath)"
            let lsOutput = try await SSHCommandExecutor.shared.execute(remoteCommand: lsCmd, connection: connection)
            return try parseLSOutput(lsOutput, showHidden: showHidden)
        }

        let items = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> SFTPFileItem? in
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard parts.count >= 5 else { return nil }
                let typeChar = String(parts[0])
                let size = Int64(parts[1])
                let name = String(parts[2])
                let perms = String(parts[3])
                let mtime = TimeInterval(parts[4])

                if name == "." || name == ".." { return nil }
                if !showHidden && name.hasPrefix(".") { return nil }

                let type: SFTPItemType
                switch typeChar {
                case "d": type = .directory
                case "l": type = .symlink
                case "f", "-": type = .file
                default: type = .other
                }

                return SFTPFileItem(
                    name: name,
                    type: type,
                    size: size,
                    modificationDate: mtime.map { Date(timeIntervalSince1970: $0) },
                    permissions: perms
                )
            }
        return items
    }

    /// 返回有效用户的主目录路径。
    ///
    /// 注意不能用 `pwd`：新 SSH 会话总是落在登录用户的主目录，「用户身份」
    /// 包装为目标用户也不会改变会话的起始目录（会得到登录用户的 home）。
    /// 改为从 passwd 读取有效用户自己的 home。
    func currentRemoteDirectory(connection: SSHConnection) async throws -> String {
        let username = connection.effectiveIdentity?.username ?? connection.username
        let output = try await SSHCommandExecutor.shared.execute(
            remoteCommand: "(getent passwd \(username) 2>/dev/null || grep -m1 '^\(username):' /etc/passwd) | cut -d: -f6",
            connection: connection
        )
        let home = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return home.isEmpty ? "/" : home
    }

    // MARK: - 上传

    func uploadFile(
        connection: SSHConnection,
        localURL: URL,
        remoteDirectory: String,
        task: SFTPTask
    ) async throws {
        let remotePath = remoteDirectory + "/" + localURL.lastPathComponent
        try await runRsyncUpload(
            connection: connection,
            localPath: localURL.path,
            remotePath: remotePath,
            task: task
        )
    }

    func uploadDirectory(
        connection: SSHConnection,
        localURL: URL,
        remoteDirectory: String,
        task: SFTPTask
    ) async throws {
        let archiveName = "ghostty_upload_\(UUID().uuidString).tar.gz"
        let localArchive = FileManager.default.temporaryDirectory.appendingPathComponent(archiveName)
        let remoteArchive = remoteDirectory + "/" + archiveName

        defer { try? FileManager.default.removeItem(at: localArchive) }

        await updateTask(task, progress: 0.05, state: .running)

        // 1. 本地压缩
        try await createTarArchive(source: localURL, archive: localArchive)
        await updateTask(task, progress: 0.15)

        // 2. 上传压缩包
        try await runRsyncUpload(
            connection: connection,
            localPath: localArchive.path,
            remotePath: remoteArchive,
            task: task,
            progressOffset: 0.15,
            progressScale: 0.70,
            compress: true
        )

        // 3. 远程解压
        await updateTask(task, progress: 0.88)
        let extractCmd = "cd \((remoteDirectory).singleQuotedShellArgument()) && tar -xzf \((archiveName).singleQuotedShellArgument()) && rm \((archiveName).singleQuotedShellArgument())"
        _ = try await SSHCommandExecutor.shared.execute(remoteCommand: extractCmd, connection: connection)

        await updateTask(task, progress: 1.0, state: .completed)
    }

    // MARK: - 下载

    func downloadFile(
        connection: SSHConnection,
        remotePath: String,
        localDirectory: URL,
        task: SFTPTask
    ) async throws {
        let localURL = localDirectory.appendingPathComponent((remotePath as NSString).lastPathComponent)
        try await runRsyncDownload(
            connection: connection,
            remotePath: remotePath,
            localPath: localURL.path,
            task: task
        )
    }

    func downloadDirectory(
        connection: SSHConnection,
        remotePath: String,
        localDirectory: URL,
        task: SFTPTask
    ) async throws {
        let name = (remotePath as NSString).lastPathComponent
        // 压缩包名不能带目录名：目录名含冒号时 GNU tar 会把 `-f` 参数
        // 误判为 host:path 远程语法而失败，而 busybox tar 又不支持
        // --force-local。与上传一致使用随机名，兼容所有 tar 实现。
        let archiveName = "ghostty_download_\(UUID().uuidString).tar.gz"
        let remoteArchive = (remotePath as NSString).deletingLastPathComponent + "/" + archiveName
        let localArchive = localDirectory.appendingPathComponent(archiveName)

        defer {
            try? FileManager.default.removeItem(at: localArchive)
            let cleanupCmd = "rm -f \((remoteArchive).singleQuotedShellArgument())"
            // 尽量清理，不抛错
            Task {
                _ = try? await SSHCommandExecutor.shared.execute(remoteCommand: cleanupCmd, connection: connection)
            }
        }

        await updateTask(task, progress: 0.05, state: .running)

        // 1. 远程压缩
        let parent = (remotePath as NSString).deletingLastPathComponent.singleQuotedShellArgument()
        let base = name.singleQuotedShellArgument()
        let compressCmd = "cd \(parent) && tar -czf \((archiveName).singleQuotedShellArgument()) \(base)"
        _ = try await SSHCommandExecutor.shared.execute(remoteCommand: compressCmd, connection: connection)
        await updateTask(task, progress: 0.25)

        // 2. 下载压缩包
        try await runRsyncDownload(
            connection: connection,
            remotePath: remoteArchive,
            localPath: localArchive.path,
            task: task,
            progressOffset: 0.25,
            progressScale: 0.65,
            compress: true
        )

        // 3. 本地解压
        await updateTask(task, progress: 0.93)
        try await extractTarArchive(archive: localArchive, destination: localDirectory)
        await updateTask(task, progress: 1.0, state: .completed)
    }

    // MARK: - 删除

    func deleteFile(
        connection: SSHConnection,
        remotePath: String
    ) async throws {
        let cmd = "rm -f \((remotePath).singleQuotedShellArgument())"
        _ = try await SSHCommandExecutor.shared.execute(remoteCommand: cmd, connection: connection)
    }

    func deleteDirectory(
        connection: SSHConnection,
        remotePath: String
    ) async throws {
        let cmd = "rm -rf \((remotePath).singleQuotedShellArgument())"
        _ = try await SSHCommandExecutor.shared.execute(remoteCommand: cmd, connection: connection)
    }

    // MARK: - 重命名

    func rename(
        connection: SSHConnection,
        from oldPath: String,
        to newPath: String
    ) async throws {
        let cmd = "mv \((oldPath).singleQuotedShellArgument()) \((newPath).singleQuotedShellArgument())"
        _ = try await SSHCommandExecutor.shared.execute(remoteCommand: cmd, connection: connection)
    }

    // MARK: - 权限

    /// 检查远程路径对当前用户是否可写。检查失败时按不可写处理。
    func isWritable(connection: SSHConnection, path: String) async -> Bool {
        let cmd = "test -w \(path.singleQuotedShellArgument()) && echo 1 || echo 0"
        guard let output = try? await SSHCommandExecutor.shared.execute(remoteCommand: cmd, connection: connection) else {
            return false
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    // MARK: - rsync 传输

    private func runRsyncUpload(
        connection: SSHConnection,
        localPath: String,
        remotePath: String,
        task: SFTPTask,
        progressOffset: Double = 0,
        progressScale: Double = 1,
        compress: Bool = false
    ) async throws {
        await deploySudoAskpassIfNeeded(connection: connection)
        try await SSHCommandExecutor.shared.withControlChannel(connection: connection) { socket in
            var args = ["--partial", "--progress", "-e", "ssh -S \(socket)"]
            if compress { args.append("-z") }
            self.applyIdentityToRsyncArgs(&args, connection: connection)
            args.append(localPath)
            // 远程路径由远端 shell 解析，含空格时会被拆分，必须加引号；
            // host 去除首尾空白（存量配置可能带尾随空格，会导致 rsync 报 hostname 非法）。
            args.append("\(connection.host.trimmingCharacters(in: .whitespaces)):\(remotePath.singleQuotedShellArgument())")
            try await self.runRsync(args: args, task: task, progressOffset: progressOffset, progressScale: progressScale)
        }
    }

    private func runRsyncDownload(
        connection: SSHConnection,
        remotePath: String,
        localPath: String,
        task: SFTPTask,
        progressOffset: Double = 0,
        progressScale: Double = 1,
        compress: Bool = false
    ) async throws {
        await deploySudoAskpassIfNeeded(connection: connection)
        try await SSHCommandExecutor.shared.withControlChannel(connection: connection) { socket in
            var args = ["--partial", "--progress", "-e", "ssh -S \(socket)"]
            if compress { args.append("-z") }
            self.applyIdentityToRsyncArgs(&args, connection: connection)
            // 远程路径由远端 shell 解析，含空格时会被拆分，必须加引号；host 去除首尾空白。
            args.append("\(connection.host.trimmingCharacters(in: .whitespaces)):\(remotePath.singleQuotedShellArgument())")
            args.append(localPath)
            try await self.runRsync(args: args, task: task, progressOffset: progressOffset, progressScale: progressScale)
        }
    }

    /// 「用户身份」启用时，rsync 需以目标用户身份在远端运行。
    /// rsync 协议流占用 stdin，无法走 sudo -S；有密码时用 sudo -A + SUDO_ASKPASS 助手
    /// （助手由 deploySudoAskpassIfNeeded 以登录用户身份部署，700 权限）；
    /// 无密码时用 sudo -n（依赖 NOPASSWD）。
    private func applyIdentityToRsyncArgs(_ args: inout [String], connection: SSHConnection) {
        guard let identity = connection.effectiveIdentity else { return }
        if let password = identity.sudoPassword, !password.isEmpty {
            let askpass = SSHIdentity.sudoAskpassPath(connectionID: connection.id)
            args += ["--rsync-path", "SUDO_ASKPASS=\(askpass) sudo -A -u \(identity.username) rsync"]
        } else {
            args += ["--rsync-path", "sudo -n -u \(identity.username) rsync"]
        }
    }

    /// 已部署 sudo askpass 助手的连接及对应密码（密码变更时重新部署）。
    private var deployedSudoAskpass: [UUID: String] = [:]

    /// 「用户身份」启用且有密码时，把 sudo askpass 助手部署到远端（幂等）：
    /// 内容为输出 sudo 密码（base64 防特殊字符），权限 700、以登录用户身份写入
    /// （sudo -A 由登录用户的 rsync 会话调用，必须对登录用户可执行）。
    private func deploySudoAskpassIfNeeded(connection: SSHConnection) async {
        guard let identity = connection.effectiveIdentity,
              let password = identity.sudoPassword, !password.isEmpty else { return }
        guard deployedSudoAskpass[connection.id] != password else { return }
        let passwordB64 = Data(password.utf8).base64EncodedString()
        let script = "#!/bin/sh\necho \(passwordB64) | base64 -d\n"
        let scriptB64 = Data(script.utf8).base64EncodedString()
        let path = SSHIdentity.sudoAskpassPath(connectionID: connection.id)
        let deployed = (try? await SSHCommandExecutor.shared.executeAsLoginUser(
            remoteCommand: "echo \(scriptB64) | base64 -d > \(path); chmod 700 \(path)",
            connection: connection
        )) != nil
        if deployed {
            deployedSudoAskpass[connection.id] = password
        }
    }

    private func runRsync(
        args: [String],
        task: SFTPTask,
        progressOffset: Double,
        progressScale: Double
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        await MainActor.run { task.process = process }

        return try await withCheckedThrowingContinuation { continuation in
            var buffer = Data()
            let outHandle = outPipe.fileHandleForReading
            outHandle.readabilityHandler = { fh in
                let data = fh.availableData
                guard !data.isEmpty else { return }
                buffer.append(data)
                // rsync --progress 用 \r 原地刷新进度行，只有文件传完才输出 \n，
                // 因此 \r 和 \n 都必须视为行分隔符，否则中途的进度永远解析不到。
                while let sep = buffer.firstIndex(where: { $0 == UInt8(ascii: "\r") || $0 == UInt8(ascii: "\n") }) {
                    let lineData = buffer.subdata(in: 0..<sep)
                    buffer.removeSubrange(0...sep)
                    guard let line = String(data: lineData, encoding: .utf8) else { continue }
                    if let percent = Self.parseRsyncProgress(line) {
                        let overall = progressOffset + percent * progressScale
                        DispatchQueue.main.async {
                            task.progress = min(overall, 0.99)
                        }
                    }
                }
            }

            process.terminationHandler = { _ in
                outHandle.readabilityHandler = nil
                DispatchQueue.main.async { task.process = nil }
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let cmd = (["rsync"] + args).joined(separator: " ")
                    let msg = stderr.isEmpty ? L("rsync exit code %d", process.terminationStatus) : stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: SFTPError.transferFailed("[\(cmd)] \(msg)"))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - 压缩/解压

    private func createTarArchive(source: URL, archive: URL) async throws {
        let parent = source.deletingLastPathComponent().path
        let name = source.lastPathComponent
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = [
            "-czf", archive.path,
            "--exclude=.DS_Store",
            "--exclude=._*",
            "--exclude=.Spotlight-V100",
            "--exclude=.Trashes",
            "--exclude=.fseventsd",
            "--exclude=.TemporaryItems",
            "-C", parent, name
        ]
        try await ProcessRunner.run(process)
    }

    private func extractTarArchive(archive: URL, destination: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archive.path, "-C", destination.path]
        try await ProcessRunner.run(process)
    }

    // MARK: - 解析工具

    private static func parseRsyncProgress(_ line: String) -> Double? {
        // 同时兼容 --progress 与 --info=progress2 的输出：
        // "  123,456  12%  123.45kB/s    0:00:05"
        guard let range = line.range(of: "%") else { return nil }
        let prefix = line[..<range.lowerBound]
        let components = prefix.split(separator: " ")
        guard let last = components.last,
              let percent = Double(last.trimmingCharacters(in: .whitespaces)) else { return nil }
        return percent / 100.0
    }

    private func parseLSOutput(_ output: String, showHidden: Bool) throws -> [SFTPFileItem] {
        var items: [SFTPFileItem] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("d") || trimmed.hasPrefix("-") || trimmed.hasPrefix("l") else { continue }
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 9 else { continue }
            let perms = String(parts[0])
            let size = Int64(parts[4])
            let nameParts = parts.dropFirst(8)
            let name = nameParts.joined(separator: " ")
            if name == "." || name == ".." { continue }
            if !showHidden && name.hasPrefix(".") { continue }

            let type: SFTPItemType
            switch perms.first {
            case "d": type = .directory
            case "l": type = .symlink
            case "-": type = .file
            default: type = .other
            }
            items.append(SFTPFileItem(name: name, type: type, size: size, modificationDate: nil, permissions: String(perms.dropFirst())))
        }
        return items
    }

    private func updateTask(_ task: SFTPTask, progress: Double, state: SFTPTaskState? = nil) {
        DispatchQueue.main.async {
            task.progress = progress
            if let state { task.state = state }
        }
    }
}

// MARK: - 传输任务管理器

/// 管理 SFTP 上传/下载任务队列。
final class SFTPTransferManager: ObservableObject {
    static let shared = SFTPTransferManager()

    @Published private(set) var tasks: [SFTPTask] = []
    private var isRunning = false

    var activeUploadCount: Int {
        tasks.filter { $0.type == .upload && $0.isActive }.count
    }

    var activeDownloadCount: Int {
        tasks.filter { $0.type == .download && $0.isActive }.count
    }

    func addTask(_ task: SFTPTask) {
        DispatchQueue.main.async {
            self.tasks.append(task)
            self.runNext()
        }
    }

    func pauseTask(_ task: SFTPTask) {
        if task.state == .running {
            task.process?.terminate()
        }
        DispatchQueue.main.async { task.state = .paused }
    }

    func resumeTask(_ task: SFTPTask) {
        guard task.state == .paused else { return }
        DispatchQueue.main.async {
            task.state = .pending
            task.errorMessage = nil
            self.runNext()
        }
    }

    func cancelTask(_ task: SFTPTask) {
        task.process?.terminate()
        DispatchQueue.main.async { task.state = .cancelled }
    }

    /// 终止所有进行中任务的进程（供程序退出时调用，避免 rsync/ssh 残留后台）。
    func terminateAll() {
        for task in tasks where task.isActive {
            task.process?.terminate()
        }
    }

    func clearCompleted(for connection: SSHConnection? = nil) {
        DispatchQueue.main.async {
            if let connection {
                self.tasks.removeAll { $0.isCompleted && $0.connection.id == connection.id }
            } else {
                self.tasks.removeAll { $0.isCompleted }
            }
        }
    }

    private func runNext() {
        guard !isRunning else { return }
        guard let task = tasks.first(where: { $0.state == .pending }) else { return }
        isRunning = true
        Task {
            await execute(task)
            await MainActor.run {
                self.isRunning = false
                self.runNext()
            }
        }
    }

    private func execute(_ task: SFTPTask) async {
        await MainActor.run {
            task.errorMessage = nil
            if task.state == .pending { task.state = .running }
        }
        do {
            switch task.type {
            case .upload:
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: task.localPath, isDirectory: &isDir), isDir.boolValue {
                    try await SFTPService.shared.uploadDirectory(
                        connection: task.connection,
                        localURL: URL(fileURLWithPath: task.localPath),
                        remoteDirectory: task.remotePath,
                        task: task
                    )
                } else {
                    try await SFTPService.shared.uploadFile(
                        connection: task.connection,
                        localURL: URL(fileURLWithPath: task.localPath),
                        remoteDirectory: task.remotePath,
                        task: task
                    )
                }
            case .download:
                let destURL = URL(fileURLWithPath: task.localPath)
                if task.isDirectory {
                    try await SFTPService.shared.downloadDirectory(
                        connection: task.connection,
                        remotePath: task.remotePath,
                        localDirectory: destURL,
                        task: task
                    )
                } else {
                    try await SFTPService.shared.downloadFile(
                        connection: task.connection,
                        remotePath: task.remotePath,
                        localDirectory: destURL,
                        task: task
                    )
                }
            }
            await MainActor.run {
                task.progress = 1.0
                if task.state != .cancelled && task.state != .paused {
                    task.state = .completed
                }
            }
        } catch {
            await MainActor.run {
                if task.state != .cancelled && task.state != .paused {
                    task.state = .failed
                    task.errorMessage = error.localizedDescription
                }
            }
        }
    }
}
