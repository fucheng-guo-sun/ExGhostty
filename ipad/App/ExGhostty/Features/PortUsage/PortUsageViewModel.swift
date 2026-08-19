//
//  PortUsageViewModel.swift
//  ExGhostty_iPad
//
//  Port usage panel: scans LISTEN ports on the remote host over SSH,
//  parses lsof -F style field output and kills processes on request.
//

import Combine
import Foundation

/// 端口占用条目（远程主机的监听端口）。
struct PortUsageEntry: Identifiable, Hashable {
    /// 无法识别进程时（如无权限读取进程信息）为 -1。
    let pid: Int32
    let processName: String
    let address: String
    let port: UInt16
    /// 进程完整启动命令行（取自 ps），无法获取时为空。
    let commandLine: String

    var id: String { "\(pid)-\(address)-\(port)" }
}

@MainActor
final class PortUsageViewModel: ObservableObject {
    @Published private(set) var entries: [PortUsageEntry] = []
    @Published private(set) var isScanning = false
    /// 首次扫描是否已成功完成（区分加载中与加载失败）。
    @Published private(set) var hasLoaded = false
    @Published private(set) var loadError: String?
    /// 是否扫描 UDP 端口（默认仅 TCP LISTEN）。
    @Published var includeUDP = false {
        didSet {
            guard oldValue != includeUDP else { return }
            Task { await refresh() }
        }
    }

    private let session: SSHSession
    private var refreshTask: Task<Void, Never>?

    init(session: SSHSession) {
        self.session = session
    }

    deinit {
        refreshTask?.cancel()
    }

