//
//  SystemMonitorViewModel.swift
//  ExGhostty_iPad
//
//  System monitor data collection, aligned with the Mac version: streams
//  `xtop --all --json --stream 5` on the remote host via SSHSession.
//  execStream, decodes one XTopOutput JSON object per line and publishes
//  the latest sample. Hosts without xtop get the unsupported state.
//

import Foundation

final class SystemMonitorViewModel: ObservableObject {
    /// 最新一次 xtop 输出。
    @Published private(set) var latest: XTopOutput?
    /// 是否正在等待首个采样。
    @Published private(set) var isLoading = true
    /// 采集失败信息（可重试）。
    @Published private(set) var errorMessage: String?
    /// 远端未安装 xtop 时为 true。
    @Published private(set) var isUnsupported = false

    private let session: SSHSession
    private var streamTask: Task<Void, Never>?

    init(session: SSHSession) {
        self.session = session
    }

    deinit {
        streamTask?.cancel()
    }

    /// 开始采集：先检测 xtop，再启动 JSON 流。
    func start() {
        guard streamTask == nil else { return }
        isLoading = latest == nil
        errorMessage = nil
        streamTask = Task { [weak self] in
            await self?.run()
        }
    }

    /// 停止采集（流的 onTermination 会关闭 exec channel，远端 xtop 随之退出）。
    func stop() {
        streamTask?.cancel()
        streamTask = nil
    }

    /// 手动重试（错误/未安装状态下使用）。
    func retry() {
        stop()
        latest = nil
        isUnsupported = false
        start()
    }

    // MARK: - 采集

    private func run() async {
        do {
            let check = try await session.exec("command -v xtop || which xtop")
            let path = check.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else {
                await applyUnsupported()
                return
            }
        } catch {
            if !Task.isCancelled {
                await applyError(error.localizedDescription)
            }
            return
        }

        var buffer = Data()
        do {
            for try await chunk in session.execStream("xtop --all --json --stream 5") {
                buffer.append(chunk)
                while let range = buffer.range(of: Data("\n".utf8)) {
                    let lineData = buffer.subdata(in: 0..<range.lowerBound)
                    buffer.removeSubrange(0..<range.upperBound)
                    if let output = Self.decodeLine(lineData) {
                        await applySuccess(output)
                    }
                }
            }
            // 流正常结束：远端 xtop 退出了。
            if !Task.isCancelled {
                await applyError("xtop 数据流已结束")
            }
        } catch {
            if !Task.isCancelled {
                await applyError(error.localizedDescription)
            }
        }
    }

    /// 解析一行 JSON；忽略空行和无法解析的行（如 xtop 的启动信息）。
    private static func decodeLine(_ data: Data) -> XTopOutput? {
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty, let lineData = text.data(using: .utf8) else { return nil }
        return try? jsonDecoder.decode(XTopOutput.self, from: lineData)
    }

    private static let jsonDecoder: JSONDecoder = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = formatter.date(from: string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid date: \(string)"
                )
            }
            return date
        }
        return decoder
    }()

    // MARK: - 状态应用

    @MainActor
    private func applySuccess(_ output: XTopOutput) {
        latest = output
        isLoading = false
        errorMessage = nil
        isUnsupported = false
    }

    @MainActor
    private func applyUnsupported() {
        isUnsupported = true
        isLoading = false
        errorMessage = nil
        stop()
    }

    @MainActor
    private func applyError(_ message: String) {
        errorMessage = message
        isLoading = false
        stop()
    }
}
