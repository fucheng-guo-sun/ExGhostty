import Foundation

/// Docker 容器条目（来自 `docker ps -a --format '{{json .}}'` 的单行 JSON）。
struct DockerContainer: Identifiable, Hashable {
    /// 容器短 ID。
    let id: String
    let image: String
    let names: String
    let state: String
    let status: String
    let ports: String

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

/// Docker 管理服务：本地终端在本机执行 docker CLI；SSH 终端通过 SSHCommandExecutor 在远程主机执行。
/// 标记为 `@unchecked Sendable` 是因为所有可变状态都在主线程上串行访问。
final class DockerService: ObservableObject, @unchecked Sendable {
    let connection: SSHConnection?

    @Published private(set) var containers: [DockerContainer] = []
    @Published private(set) var images: [DockerImage] = []
    @Published private(set) var volumes: [DockerVolume] = []
    @Published private(set) var networks: [DockerNetwork] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    init(connection: SSHConnection?) {
        self.connection = connection
    }

    /// 检查目标主机上是否存在 docker 命令。
    func checkDockerAvailable() async -> Bool {
        do {
            let path = try await run("command -v docker || which docker")
            return !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } catch {
            return false
        }
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
                    ports: $0.Ports ?? ""
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

    // MARK: - 操作

    enum ContainerAction: String {
        case start
        case stop
        case restart
        case remove = "rm"
    }

    /// 对容器执行 start/stop/restart/rm；成功返回 true，失败时设置 errorMessage。
    @discardableResult
    func performContainerAction(_ action: ContainerAction, id: String) async -> Bool {
        await perform("docker \(action.rawValue) \(Self.shellQuote(id))")
    }

    /// 删除镜像；成功返回 true，失败时设置 errorMessage。
    @discardableResult
    func removeImage(reference: String) async -> Bool {
        await perform("docker rmi \(Self.shellQuote(reference))")
    }

    /// 获取容器日志（默认最近 200 行；docker 的日志输出在 stderr，需合并到 stdout）。
    func containerLogs(id: String, tail: Int = 200) async throws -> String {
        try await run("docker logs --tail \(tail) \(Self.shellQuote(id)) 2>&1")
    }

    /// 获取容器端口映射（`docker port` 输出）。
    func containerPorts(id: String) async throws -> String {
        try await run("docker port \(Self.shellQuote(id))")
    }

    /// 获取容器挂载点列表（类型: 源 -> 目标，每行一条）。
    func containerMounts(id: String) async throws -> String {
        let template = "{{range .Mounts}}{{.Type}}: {{.Source}} -> {{.Destination}}{{\"\\n\"}}{{end}}"
        return try await run("docker inspect --format '\(template)' \(Self.shellQuote(id))")
    }

    /// 获取容器启动命令（实际执行的入口路径与参数）。
    func containerStartCommand(id: String) async throws -> String {
        let template = "{{.Path}} {{join .Args \" \"}}"
        return try await run("docker inspect --format '\(template)' \(Self.shellQuote(id))")
    }

    // MARK: - 内部辅助

    private func run(_ command: String) async throws -> String {
        if let connection {
            return try await SSHCommandExecutor.shared.execute(remoteCommand: command, connection: connection)
        }
        return try await ProcessRunner.run(shellCommand: command)
    }

    private func refresh<T>(
        _ command: String,
        parse: @escaping (String) -> [T],
        assign: @escaping ([T]) -> Void
    ) async {
        guard !isLoading else { return }
        await MainActor.run {
            isLoading = true
            errorMessage = nil
        }
        do {
            let output = try await run(command)
            let result = parse(output)
            await MainActor.run {
                assign(result)
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func perform(_ command: String) async -> Bool {
        do {
            _ = try await run(command)
            return true
        } catch {
            await MainActor.run { errorMessage = error.localizedDescription }
            return false
        }
    }

    /// 把任意值包裹为 shell 单引号字符串，内部的单引号转义为 `'\''`。
    private static func shellQuote(_ value: String) -> String {
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
