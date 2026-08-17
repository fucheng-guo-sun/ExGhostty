//
//  DockerViewModel.swift
//  iOSTerminal
//
//  Docker 管理面板的数据层：通过 SSHSession 在远程主机执行 docker CLI，
//  解析 `--format '{{json .}}'` 的逐行 JSON 输出，并执行容器/镜像操作。
//

import Foundation

/// Docker 容器条目（来自 `docker ps -a --format '{{json .}}'` 的单行 JSON）。
struct DockerContainer: Identifiable, Hashable {
    /// 容器短 ID。
    let id: String
    let image: String
    let names: String
    let state: String
    /// 人类可读状态（含运行时间，如 "Up 2 hours" / "Exited (0) 3 days ago"）。
    let status: String
    /// 端口映射列表，一个映射一行展示。
    let ports: [String]

    var isRunning: Bool { state.lowercased() == "running" }
}

/// Docker 镜像条目（来自 `docker images --format '{{json .}}'` 的单行 JSON）。
struct DockerImage: Identifiable, Hashable {
    /// 镜像短 ID。同一镜像可被打多个 tag（短 ID 相同），因此不能单独用作 Identifiable 的 id。
    let imageID: String
    let repository: String
    let tag: String
    let size: String

    /// 唯一标识：短 ID + 仓库 + 标签。
    var id: String { "\(imageID)-\(repository)-\(tag)" }

    /// 用于 `docker rmi` 的引用；悬空镜像（<none>）没有可用引用，只能用短 ID 删除。
    var reference: String {
        repository == "<none>" ? imageID : "\(repository):\(tag)"
    }
}

/// Docker 卷条目（来自 `docker volume ls --format '{{json .}}'` 的单行 JSON）。
struct DockerVolume: Identifiable, Hashable {
    let name: String
    let driver: String
    let scope: String

    var id: String { name }
}

/// Docker 网络条目（来自 `docker network ls --format '{{json .}}'` 的单行 JSON）。
struct DockerNetwork: Identifiable, Hashable {
    /// 网络短 ID。
    let id: String
    let name: String
    let driver: String
    let scope: String
}

/// 加载/操作失败的分类问题，供面板按情况展示而不是原始错误文本。
struct DockerIssue {
    enum Kind {
        /// Docker 服务未运行（无法连接 daemon）。
        case daemonDown
        /// 无权限访问 daemon socket（需加入 docker 用户组）。
        case permissionDenied
        /// 删除仍在运行的容器。
        case containerRunning
        /// 删除仍被容器引用的镜像。
        case imageInUse
        /// 其他命令失败。
        case commandFailed
    }

    let kind: Kind
    /// 原始错误信息（已去除首尾空白）。
    let detail: String
}

/// docker 命令以非零状态码退出时抛出的错误，message 取自 stderr。
struct DockerCommandError: Error, LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

/// Docker 管理面板的 ViewModel：可用性检测、四类资源列表加载与容器/镜像操作。
@MainActor
final class DockerViewModel: ObservableObject {
    let session: SSHSession

    @Published private(set) var containers: [DockerContainer] = []
    @Published private(set) var images: [DockerImage] = []
    @Published private(set) var volumes: [DockerVolume] = []
    @Published private(set) var networks: [DockerNetwork] = []
    @Published private(set) var isLoading = false
    /// 最近一次加载（列表刷新）失败的分类问题；刷新开始时清除。
    @Published private(set) var issue: DockerIssue?
    /// 最近一次操作（启停/重启/删除等）失败的原始错误信息；保留原文展示。
    @Published private(set) var actionError: String?

    init(session: SSHSession) {
        self.session = session
    }

    /// Docker 访问检查结果。
    enum DockerAccess {
        case ok
        /// docker CLI 不存在。
        case cliMissing
        /// 当前用户无权访问 Docker daemon socket（通常需要加入 docker 用户组，而非使用 sudo）。
        case permissionDenied
        /// daemon 未运行或其他原因导致不可用。
        case daemonDown
    }

