import Foundation

/// Docker 容器条目（基础信息来自 `docker ps -a --format '{{json .}}'`；挂载点来自 `docker inspect`，
/// 因为 ps 的 Mounts 字段对长路径会以省略号截断）。
struct DockerContainer: Identifiable, Hashable {
    /// 容器短 ID。
    let id: String
    let image: String
    let names: String
    let state: String
    let status: String
    /// 端口映射列表，一个映射一行展示。
    let ports: [String]
    /// 挂载点描述列表（来源 -> 目标），一个挂载点一行展示。
    let mounts: [String]

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

/// 加载/操作失败的分类问题，供面板按情况展示“当前信息 + 解决方案”而不是原始红色错误。
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

/// Docker 管理服务：本地终端在本机执行 docker CLI；SSH 终端通过 SSHCommandExecutor 在远程主机执行。
/// 标记为 `@unchecked Sendable` 是因为所有可变状态都在主线程上串行访问。
final class DockerService: ObservableObject, @unchecked Sendable {
    let connection: SSHConnection?

    @Published private(set) var containers: [DockerContainer] = []
    @Published private(set) var images: [DockerImage] = []
    @Published private(set) var volumes: [DockerVolume] = []
    @Published private(set) var networks: [DockerNetwork] = []
    @Published private(set) var isLoading = false
    /// 最近一次加载（列表刷新）失败的分类问题；刷新开始时清除。统一以简化文案展示。
    @Published private(set) var issue: DockerIssue?
    /// 最近一次操作（启停/重启/删除等）失败的原始错误信息；保留原文展示。
    @Published private(set) var actionError: String?

    init(connection: SSHConnection?) {
        self.connection = connection
    }

    /// Docker 访问检查结果。
    enum DockerAccess {
        case ok
        /// docker CLI 不存在。
        case cliMissing
        /// 当前用户无权访问 Docker daemon socket（通常需要加入 docker 用户组，而非使用 sudo）。
        case permissionDenied
        /// 其他失败（如 daemon 未运行）。
        case unavailable
    }

    /// 检查目标主机上的 docker 可用性与访问权限。
    func checkDockerAccess() async -> DockerAccess {
        do {
            let path = try await run("command -v docker || which docker")
            if path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .cliMissing
            }
        } catch {
            return .cliMissing
        }
        do {
            // 保留 stderr（权限错误信息在 stderr 上），仅丢弃 stdout。
            _ = try await run("docker info >/dev/null")
            return .ok
        } catch {
            return Self.isPermissionDenied(error) ? .permissionDenied : .unavailable
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
        DispatchQueue.main.async { [weak self] in
            self?.issue = nil
        }
    }

    /// 清除当前操作错误（提示条的关闭按钮）。
    func dismissActionError() {
        DispatchQueue.main.async { [weak self] in
            self?.actionError = nil
        }
    }

    // MARK: - 列表

    /// 刷新容器列表。
    /// 分两条命令：`docker ps` 取基础信息；`docker inspect` 批量取完整挂载点
    ///（ps 的 Mounts 字段对长路径会以省略号截断）。
    func refreshContainers() async {
        guard !isLoading else { return }
        await MainActor.run {
            isLoading = true
            issue = nil
        }
        do {
            let output = try await run("docker ps -a --format '{{json .}}'")
            let rawList = Self.decodeLines(output, as: RawContainer.self)
            let mountsByID = await fetchFullMounts(ids: rawList.map { $0.ID })
            let result = rawList.map { raw in
                DockerContainer(
                    id: raw.ID,
                    image: raw.Image,
                    names: raw.Names,
                    state: raw.State,
                    status: raw.Status ?? "",
                    ports: (raw.Ports ?? "").split(separator: ", ").map(String.init),
                    mounts: mountsByID[raw.ID] ?? []
                )
            }
            await MainActor.run {
                containers = result
                isLoading = false
            }
        } catch {
            await MainActor.run {
                issue = Self.classify(error)
                isLoading = false
            }
        }
    }

