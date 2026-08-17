//
//  SystemMonitorViewModel.swift
//  ExGhostty_iPad
//
//  System monitor data collection: runs a portable shell script on the
//  remote Linux host via SSHSession.exec, parses key=value output and
//  publishes a snapshot every 5 seconds.
//

import Foundation

// MARK: - 数据模型

struct SystemMonitorSample {
    /// CPU 总体使用率（0-100）。
    var cpuOverall: Double = 0
    /// 每核使用率（0-100）。
    var cpuPerCore: [Double] = []
    /// 内存（字节）。
    var memTotal: UInt64 = 0
    var memUsed: UInt64 = 0
    var memAvailable: UInt64 = 0
    /// Swap（字节）。
    var swapTotal: UInt64 = 0
    var swapUsed: UInt64 = 0
    /// 负载均值。
    var load1: Double = 0
    var load5: Double = 0
    var load15: Double = 0
    /// 磁盘挂载点。
    var disks: [DiskMount] = []
    /// 网络速率（字节/秒）。
    var netRxPerSec: Double = 0
    var netTxPerSec: Double = 0
    /// CPU 占用 Top 进程。
    var topProcesses: [ProcessInfo] = []

    struct DiskMount: Identifiable {
        var id: String { mountPoint }
        let mountPoint: String
        let total: UInt64
        let used: UInt64
        /// 使用率（0-100）。
        let usedPercent: Double
    }

    struct ProcessInfo: Identifiable {
        var id: String { "\(pid)-\(command)" }
        let pid: Int32
        let command: String
        let cpuPercent: Double
        let memPercent: Double
    }
}

// MARK: - ViewModel

final class SystemMonitorViewModel: ObservableObject {
    /// 最新一次采样结果。
    @Published private(set) var sample: SystemMonitorSample?
    /// 是否正在进行首次采样。
    @Published private(set) var isLoading = true
    /// 采样失败信息（可重试）。
    @Published private(set) var errorMessage: String?
    /// 目标主机不是 Linux（无 /proc）时为 true。
    @Published private(set) var isUnsupported = false

    private let session: SSHSession
    private var pollTask: Task<Void, Never>?

    init(session: SSHSession) {
        self.session = session
    }

    deinit {
        pollTask?.cancel()
    }

