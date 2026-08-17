//
//  Translations.Panels.swift
//  ExGhostty_iPad
//
//  English translations for the panels area (SessionReuse / PortUsage /
//  Docker / SystemMonitor feature panels). Keys are the Chinese source
//  strings wrapped in L() in those panels (see Translations.swift).
//

import Foundation

extension Translations {
    static let panels: [String: String] = [
        // MARK: SessionReuse
        "删除 %@ 会话": "Delete %@ Session",
        "确定要删除会话「%@」吗？该操作不可撤销。": "Delete session \"%@\"? This cannot be undone.",
        "删除": "Delete",
        "取消": "Cancel",
        "正在检测远端 tmux / rmux / zellij 环境…": "Detecting remote tmux / rmux / zellij…",
        "检测远端环境失败": "Failed to Detect Remote Environment",
        "重试": "Retry",
        "远端未安装 tmux / rmux / zellij": "tmux / rmux / zellij Not Installed on Remote Host",
        "会话复用需要远端安装终端复用工具。可以将下面的安装命令一键发送到当前终端标签页执行。":
            "Session reuse requires a terminal multiplexer on the remote host. Send one of the install commands below to the current terminal tab to run it.",
        "发送到终端": "Send to Terminal",
        "rmux 不在 apt 仓库中，请参照其项目文档手动安装。":
            "rmux is not in the apt repositories; install it manually following its project documentation.",
        "较旧的 Ubuntu 可能没有 zellij 软件包，可改用 cargo install zellij。":
            "Older Ubuntu releases may not ship a zellij package; use `cargo install zellij` instead.",
        "操作会以命令形式发送到当前终端标签页执行": "Actions are sent as commands to the current terminal tab",
        "新建 %@ 会话": "New %@ Session",
        "从当前 %@ 会话断开": "Detach from Current %@ Session",
        "暂无会话": "No Sessions",
        "删除会话 %@": "Delete Session %@",
        "会话名称（仅限英文和数字）": "Session name (letters and digits only)",
        "将在当前终端标签页中执行 %@ 命令。": "The %@ command will run in the current terminal tab.",
        "创建": "Create",

        // MARK: PortUsage
        "结束进程": "Kill Process",
        "结束": "Kill",
        "确定要强制结束「%@」(PID %d) 吗？该操作不可撤销。":
            "Force kill \"%@\" (PID %d)? This cannot be undone.",
        "无法结束进程": "Unable to Kill Process",
        "好": "OK",
        "结束 %@ (PID %d) 失败，可能没有权限或进程已退出。":
            "Failed to kill %@ (PID %d); permission denied or the process has already exited.",
        "端口使用": "Port Usage",
        "共 %d 个监听端口": "%d listening ports",
        "按端口 / 进程搜索": "Search by port / process",
        "正在扫描监听端口…": "Scanning listening ports…",
        "扫描失败": "Scan Failed",
        "未发现监听端口": "No Listening Ports Found",
        "没有匹配的端口": "No Matching Ports",

        // MARK: Docker
        "容器": "Containers",
        "镜像": "Images",
        "卷": "Volumes",
        "网络": "Networks",
        "正在检测 Docker 环境…": "Checking Docker environment…",
        "删除容器": "Delete Container",
        "确定要删除容器 \"%@\" 吗？此操作不可恢复。": "Delete container \"%@\"? This cannot be undone.",
        "删除镜像": "Delete Image",
        "确定要删除镜像 \"%@:%@\" 吗？": "Delete image \"%@:%@\"?",
        "未安装 Docker": "Docker Not Installed",
        "Docker 管理需要远程主机已安装 docker CLI": "Docker management requires the docker CLI on the remote host",
        "重新检测": "Check Again",
        "Docker 服务未运行": "Docker Service Not Running",
        "无法连接 Docker daemon，请先在远程主机上启动服务：":
            "Cannot connect to the Docker daemon. Start the service on the remote host first:",
        "Docker 权限不足": "Docker Permission Denied",
        "当前用户无法访问 Docker daemon。建议把用户加入 docker 用户组（优于使用 sudo）：":
            "The current user cannot access the Docker daemon. Add the user to the docker group (preferred over sudo):",
        "执行后需重新登录（或重新连接）才能生效。": "Log in again (or reconnect) for the change to take effect.",
        "复制": "Copy",
        "正在加载…": "Loading…",
        "没有容器": "No Containers",
        "没有镜像": "No Images",
        "没有卷": "No Volumes",
        "没有网络": "No Networks",
        "Docker 服务未运行，请启动后刷新": "Docker service is not running; start it and refresh",
        "当前用户无权访问 Docker daemon": "The current user cannot access the Docker daemon",
        "容器仍在运行，请先停止": "Container is still running; stop it first",
        "镜像仍被容器引用，无法删除": "Image is still referenced by a container and cannot be deleted",
        "请安装或启动 Docker 服务": "Install or start the Docker service",
        "查看日志": "View Logs",
        "等待日志输出…": "Waiting for log output…",
        "日志 - %@": "Logs - %@",
        "关闭": "Close",

        // MARK: SystemMonitor
        "正在采集系统数据…": "Collecting system data…",
        "未检测到 xtop": "xtop Not Detected",
        "系统监控需要在远端主机安装 xtop。": "System monitor requires xtop on the remote host.",
        "打开 xtop 项目主页": "Open xtop Project Page",
        "采集失败": "Collection Failed",
        "xtop 数据流已结束": "The xtop data stream has ended",
        "内存": "Memory",
        "已用": "Used",
        "缓存": "Cached",
        "空闲": "Free",
        "磁盘": "Disk",
        "GPU 负载": "GPU Load",
        "显存": "VRAM",
        "GPU 不可用": "GPU Unavailable",
        "进程（共 %d 个）": "Processes (%d total)",
        "Top 内存": "Top Memory",
        "Top 磁盘": "Top Disk",
        "等待数据…": "Waiting for data…",
    ]
}