    /// 批量 inspect 容器，返回 短 ID -> 完整挂载点描述（来源 -> 目标）列表。
    /// inspect 失败时返回空表，容器列表本身不受影响（仅挂载点缺失）。
    private func fetchFullMounts(ids: [String]) async -> [String: [String]] {
        guard !ids.isEmpty else { return [:] }
        let command = "docker inspect \(ids.map { Self.shellQuote($0) }.joined(separator: " "))"
        guard let output = try? await run(command),
              let data = output.data(using: .utf8),
              let list = try? JSONDecoder().decode([ContainerInspection].self, from: data) else {
            return [:]
        }
        var result: [String: [String]] = [:]
        for inspection in list {
            guard let fullID = inspection.Id else { continue }
            let mounts = (inspection.Mounts ?? []).compactMap { mount -> String? in
                guard let destination = mount.Destination, !destination.isEmpty else { return nil }
                var source = mount.Source ?? ""
                if mount.Type == "volume", let name = mount.Name, !name.isEmpty {
                    source = name
                }
                guard !source.isEmpty else { return nil }
                var line = "\(source) -> \(destination)"
                if mount.RW == false { line += " (ro)" }
                return line
            }
            result[String(fullID.prefix(12))] = mounts
        }
        return result
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

    /// 对容器执行 start/stop/restart/rm；成功返回 true，失败时设置 issue。
    @discardableResult
    func performContainerAction(_ action: ContainerAction, id: String) async -> Bool {
        await perform("docker \(action.rawValue) \(Self.shellQuote(id))")
    }

    /// 删除镜像；成功返回 true，失败时设置 issue。
    @discardableResult
    func removeImage(reference: String) async -> Bool {
        await perform("docker rmi \(Self.shellQuote(reference))")
    }

    /// 重建容器的 `docker run` 启动命令（基于 `docker inspect` 的配置，类似 runlike）。
    /// 覆盖：名称、重启策略、网络、特权、端口映射、环境变量、挂载、entrypoint 与 cmd。
    func containerRunCommand(id: String) async throws -> String {
        let output = try await run("docker inspect \(Self.shellQuote(id))")
        guard let data = output.data(using: .utf8),
              let list = try? JSONDecoder().decode([ContainerInspection].self, from: data),
              let inspection = list.first else {
            return ""
        }
        return Self.buildRunCommand(inspection)
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
            issue = nil
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
                issue = Self.classify(error)
                isLoading = false
            }
        }
    }

