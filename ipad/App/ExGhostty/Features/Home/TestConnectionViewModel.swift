//
//  TestConnectionViewModel.swift
//  ExGhostty_iPad
//
//  连接编辑页「测试连接」的数据层（对标 Mac 版 SSHTestRunner）：用表单当前
//  草稿值构建一次性 SSHSession 做真实连接探测（iPad 无系统 ssh，走内嵌
//  NIOSSH 栈），分步执行（校验配置 → 跳板机 → 连接认证 → 远程命令 → 桌面
//  访问）并追加日志。密码/私钥密码遵循表单"留空保持已存"语义（留空时回落
//  Keychain）。测试会话独立创建、测完必断开，不污染在用会话。每步 ~15s
//  超时保护；日志存中文原文（key + 参数），由 View 层 L() 翻译渲染。
//

import Foundation
import NIOSSH

/// 「测试连接」的输入：表单草稿值 + 已有连接 id（用于"留空保持"回落 Keychain）。
struct TestConnectionInput: Identifiable {
    /// sheet(item:) 需要；每次弹出都是新快照。
    let id = UUID()
    /// 编辑已有连接时为其 id；新建为 nil。
    let existingID: UUID?
    var host: String
    /// 端口保留表单原文，有效性在第 1 步"校验配置"里检查并给出报错。
    var portText: String
    var username: String
    var authMode: SSHAuthMode
    var keyID: UUID?
    /// 表单里输入的密码；空串 = 留空（编辑时回落 Keychain 已存值）。
    var formPassword: String
    /// 表单里输入的私钥密码；语义同上。
    var formKeyPassphrase: String
    var desktopAccess: Bool
    var jumpHostID: UUID?
}

/// 一行日志：key 为中文原文（可含 %@ 占位），View 层 L() 翻译后再代入参数。
struct TestLogLine: Identifiable {
    let id = UUID()
    let key: String
    var args: [String] = []
}

/// 面向用户的步骤失败：key 为中文原文（可含 %@ 占位），View 层 L() 翻译。
struct TestStepFailure: Error {
    let key: String
    var args: [String] = []

    init(_ key: String, _ args: [String] = []) {
        self.key = key
        self.args = args
    }
}

/// 保证带超时的 continuation 只 resume 一次（先到者生效，慢者丢弃）。
private final class ResumeGuard<T>: @unchecked Sendable {
    private var resumed = false
    private let lock = NSLock()