    /// 立即扫描一次，并开始 5 秒定时自动刷新。
    func startAutoRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        do {
            let result = try await session.exec(Self.makeScanScript(udp: includeUDP))
            guard !Task.isCancelled else { return }
            entries = Self.parseFieldOutput(result.stdout)
            hasLoaded = true
            loadError = nil
        } catch {
            if !Task.isCancelled {
                loadError = error.localizedDescription
            }
        }
    }

    /// 结束占用进程；成功后触发一次刷新。
    @discardableResult
    func kill(pid: Int32) async -> Bool {
        guard pid > 0 else { return false }
        do {
            let result = try await session.exec("kill -9 \(pid)")
            let ok = (result.exitStatus ?? 0) == 0
            if ok { await refresh() }
            return ok
        } catch {
            return false
        }
    }

    // MARK: - 扫描脚本

    /// 远端扫描：优先 lsof，退化到 ss / netstat；
    /// 三种来源统一输出 lsof -F pcn 风格字段（p<PID> / c<COMMAND> / n<ADDR:PORT>），复用同一解析器。
    /// 末尾追加 ps 的完整命令行（a<PID> <ARGS> 字段），供解析器按 PID 合并。
    /// 注意：脚本必须以 true 结尾保证退出码为 0，不能让 ps/awk 附加段拖垮前面的端口扫描结果。
    private static func makeScanScript(udp: Bool) -> String {
        let lsofArgs = udp ? "-nP -iUDP -F pcn" : "-nP -iTCP -sTCP:LISTEN -F pcn"
        let ssCmd = udp ? "ss -ulnp" : "ss -tlnp"
        let netstatCmd = udp ? "netstat -ulnp" : "netstat -tlnp"

        let ssAwk: String
        let netstatAwk: String
        if udp {
            // UDP 无 LISTEN 状态：ss 中为 UNCONN，netstat 中无状态列（pid/cmd 在第 6 列）。
            ssAwk = #"'$1=="UNCONN" { la=$4; port=la; sub(/.*:/,"",port); addr=la; sub(/:[^:]*$/,"",addr); pid=""; cmd="?"; if (match($0,/pid=[0-9]+/)) pid=substr($0,RSTART+4,RLENGTH-4); if (match($0,/\(\("[^"]+"/)) cmd=substr($0,RSTART+3,RLENGTH-4); if (pid=="") pid="-1"; print "p" pid; print "c" cmd; print "n" addr ":" port }'"#
            netstatAwk = #"'$1 ~ /^udp/ { la=$4; port=la; sub(/.*:/,"",port); addr=la; sub(/:[^:]*$/,"",addr); pid="-1"; cmd="?"; if ($6 ~ /^[0-9]+\//) { split($6,b,"/"); pid=b[1]; cmd=b[2] } print "p" pid; print "c" cmd; print "n" addr ":" port }'"#
        } else {
            ssAwk = #"'$1=="LISTEN" { la=$4; port=la; sub(/.*:/,"",port); addr=la; sub(/:[^:]*$/,"",addr); pid=""; cmd="?"; if (match($0,/pid=[0-9]+/)) pid=substr($0,RSTART+4,RLENGTH-4); if (match($0,/\(\("[^"]+"/)) cmd=substr($0,RSTART+3,RLENGTH-4); if (pid=="") pid="-1"; print "p" pid; print "c" cmd; print "n" addr ":" port }'"#
            netstatAwk = #"'$6=="LISTEN" { la=$4; port=la; sub(/.*:/,"",port); addr=la; sub(/:[^:]*$/,"",addr); pid="-1"; cmd="?"; if ($7 ~ /^[0-9]+\//) { split($7,b,"/"); pid=b[1]; cmd=b[2] } print "p" pid; print "c" cmd; print "n" addr ":" port }'"#
        }

        return """
        if command -v lsof >/dev/null 2>&1; then
          lsof \(lsofArgs) 2>/dev/null
        elif command -v ss >/dev/null 2>&1 && command -v awk >/dev/null 2>&1; then
          \(ssCmd) 2>/dev/null | awk \(ssAwk)
        elif command -v netstat >/dev/null 2>&1 && command -v awk >/dev/null 2>&1; then
          \(netstatCmd) 2>/dev/null | awk \(netstatAwk)
        fi
        if command -v ps >/dev/null 2>&1 && command -v awk >/dev/null 2>&1; then
          ps -eo pid=,args= 2>/dev/null | awk '{ pid=$1; $1=""; sub(/^ +/,""); if (pid ~ /^[0-9]+$/) print "a" pid " " $0 }'
        fi
        true
        """
    }

    // MARK: - 解析

    /// 解析 lsof -F pcn 风格字段流；a<PID> <ARGS> 行为进程完整命令行，按 PID 合并进条目。
    static func parseFieldOutput(_ text: String) -> [PortUsageEntry] {
        let lines = text.components(separatedBy: .newlines)

        var argsByPid: [Int32: String] = [:]
        for line in lines where line.first == "a" {
            let rest = line.dropFirst()
            guard let space = rest.firstIndex(of: " "),
                  let pid = Int32(rest[rest.startIndex..<space]) else { continue }
            argsByPid[pid] = String(rest[rest.index(after: space)...])
        }

        var entries: [PortUsageEntry] = []
        var seen: Set<String> = []
        var pid: Int32 = 0
        var command = ""
        for line in lines {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                pid = Int32(value) ?? -1
                command = ""
            case "c":
                command = value
            case "n":
                guard !command.isEmpty else { continue }
                let name = value.replacingOccurrences(of: " (LISTEN)", with: "")
                guard let colon = name.lastIndex(of: ":") else { continue }
                guard let port = UInt16(name[name.index(after: colon)...]), port > 0 else { continue }
                let address = String(name[name.startIndex..<colon])
                let entry = PortUsageEntry(
                    pid: pid,
                    processName: command,
                    address: address,
                    port: port,
                    commandLine: argsByPid[pid] ?? ""
                )
                if seen.insert(entry.id).inserted {
                    entries.append(entry)
                }
            default:
                continue
            }
        }
        return entries.sorted { ($0.port, $0.processName, $0.pid) < ($1.port, $1.processName, $1.pid) }
    }
}