    private func perform(_ command: String) async -> Bool {
        await MainActor.run { actionError = nil }
        do {
            _ = try await run(command)
            return true
        } catch {
            // 操作类失败保留原始错误信息，便于用户判断真实原因。
            await MainActor.run {
                actionError = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return false
        }
    }

    /// 把任意值包裹为 shell 单引号字符串，内部的单引号转义为 `'\''`。
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 仅当值包含 shell 特殊字符时才加单引号，保持生成的 docker run 命令简洁可读。
    private static func shellQuoteIfNeeded(_ value: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:=@%,+-")
        return value.unicodeScalars.allSatisfy { safe.contains($0) } ? value : shellQuote(value)
    }

    // MARK: - docker run 命令重建

    /// `docker inspect` 输出的容器配置（取重建 docker run 所需的字段）。
    private struct ContainerInspection: Decodable {
        struct Config: Decodable {
            let Image: String?
            let Env: [String]?
            let Cmd: StringList?
            let Entrypoint: StringList?
            let Hostname: String?
            let Domainname: String?
            let User: String?
            let ExposedPorts: [String: [String: String]]?
            let WorkingDir: String?
            let Labels: [String: String]?
            let OpenStdin: Bool?
            let Tty: Bool?
            let StopSignal: String?
            let MacAddress: String?
        }
        struct HostConfig: Decodable {
            let RestartPolicy: RestartPolicy?
            let NetworkMode: String?
            let Privileged: Bool?
            let PortBindings: [String: [PortBinding]]?
            let PublishAllPorts: Bool?
            let Dns: [String]?
            let DnsOptions: [String]?
            let DnsSearch: [String]?
            let ExtraHosts: [String]?
            let Links: [String]?
            let CapAdd: [String]?
            let CapDrop: [String]?
            let Devices: [Device]?
            let DeviceCgroupRules: [String]?
            let SecurityOpt: [String]?
            let Ulimits: [Ulimit]?
            let Sysctls: [String: String]?
            let Memory: Int64?
            let MemorySwap: Int64?
            let MemoryReservation: Int64?
            let NanoCPUs: Int64?
            let CpuQuota: Int64?
            let CpuPeriod: Int64?
            let CpusetCpus: String?
            let BlkioWeight: Int?
            let PidsLimit: Int64?
            let ShmSize: Int64?
            let OomKillDisable: Bool?
            let ReadonlyRootfs: Bool?
            let Tmpfs: [String: String]?
            let LogConfig: LogConfig?
            let Runtime: String?
            let GroupAdd: [String]?
            let IpcMode: String?
            let PidMode: String?
            let UTSMode: String?
            let CgroupnsMode: String?
            let UsernsMode: String?
            let VolumesFrom: [String]?
            let AutoRemove: Bool?
            let Init: Bool?
            let Isolation: String?
            let CgroupParent: String?
        }
        struct RestartPolicy: Decodable {
            let Name: String?
        }
        struct PortBinding: Decodable {
            let HostIp: String?
            let HostPort: String?
        }
        struct Device: Decodable {
            let PathOnHost: String?
            let PathInContainer: String?
            let CgroupPermissions: String?
        }
        struct Ulimit: Decodable {
            let Name: String?
            let Soft: Int64?
            let Hard: Int64?
        }
        struct LogConfig: Decodable {
            let `Type`: String?
            let Config: [String: String]?
        }
        struct Mount: Decodable {
            let `Type`: String?
            let Name: String?
            let Source: String?
            let Destination: String?
            let RW: Bool?
        }
        let Id: String?
        let Name: String?
        let Config: Config?
        let HostConfig: HostConfig?
        let Mounts: [Mount]?
    }

    /// 兼容字符串 / 字符串数组两种 JSON 形式（不同 Docker 版本的 Cmd、Entrypoint 类型不一致）。
    private struct StringList: Decodable {
        let values: [String]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let array = try? container.decode([String].self) {
                values = array
            } else if let string = try? container.decode(String.self) {
                values = string.isEmpty ? [] : [string]
            } else {
                values = []
            }
        }
    }