    func resume(_ result: Result<T, Error>, continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        switch result {
        case .success(let value): continuation.resume(returning: value)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}

@MainActor
final class TestConnectionViewModel: ObservableObject {
    enum StepStatus {
        case pending
        case running
        case success
        case failure
    }

    struct Step: Identifiable {
        let id: Int
        /// 中文原文，View 层 L() 翻译。
        let titleKey: String
        var status: StepStatus = .pending
    }

    enum FinalResult {
        case success
        case failure
        case cancelled
    }

    @Published private(set) var steps: [Step] = []
    @Published private(set) var logs: [TestLogLine] = []
    @Published private(set) var isRunning = false
    @Published private(set) var finalResult: FinalResult?
    /// 结束语 key/参数（中文原文，View 层 L() 翻译）。
    @Published private(set) var finalMessageKey = ""
    @Published private(set) var finalMessageArgs: [String] = []

    private let input: TestConnectionInput
    private var runTask: Task<Void, Never>?
    /// 目标机测试会话（含跳板设置）。
    private var session: SSHSession?
    /// 跳板机探针会话（只验证到 transport 建立，验证完即弃）。
    private var jumpProbeSession: SSHSession?

    /// 每步超时；NIO 的 TCP connect 自身有 10s connectTimeout，这里是兜底。
    private static let stepTimeoutSeconds: TimeInterval = 15

    init(input: TestConnectionInput) {
        self.input = input
    }

    deinit {
        runTask?.cancel()
    }

    // MARK: - 入口

    func start() {
        guard runTask == nil else { return }
        isRunning = true
        var titles = ["校验配置"]
        if input.jumpHostID != nil { titles.append("连接跳板机") }
        titles += ["连接并认证", "执行远程命令"]
        if input.desktopAccess { titles.append("桌面访问测试") }
        steps = titles.enumerated().map { Step(id: $0.offset, titleKey: $0.element) }
        runTask = Task { await self.run() }
    }

    /// 取消：断开测试会话。NIO 的 await 不响应 Task 取消，所以这里直接置
    /// 终态；run() 里残留的 await 最终会因通道关闭报错退出（终态已置，不再
    /// 改 UI）。
    func cancel() {
        guard isRunning, finalResult == nil else { return }
        runTask?.cancel()
        session?.disconnect()
        jumpProbeSession?.disconnect()
        markRunningStepFailed()
        finish(.cancelled, key: "已取消测试")
    }

    // MARK: - 主流程

    private func run() async {
        defer {
            session?.disconnect()
            jumpProbeSession?.disconnect()
            isRunning = false
        }
        do {
            let prepared = try await performStep(0) { try self.validateConfig() }
            var stepIndex = 1
            var jumpSpec: SSHSession.JumpSpec?
            if input.jumpHostID != nil {
                jumpSpec = try await performStep(stepIndex) { try await self.testJumpHost() }
                stepIndex += 1
            }
            let target = try await performStep(stepIndex) {
                try await self.connectTarget(prepared, jump: jumpSpec)
            }
            stepIndex += 1
            try await performStep(stepIndex) { try await self.testRemoteCommand(target) }
            if input.desktopAccess {
                stepIndex += 1
                try await performStep(stepIndex) { try await self.testDesktopAccess(target) }
            }
            finish(.success, key: "测试通过")
        } catch is CancellationError {
            finish(.cancelled, key: "已取消测试")
        } catch let failure as TestStepFailure {
            finish(.failure, key: failure.key, args: failure.args)
        } catch {
            finish(.failure, key: "测试失败：%@", args: [error.localizedDescription])
        }
    }

    /// 统一包装一步：置 running → 执行 → 置 success/failure。已终态（用户
    /// 取消）时直接抛取消，避免残留的 await 把失败步骤改回 running。
    private func performStep<T>(_ index: Int, _ work: () async throws -> T) async throws -> T {
        guard finalResult == nil else { throw CancellationError() }
        steps[index].status = .running
        do {
            let value = try await work()
            steps[index].status = .success
            return value
        } catch {
            steps[index].status = .failure
            throw error
        }
    }

    // MARK: - 步骤 1：校验配置

    private struct Prepared {
        var config: SSHConnectionConfig
        var password: String?
        var privateKey: NIOSSHPrivateKey?
    }

    private func validateConfig() throws -> Prepared {
        let host = input.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw TestStepFailure("主机地址不能为空") }
        let portText = input.portText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(portText), (1...65535).contains(port) else {
            throw TestStepFailure("端口号无效：%@", [input.portText])
        }
        let username = input.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { throw TestStepFailure("用户名不能为空") }

        var privateKey: NIOSSHPrivateKey?
        if input.authMode == .key {
            guard let keyID = input.keyID else { throw TestStepFailure("未选择密钥") }
            guard let text = SSHKeyStore.shared.keyText(for: keyID) else {
                throw TestStepFailure("无法读取密钥内容")
            }
            do {
                // 加密密钥在这里就会暴露"需要密码/密码错误"，不必等到连接。
                let parsed = try SSHKeyParser.parse(text, passphrase: effectiveKeyPassphrase())
                privateKey = parsed.key
                let meta = SSHKeyStore.shared.meta(for: keyID)
                appendLog("密钥校验通过：%@", [meta.map { "\($0.name)（\($0.keyType)）" } ?? parsed.keyType])
            } catch {
                throw TestStepFailure("密钥校验失败：%@", [error.localizedDescription])
            }
        }

        var config = SSHConnectionConfig(name: "", host: host, port: port, username: username)
        config.authMode = input.authMode
        config.keyID = input.keyID
        config.desktopAccess = input.desktopAccess
        config.jumpHostID = input.jumpHostID

        appendLog("目标主机：%@:%@", [host, String(port)])
        appendLog("用户名：%@", [username])
        appendLog(input.authMode == .key ? "认证方式：密钥" : "认证方式：密码")
        return Prepared(config: config, password: effectivePassword(), privateKey: privateKey)
    }

    // MARK: - 步骤 2：跳板机连接（只验证到 transport 建立）

    private func testJumpHost() async throws -> SSHSession.JumpSpec {
        guard let jumpID = input.jumpHostID,
              let jumpConfig = ConnectionStore.shared.connections.first(where: { $0.id == jumpID }) else {
            throw TestStepFailure("跳板机配置不存在")
        }
        appendLog("正在连接跳板机 %@（%@:%@）…", [
            jumpConfig.displayName, jumpConfig.host, String(jumpConfig.port),
        ])
        // 凭证解析与 SessionFactory 同款：跳板是已存连接，密码/私钥密码直接
        // 从 Keychain 取（无"留空保持"问题）。
        let spec = SSHSession.JumpSpec(
            config: jumpConfig,
            password: KeychainHelper.password(for: jumpConfig.id),
            privateKey: resolvePrivateKey(for: jumpConfig)
        )
        let probe = SSHSession(config: jumpConfig, password: spec.password, privateKey: spec.privateKey)
        jumpProbeSession = probe
        do {
            try await withTimeout { try await probe.connect() }
        } catch {
            throw TestStepFailure("跳板机连接失败：%@", [error.localizedDescription])
        }
        appendLog("跳板机连接成功")
        return spec
    }

    // MARK: - 步骤 3：连接并认证目标机

    private func connectTarget(_ prepared: Prepared, jump: SSHSession.JumpSpec?) async throws -> SSHSession {
        appendLog("正在连接 %@:%@…", [prepared.config.host, String(prepared.config.port)])
        if prepared.privateKey != nil, prepared.password != nil {
            appendLog("使用密钥认证（失败时回退密码）")
        } else if prepared.privateKey != nil {
            appendLog("使用密钥认证")
        } else if prepared.password != nil {
            appendLog("使用密码认证")
        } else {
            appendLog("未提供密码或密钥，认证可能失败")
        }
        let session = SSHSession(
            config: prepared.config,
            password: prepared.password,
            privateKey: prepared.privateKey
        )
        session.jump = jump
        self.session = session
        do {
            try await withTimeout { try await session.connect() }
        } catch {
            throw TestStepFailure("连接失败：%@", [error.localizedDescription])
        }
        appendLog("连接并认证成功")
        return session
    }

    // MARK: - 步骤 4：执行远程命令

    private func testRemoteCommand(_ session: SSHSession) async throws {
        let marker = "__EXGHOSTTY_TEST_OK__"
        appendLog("执行远程命令：echo %@", [marker])
        let result: ExecResult
        do {
            result = try await withTimeout { try await session.execRaw("echo \(marker)") }
        } catch {
            throw TestStepFailure("远程命令执行失败：%@", [error.localizedDescription])
        }
        guard result.stdout.contains(marker) else {
            throw TestStepFailure("远程命令输出不符合预期")
        }
        appendLog("远程命令执行成功")
    }

    // MARK: - 步骤 5：桌面访问测试（sshdesk）

    private func testDesktopAccess(_ session: SSHSession) async throws {
        appendLog("正在检测 sshdesk 服务（command -v desktop）…")
        let result: ExecResult
        do {
            result = try await withTimeout { try await session.execRaw("command -v desktop") }
        } catch {
            throw TestStepFailure("桌面访问检测失败：%@", [error.localizedDescription])
        }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (result.exitStatus ?? 1) == 0, !path.isEmpty else {
            appendLog("项目地址：https://github.com/rarnu/sshdesk-go")
            throw TestStepFailure("目标主机未安装 sshdesk 服务")
        }
        appendLog("sshdesk 服务可用：%@", [path])
    }

    // MARK: - 凭证解析

    /// 表单密码的有效值：表单非空用表单值；留空时编辑场景回落 Keychain
    /// （与 ConnectionEditView 保存逻辑一致），新建场景留空即无密码。
    private func effectivePassword() -> String? {
        if !input.formPassword.isEmpty { return input.formPassword }
        guard let id = input.existingID else { return nil }
        return KeychainHelper.password(for: id)
    }

    /// 私钥密码的有效值；语义同 effectivePassword。
    private func effectiveKeyPassphrase() -> String? {
        if !input.formKeyPassphrase.isEmpty { return input.formKeyPassphrase }
        guard let id = input.existingID else { return nil }
        return KeychainHelper.keyPassphrase(for: id)
    }

    /// 跳板机密钥解析：与 SessionFactory.resolvePrivateKey 一致（容错，
    /// 解析失败返回 nil，由连接阶段的认证错误暴露原因）。
    private func resolvePrivateKey(for config: SSHConnectionConfig) -> NIOSSHPrivateKey? {
        guard config.authMode == .key,
              let keyID = config.keyID,
              let text = SSHKeyStore.shared.keyText(for: keyID),
              let parsed = try? SSHKeyParser.parse(
                  text, passphrase: KeychainHelper.keyPassphrase(for: config.id)
              ) else {
            return nil
        }
        return parsed.key
    }

    // MARK: - 超时与输出

    /// 每步超时保护：15s 内未完成即抛"操作超时"。NIO 的 await 不响应 Task
    /// 取消，超时后到期的子任务由随后 defer 的 disconnect() 收尸。
    private func withTimeout<T>(_ work: @escaping () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let guardBox = ResumeGuard<T>()
            Task {
                do {
                    guardBox.resume(.success(try await work()), continuation: continuation)
                } catch {
                    guardBox.resume(.failure(error), continuation: continuation)
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(Self.stepTimeoutSeconds * 1_000_000_000))
                guardBox.resume(.failure(TestStepFailure("操作超时")), continuation: continuation)
            }
        }
    }

    private func appendLog(_ key: String, _ args: [String] = []) {
        logs.append(TestLogLine(key: key, args: args))
    }

    private func markRunningStepFailed() {
        if let index = steps.firstIndex(where: { $0.status == .running }) {
            steps[index].status = .failure
        }
    }

    private func finish(_ result: FinalResult, key: String, args: [String] = []) {
        guard finalResult == nil else { return }
        finalResult = result
        finalMessageKey = key
        finalMessageArgs = args
        appendLog(key, args)
    }
}