    /// 检查远程主机上的 docker 可用性与访问权限。
    func checkDockerAccess() async -> DockerAccess {
        do {
            let result = try await session.exec("command -v docker")
            let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.isEmpty || (result.exitStatus ?? 1) != 0 {
                return .cliMissing
            }
        } catch {
            return .cliMissing
        }
        do {
            // 保留 stderr（权限与 daemon 错误信息在 stderr 上），仅丢弃 stdout。
            _ = try await run("docker info >/dev/null")
            return .ok
        } catch {
            return Self.isPermissionDenied(error) ? .permissionDenied : .daemonDown
        }
    }

    /// 判断错误是否为访问 Docker daemon socket 的权限问题。
    static func isPermissionDenied(_ error: Error) -> Bool {
        error.localizedDescription.localizedCaseInsensitiveContains("permission denied")
    }

    /// 把原始错误分类为结构化问题。
    static func classify(_ error: Error) -> DockerIssue {
        let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if isPermissionDenied(error) {
            return DockerIssue(kind: .permissionDenied, detail: text)
        }
        let lower = text.lowercased()
        if lower.contains("cannot connect to the docker daemon") || lower.contains("is the docker daemon running") {
            return DockerIssue(kind: .daemonDown, detail: text)
        }
        if lower.contains("container is running") {
            return DockerIssue(kind: .containerRunning, detail: text)
        }
        if lower.contains("image is being used") || lower.contains("is using its referenced image") {
            return DockerIssue(kind: .imageInUse, detail: text)
        }
        return DockerIssue(kind: .commandFailed, detail: text)
    }

    /// 清除当前问题（提示条的关闭按钮）。
    func dismissIssue() {
        issue = nil
    }

    /// 清除当前操作错误（提示条的关闭按钮）。
    func dismissActionError() {
        actionError = nil
    }

    // MARK: - 列表

    /// 刷新容器列表。
    func refreshContainers() async {
        await refresh("docker ps -a --format '{{json .}}'") { output in
            Self.decodeLines(output, as: RawContainer.self).map {
                DockerContainer(
                    id: $0.ID,
                    image: $0.Image,
                    names: $0.Names,
                    state: $0.State,
                    status: $0.Status ?? "",
                    ports: ($0.Ports ?? "").split(separator: ", ").map(String.init)
                )
            }
        } assign: { self.containers = $0 }
    }

    /// 刷新镜像列表。
    func refreshImages() async {
        await refresh("docker images --format '{{json .}}'") { output in
            Self.decodeLines(output, as: RawImage.self).map {
                DockerImage(imageID: $0.ID, repository: $0.Repository, tag: $0.Tag, size: $0.Size)
            }
        } assign: { self.images = $0 }
    }

    /// 刷新卷列表。
    func refreshVolumes() async {
        await refresh("docker volume ls --format '{{json .}}'") { output in
            Self.decodeLines(output, as: RawVolume.self).map {
                DockerVolume(name: $0.Name, driver: $0.Driver, scope: $0.Scope)
            }
        } assign: { self.volumes = $0 }
    }

    /// 刷新网络列表。
    func refreshNetworks() async {
        await refresh("docker network ls --format '{{json .}}'") { output in
            Self.decodeLines(output, as: RawNetwork.self).map {
                DockerNetwork(id: $0.ID, name: $0.Name, driver: $0.Driver, scope: $0.Scope)
            }
        } assign: { self.networks = $0 }
    }

    /// 依次刷新全部四类资源（首次进入面板时调用）。
    func refreshAll() async {
        await refreshContainers()
        await refreshImages()
        await refreshVolumes()
        await refreshNetworks()
    }

    // MARK: - 操作

    enum ContainerAction: String {
        case start
        case stop
        case restart
        case remove = "rm"
    }