    /// 把容器配置重建为一条可直接复制执行的 `docker run` 命令。
    private static func buildRunCommand(_ inspection: ContainerInspection) -> String {
        var parts: [String] = ["docker", "run", "-d"]
        let config = inspection.Config
        let hostConfig = inspection.HostConfig

        // 基本
        if let name = inspection.Name?.drop(while: { $0 == "/" }), !name.isEmpty {
            parts += ["--name", shellQuoteIfNeeded(String(name))]
        }
        if hostConfig?.AutoRemove == true {
            parts.append("--rm")
        }
        if let policy = hostConfig?.RestartPolicy?.Name, !policy.isEmpty, policy != "no" {
            parts += ["--restart", policy]
        }

        // 网络
        if let network = hostConfig?.NetworkMode, !network.isEmpty, network != "default" {
            parts += ["--network", network]
        }
        // 未显式设置 hostname 时，Docker 默认用容器短 ID 作为 hostname，不应重建进命令。
        if let hostname = config?.Hostname, !hostname.isEmpty,
           !(inspection.Id?.hasPrefix(hostname) ?? false) {
            parts += ["--hostname", shellQuoteIfNeeded(hostname)]
        }
        if let domainname = config?.Domainname, !domainname.isEmpty {
            parts += ["--domainname", shellQuoteIfNeeded(domainname)]
        }
        for dns in hostConfig?.Dns ?? [] {
            parts += ["--dns", dns]
        }
        for option in hostConfig?.DnsOptions ?? [] {
            parts += ["--dns-option", shellQuoteIfNeeded(option)]
        }
        for search in hostConfig?.DnsSearch ?? [] {
            parts += ["--dns-search", shellQuoteIfNeeded(search)]
        }
        for host in hostConfig?.ExtraHosts ?? [] {
            parts += ["--add-host", shellQuoteIfNeeded(host)]
        }
        for link in hostConfig?.Links ?? [] {
            parts += ["--link", shellQuoteIfNeeded(link)]
        }
        if let mac = config?.MacAddress, !mac.isEmpty {
            parts += ["--mac-address", mac]
        }

        // 端口
        let portBindings = hostConfig?.PortBindings ?? [:]
        for (containerPort, bindings) in portBindings.sorted(by: { $0.key < $1.key }) {
            for binding in bindings {
                var mapping = ""
                if let ip = binding.HostIp, !ip.isEmpty, ip != "0.0.0.0", ip != "::" {
                    mapping += "\(ip):"
                }
                if let hostPort = binding.HostPort, !hostPort.isEmpty {
                    mapping += "\(hostPort):"
                }
                mapping += containerPort
                parts += ["-p", shellQuoteIfNeeded(mapping)]
            }
        }
        // 已发布的端口隐含 expose，不重复输出。
        for exposed in (config?.ExposedPorts ?? [:]).keys.sorted() where portBindings[exposed] == nil {
            parts += ["--expose", exposed]
        }
        if hostConfig?.PublishAllPorts == true {
            parts.append("-P")
        }

        // 资源限制
        if let memory = hostConfig?.Memory, memory > 0 {
            parts += ["--memory", "\(memory)"]
        }
        if let memorySwap = hostConfig?.MemorySwap, memorySwap > 0 {
            parts += ["--memory-swap", "\(memorySwap)"]
        }
        if let reservation = hostConfig?.MemoryReservation, reservation > 0 {
            parts += ["--memory-reservation", "\(reservation)"]
        }
        if let nanoCPUs = hostConfig?.NanoCPUs, nanoCPUs > 0 {
            parts += ["--cpus", formatCPUs(Double(nanoCPUs) / 1_000_000_000)]
        } else if let quota = hostConfig?.CpuQuota, let period = hostConfig?.CpuPeriod, quota > 0, period > 0 {
            parts += ["--cpus", formatCPUs(Double(quota) / Double(period))]
        }
        if let cpuset = hostConfig?.CpusetCpus, !cpuset.isEmpty {
            parts += ["--cpuset-cpus", cpuset]
        }
        if let weight = hostConfig?.BlkioWeight, weight > 0 {
            parts += ["--blkio-weight", "\(weight)"]
        }
        if let pidsLimit = hostConfig?.PidsLimit, pidsLimit > 0 {
            parts += ["--pids-limit", "\(pidsLimit)"]
        }
        if let shmSize = hostConfig?.ShmSize, shmSize > 0 {
            parts += ["--shm-size", "\(shmSize)"]
        }
        for ulimit in hostConfig?.Ulimits ?? [] {
            guard let name = ulimit.Name, !name.isEmpty else { continue }
            parts += ["--ulimit", "\(name)=\(ulimit.Soft ?? 0):\(ulimit.Hard ?? 0)"]
        }

        // 设备与权限
        if hostConfig?.Privileged == true {
            parts.append("--privileged")
        }
        for cap in hostConfig?.CapAdd ?? [] {
            parts += ["--cap-add", cap]
        }
        for cap in hostConfig?.CapDrop ?? [] {
            parts += ["--cap-drop", cap]
        }
        for device in hostConfig?.Devices ?? [] {
            guard let onHost = device.PathOnHost, !onHost.isEmpty else { continue }
            var value = onHost
            if let inContainer = device.PathInContainer, !inContainer.isEmpty {
                value += ":\(inContainer)"
                if let permissions = device.CgroupPermissions, !permissions.isEmpty {
                    value += ":\(permissions)"
                }
            }
            parts += ["--device", shellQuoteIfNeeded(value)]
        }
        for rule in hostConfig?.DeviceCgroupRules ?? [] {
            parts += ["--device-cgroup-rule", shellQuoteIfNeeded(rule)]
        }
        for opt in hostConfig?.SecurityOpt ?? [] {
            parts += ["--security-opt", shellQuoteIfNeeded(opt)]
        }
        for (key, value) in (hostConfig?.Sysctls ?? [:]).sorted(by: { $0.key < $1.key }) {
            parts += ["--sysctl", shellQuoteIfNeeded("\(key)=\(value)")]
        }

        // 存储
        for mount in inspection.Mounts ?? [] {
            guard let destination = mount.Destination, !destination.isEmpty else { continue }
            var source = mount.Source ?? ""
            if mount.Type == "volume", let name = mount.Name, !name.isEmpty {
                source = name
            }
            guard !source.isEmpty else { continue }
            var volume = "\(source):\(destination)"
            if mount.RW == false { volume += ":ro" }
            parts += ["-v", shellQuoteIfNeeded(volume)]
        }
        for from in hostConfig?.VolumesFrom ?? [] {
            parts += ["--volumes-from", shellQuoteIfNeeded(from)]
        }
        for (destination, options) in (hostConfig?.Tmpfs ?? [:]).sorted(by: { $0.key < $1.key }) {
            let value = options.isEmpty ? destination : "\(destination):\(options)"
            parts += ["--tmpfs", shellQuoteIfNeeded(value)]
        }
        if hostConfig?.ReadonlyRootfs == true {
            parts.append("--read-only")
        }

        // 命名空间与运行时
        if let ipc = hostConfig?.IpcMode, !ipc.isEmpty, ipc != "private", ipc != "shareable" {
            parts += ["--ipc", ipc]
        }
        if let pid = hostConfig?.PidMode, !pid.isEmpty {
            parts += ["--pid", pid]
        }
        if let uts = hostConfig?.UTSMode, !uts.isEmpty {
            parts += ["--uts", uts]
        }
        if let userns = hostConfig?.UsernsMode, !userns.isEmpty {
            parts += ["--userns", userns]
        }
        if let cgroupns = hostConfig?.CgroupnsMode, !cgroupns.isEmpty, cgroupns != "private" {
            parts += ["--cgroupns", cgroupns]
        }
        if let parent = hostConfig?.CgroupParent, !parent.isEmpty {
            parts += ["--cgroup-parent", shellQuoteIfNeeded(parent)]
        }
        if let runtime = hostConfig?.Runtime, !runtime.isEmpty, runtime != "runc" {
            parts += ["--runtime", runtime]
        }
        if let isolation = hostConfig?.Isolation, !isolation.isEmpty, isolation != "default" {
            parts += ["--isolation", isolation]
        }
        if hostConfig?.Init == true {
            parts.append("--init")
        }
        if hostConfig?.OomKillDisable == true {
            parts.append("--oom-kill-disable")
        }
        if let signal = config?.StopSignal, !signal.isEmpty {
            parts += ["--stop-signal", signal]
        }

        // 日志
        if let driver = hostConfig?.LogConfig?.Type, !driver.isEmpty, driver != "json-file" {
            parts += ["--log-driver", driver]
        }
        for (key, value) in (hostConfig?.LogConfig?.Config ?? [:]).sorted(by: { $0.key < $1.key }) {
            parts += ["--log-opt", shellQuoteIfNeeded("\(key)=\(value)")]
        }

        // 进程与环境
        for group in hostConfig?.GroupAdd ?? [] {
            parts += ["--group-add", group]
        }
        if let user = config?.User, !user.isEmpty {
            parts += ["--user", shellQuoteIfNeeded(user)]
        }
        if let workdir = config?.WorkingDir, !workdir.isEmpty {
            parts += ["--workdir", shellQuoteIfNeeded(workdir)]
        }
        if config?.OpenStdin == true {
            parts.append("-i")
        }
        if config?.Tty == true {
            parts.append("-t")
        }
        for (key, value) in (config?.Labels ?? [:]).sorted(by: { $0.key < $1.key }) {
            let label = value.isEmpty ? key : "\(key)=\(value)"
            parts += ["--label", shellQuoteIfNeeded(label)]
        }
        for env in config?.Env ?? [] {
            parts += ["-e", shellQuoteIfNeeded(env)]
        }
        if let entrypoint = config?.Entrypoint?.values, !entrypoint.isEmpty {
            parts += ["--entrypoint", shellQuote(entrypoint.joined(separator: " "))]
        }
        parts.append(shellQuoteIfNeeded(config?.Image ?? ""))
        for arg in config?.Cmd?.values ?? [] {
            parts.append(shellQuoteIfNeeded(arg))
        }
        return parts.joined(separator: " ")
    }

    /// 格式化 --cpus 数值：整数值不带小数点，其余保留两位以内的小数。
    private static func formatCPUs(_ value: Double) -> String {
        if value == value.rounded() {
            return "\(Int(value))"
        }
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
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