    /// 启动 5 秒轮询采集。
    func start() {
        guard pollTask == nil else { return }
        isLoading = sample == nil
        errorMessage = nil
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.collectOnce()
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    break
                }
            }
        }
    }

    /// 停止轮询。
    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// 手动重试（错误/不支持状态下使用）。
    func retry() {
        stop()
        sample = nil
        isUnsupported = false
        start()
    }

    // MARK: - 采集

    @MainActor
    private func applySuccess(_ sample: SystemMonitorSample) {
        self.sample = sample
        self.isLoading = false
        self.errorMessage = nil
        self.isUnsupported = false
    }

    @MainActor
    private func applyUnsupported() {
        self.isUnsupported = true
        self.isLoading = false
        self.errorMessage = nil
        stop()
    }

    @MainActor
    private func applyError(_ message: String) {
        self.errorMessage = message
        self.isLoading = false
        stop()
    }

    private func collectOnce() async {
        do {
            let command = "echo \(Self.scriptBase64) | base64 -d | sh"
            let result = try await session.exec(command)
            let output = result.stdout
            if output.contains("unsupported=1") {
                await applyUnsupported()
                return
            }
            guard let sample = Self.parse(output) else {
                let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = detail.isEmpty
                    ? "无法解析监控数据（exit=\(result.exitStatus.map(String.init) ?? "?")）"
                    : detail
                await applyError(message)
                return
            }
            await applySuccess(sample)
        } catch {
            if !Task.isCancelled {
                await applyError(error.localizedDescription)
            }
        }
    }

    // MARK: - 解析

    /// 解析脚本输出的 key=value 行；没有任何有效数据时返回 nil。
    static func parse(_ output: String) -> SystemMonitorSample? {
        var sample = SystemMonitorSample()
        var cores: [(Int, Double)] = []
        var seenKeys = Set<String>()

        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq])
            let value = String(line[line.index(after: eq)...])
            seenKeys.insert(key)

            switch key {
            case "cpu_total":
                sample.cpuOverall = Double(value) ?? 0
            case let k where k.hasPrefix("cpu_core_"):
                if let index = Int(k.dropFirst("cpu_core_".count)),
                   let usage = Double(value) {
                    cores.append((index, usage))
                }
            case "mem_total":
                sample.memTotal = UInt64(value) ?? 0
            case "mem_used":
                sample.memUsed = UInt64(value) ?? 0
            case "mem_available":
                sample.memAvailable = UInt64(value) ?? 0
            case "swap_total":
                sample.swapTotal = UInt64(value) ?? 0
            case "swap_used":
                sample.swapUsed = UInt64(value) ?? 0
            case "load1":
                sample.load1 = Double(value) ?? 0
            case "load5":
                sample.load5 = Double(value) ?? 0
            case "load15":
                sample.load15 = Double(value) ?? 0
            case "net_rx":
                sample.netRxPerSec = Double(value) ?? 0
            case "net_tx":
                sample.netTxPerSec = Double(value) ?? 0
            case "disk":
                // disk=<mount>|<totalBytes>|<usedBytes>|<usedPercent>
                let fields = value.split(separator: "|", omittingEmptySubsequences: false)
                if fields.count == 4 {
                    let mount = String(fields[0])
                    sample.disks.append(SystemMonitorSample.DiskMount(
                        mountPoint: mount,
                        total: UInt64(fields[1]) ?? 0,
                        used: UInt64(fields[2]) ?? 0,
                        usedPercent: Double(fields[3]) ?? 0
                    ))
                }
            case "proc":
                // proc=<pid>|<comm>|<cpu>|<mem>
                let fields = value.split(separator: "|", omittingEmptySubsequences: false)
                if fields.count == 4 {
                    sample.topProcesses.append(SystemMonitorSample.ProcessInfo(
                        pid: Int32(fields[0]) ?? 0,
                        command: String(fields[1]),
                        cpuPercent: Double(fields[2]) ?? 0,
                        memPercent: Double(fields[3]) ?? 0
                    ))
                }
            default:
                break
            }
        }

        sample.cpuPerCore = cores.sorted { $0.0 < $1.0 }.map(\.1)
        guard seenKeys.contains("cpu_total") || seenKeys.contains("mem_total") else {
            return nil
        }
        return sample
    }

    // MARK: - 采集脚本

    /// 远端采集脚本（base64）。从 /proc 读取两次采样计算 CPU/网络差值，
    /// 输出固定格式的 key=value 行。仅依赖 POSIX sh、awk、df、ps。
    private static let scriptBase64: String = {
        let script = #"""
        if [ ! -r /proc/stat ] || [ ! -r /proc/meminfo ]; then
            echo "unsupported=1"
            exit 0
        fi

        net_sample() {
            awk 'BEGIN { rx = 0; tx = 0 }
                 NR > 2 {
                     pos = index($0, ":")
                     if (pos == 0) next
                     iface = substr($0, 1, pos - 1)
                     gsub(/[ \t]/, "", iface)
                     rest = substr($0, pos + 1)
                     gsub(/^[ \t]+/, "", rest)
                     n = split(rest, f, /[ \t]+/)
                     if (iface != "" && iface != "lo" && n >= 9) { rx += f[1]; tx += f[9] }
                 }
                 END { printf "%d %d", rx, tx }' /proc/net/dev
        }

        C1=$(grep '^cpu' /proc/stat)
        N1=$(net_sample)
        T1=$(date +%s%N 2>/dev/null)
        case "$T1" in (*N*|"") T1=0 ;; esac
        sleep 1
        C2=$(grep '^cpu' /proc/stat)
        N2=$(net_sample)
        T2=$(date +%s%N 2>/dev/null)
        case "$T2" in (*N*|"") T2=0 ;; esac

        # CPU：两次 /proc/stat 采样差值，idle = idle + iowait
        printf '%s\n---\n%s\n' "$C1" "$C2" | awk '
            /^---$/ { part = 2; next }
            part == 1 {
                name = $1
                total1[name] = 0
                for (i = 2; i <= NF; i++) { total1[name] += $i }
                idle1[name] = $5 + $6
                next
            }
            part == 2 {
                name = $1
                t2 = 0
                for (i = 2; i <= NF; i++) { t2 += $i }
                i2 = $5 + $6
                dt = t2 - total1[name]
                di = i2 - idle1[name]
                u = (dt > 0) ? (dt - di) * 100.0 / dt : 0
                if (u < 0) u = 0
                if (u > 100) u = 100
                if (name == "cpu") printf "cpu_total=%.1f\n", u
                else printf "cpu_core_%s=%.1f\n", substr(name, 4), u
            }'

        # 内存与 Swap（kB -> 字节）
        awk '/^MemTotal:/     { t  = $2 }
             /^MemAvailable:/ { a  = $2 }
             /^SwapTotal:/    { st = $2 }
             /^SwapFree:/     { sf = $2 }
             END {
                 u = t - a
                 printf "mem_total=%d\nmem_used=%d\nmem_available=%d\n", t * 1024, u * 1024, a * 1024
                 printf "swap_total=%d\nswap_used=%d\n", st * 1024, (st - sf) * 1024
             }' /proc/meminfo

        # 负载
        awk '{ printf "load1=%s\nload5=%s\nload15=%s\n", $1, $2, $3 }' /proc/loadavg

        # 网络速率（按实际间隔折算，缺时间时按 1 秒）
        echo "$N1 $N2 $T1 $T2" | awk '{
            rx1 = $1; tx1 = $2; rx2 = $3; tx2 = $4; t1 = $5; t2 = $6
            dt = (t2 - t1) / 1000000000.0
            if (dt <= 0) dt = 1
            printf "net_rx=%.0f\nnet_tx=%.0f\n", (rx2 - rx1) / dt, (tx2 - tx1) / dt
        }'

        # 磁盘（过滤虚拟文件系统，按挂载点去重）
        df -k -P 2>/dev/null | awk 'NR > 1 {
            fs = $1
            if (fs ~ /^(tmpfs|devtmpfs|overlay|shm|udev|none|squashfs)/) next
            mount = $NF
            if (seen[mount]++) next
            pct = $(NF - 1)
            gsub(/%/, "", pct)
            printf "disk=%s|%d|%d|%s\n", mount, $2 * 1024, $3 * 1024, pct
        }'

        # Top 5 CPU 进程
        ps -eo pid=,comm=,pcpu=,pmem= --sort=-pcpu 2>/dev/null | head -n 5 | \
            awk 'NF >= 4 { printf "proc=%s|%s|%s|%s\n", $1, $2, $3, $4 }'
        """#
        return Data(script.utf8).base64EncodedString()
    }()
}

// MARK: - 格式化辅助

extension UInt64 {
    /// 将字节格式化为人类可读字符串（B/KiB/MiB/GiB/TiB）。
    func formattedBytes() -> String {
        let f = Double(self)
        if self >= (1 << 40) { return String(format: "%.2f TiB", f / Double(1 << 40)) }
        if self >= (1 << 30) { return String(format: "%.2f GiB", f / Double(1 << 30)) }
        if self >= (1 << 20) { return String(format: "%.2f MiB", f / Double(1 << 20)) }
        if self >= (1 << 10) { return String(format: "%.2f KiB", f / Double(1 << 10)) }
        return "\(self) B"
    }
}

extension Double {
    /// 将字节/秒格式化为人类可读字符串。
    func formattedBytesPerSecond() -> String {
        guard self >= 0 else { return "N/A" }
        if self >= Double(1 << 40) { return String(format: "%.2f TiB/s", self / Double(1 << 40)) }
        if self >= Double(1 << 30) { return String(format: "%.2f GiB/s", self / Double(1 << 30)) }
        if self >= Double(1 << 20) { return String(format: "%.2f MiB/s", self / Double(1 << 20)) }
        if self >= Double(1 << 10) { return String(format: "%.2f KiB/s", self / Double(1 << 10)) }
        return String(format: "%.1f B/s", self)
    }
}