    /// 对容器执行 start/stop/restart/rm；成功返回 true，失败时设置 actionError。
    @discardableResult
    func performContainerAction(_ action: ContainerAction, id: String) async -> Bool {
        await perform("docker \(action.rawValue) \(Self.shellQuote(id))")
    }

    /// 删除镜像；成功返回 true，失败时设置 actionError。
    @discardableResult
    func removeImage(reference: String) async -> Bool {
        await perform("docker rmi \(Self.shellQuote(reference))")
    }

    // MARK: - 内部辅助

    /// 执行远程命令并返回 stdout；非零退出码时抛出携带 stderr 的 DockerCommandError。
    private func run(_ command: String) async throws -> String {
        let result = try await session.exec(command)
        if let status = result.exitStatus, status != 0 {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DockerCommandError(message: detail.isEmpty ? "命令退出状态码：\(status)" : detail)
        }
        return result.stdout
    }

    private func refresh<T>(
        _ command: String,
        parse: (String) -> [T],
        assign: ([T]) -> Void
    ) async {
        guard !isLoading else { return }
        isLoading = true
        issue = nil
        do {
            let output = try await run(command)
            assign(parse(output))
            isLoading = false
        } catch {
            issue = Self.classify(error)
            isLoading = false
        }
    }

    private func perform(_ command: String) async -> Bool {
        actionError = nil
        do {
            _ = try await run(command)
            return true
        } catch {
            // 操作类失败保留原始错误信息，便于用户判断真实原因。
            actionError = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            return false
        }
    }

    /// 把任意值包裹为 shell 单引号字符串，内部的单引号转义为 `'\''`。
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 逐行解析 `--format '{{json .}}'` 输出，无法解析的行直接忽略。
    private static func decodeLines<T: Decodable>(_ output: String, as type: T.Type) -> [T] {
        let decoder = JSONDecoder()
        return output.components(separatedBy: .newlines).compactMap { line in
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = text.data(using: .utf8), !text.isEmpty else { return nil }
            return try? decoder.decode(type, from: data)
        }
    }

    private struct RawContainer: Decodable {
        let ID: String
        let Image: String
        let Names: String
        let State: String
        let Status: String?
        let Ports: String?
    }

    private struct RawImage: Decodable {
        let Repository: String
        let Tag: String
        let ID: String
        let Size: String
    }

    private struct RawVolume: Decodable {
        let Name: String
        let Driver: String
        let Scope: String
    }

    private struct RawNetwork: Decodable {
        let ID: String
        let Name: String
        let Driver: String
        let Scope: String
    }
}

// MARK: - 容器日志流

/// 容器日志 sheet 的 ViewModel：用 execStream 跑 `docker logs --tail 200 -f`，
/// 流式追加到文本；stop 时取消本地消费任务。
@MainActor
final class DockerLogsViewModel: ObservableObject {
    @Published private(set) var text = ""
    @Published private(set) var isStreaming = false

    private var streamTask: Task<Void, Never>?

    deinit {
        streamTask?.cancel()
    }

    /// 开始流式读取指定容器的日志（重复调用幂等）。
    func start(session: SSHSession, containerID: String) {
        guard streamTask == nil else { return }
        isStreaming = true
        // stderr 合并进 stdout，启动失败（如容器已删除）也能看到原因。
        let command = "docker logs --tail 200 -f \(DockerViewModel.shellQuote(containerID)) 2>&1"
        streamTask = Task { [weak self] in
            do {
                for try await chunk in session.execStream(command) {
                    try Task.checkCancellation()
                    self?.append(chunk)
                }
            } catch {
                // 取消或通道错误都按流结束处理。
            }
            self?.isStreaming = false
        }
    }

    /// 停止日志流（sheet 关闭时调用）。
    func stop() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
    }

    private func append(_ data: Data) {
        text += String(decoding: data, as: UTF8.self)
        // 限制内存占用：超出上限时丢弃最早的部分。
        if text.count > 200_000 {
            text = String(text.suffix(150_000))
        }
    }
}
