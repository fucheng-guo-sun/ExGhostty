//
//  Translations.home.swift
//  ExGhostty_iPad
//
//  English translations for the home area (see Translations.swift):
//  connection list sidebar, add/edit connection form, split view root.
//

import Foundation

extension Translations {
    static let home: [String: String] = [
        // MARK: ConnectionListView
        "SSH 连接": "SSH Connections",
        "没有 SSH 连接": "No SSH Connections",
        "点击右上角 + 新增": "Tap + at the top right to add one",
        "未分组": "Ungrouped",
        "编辑": "Edit",
        "删除": "Delete",
        "取消": "Cancel",
        "删除连接": "Delete Connection",
        "确定要删除「%@」吗？": "Are you sure you want to delete \"%@\"?",

        // MARK: ConnectionEditView
        "新增连接": "New Connection",
        "编辑连接": "Edit Connection",
        "保存": "Save",
        "连接": "Connection",
        "名称（可选）": "Name (Optional)",
        "主机": "Host",
        "端口": "Port",
        "分组（可选）": "Group (Optional)",
        "用户名": "Username",
        "认证": "Authentication",
        "认证方式": "Auth Method",
        "密码": "Password",
        "密码（留空保持不变）": "Password (leave blank to keep)",
        "密码（可选，作为回退）": "Password (optional, as fallback)",
        "密码（可选，留空保持不变）": "Password (optional, leave blank to keep)",
        "密钥认证失败时，可回退使用该密码登录。":
            "If key authentication fails, this password can be used to log in as a fallback.",
        "私钥密码（可选，如密钥未加密可留空）":
            "Key passphrase (optional; leave blank if the key is not encrypted)",
        "私钥密码（留空保持不变）": "Key passphrase (leave blank to keep)",
        "作为桌面访问": "Use as Desktop Access",
        "需要目标主机安装sshdesk服务，": "Requires the sshdesk service on the target host. ",
        "点击查看详情": "Learn more",
        "还没有密钥，去导入": "No keys yet — import one",
        "未选择": "None",
        "管理密钥": "Manage Keys",
        "登录后切换用户": "Switch User After Login",
        "目标用户名（如 root）": "Target username (e.g. root)",
        "sudo 密码（留空保持不变）": "sudo password (leave blank to keep)",
        "sudo 密码（可选，NOPASSWD 可留空）": "sudo password (optional; leave blank for NOPASSWD)",
        "登录后自动执行 sudo su 切换到目标用户，终端及 SFTP、Docker、系统监控等远程操作均以该用户身份执行。":
            "Runs sudo su automatically after login to switch to the target user; the terminal and remote operations such as SFTP, Docker, and System Monitor all run as that user.",
        "跳板机": "Jump Host",
        "直连": "Direct",
        "高级": "Advanced",
        "编码": "Encoding",
        "备注": "Notes",

        // MARK: 端口转发
        "端口转发": "Port Forwarding",
        "没有转发规则": "No Forwarding Rules",
        "删除转发规则": "Delete Rule",
        "转发规则": "Forwarding Rule",
        "运行中": "Running",
        "类型": "Type",
        "规则名称": "Rule Name",
        "本地 (-L)": "Local (-L)",
        "远程 (-R)": "Remote (-R)",
        "动态 (-D)": "Dynamic (-D)",
        "把本机端口通过 SSH 转发到远端可达的某个主机端口":
            "Forward a local port through SSH to a host reachable from the remote side.",
        "把本机服务端口暴露到远端主机的监听端口上":
            "Expose a local service port on a listening port of the remote host.",
        "在本机起一个 SOCKS5 代理，流量经 SSH 出站":
            "Run a local SOCKS5 proxy; traffic exits via SSH.",
        "本地监听端口": "Local Listen Port",
        "目标主机": "Target Host",
        "目标端口": "Target Port",
        "远程监听端口": "Remote Listen Port",
        "本地服务端口": "Local Service Port",
        "本地代理端口": "Local Proxy Port",
        "规则绑定的 SSH 连接已不存在": "The SSH connection bound to this rule no longer exists.",
        "重连次数过多，已自动停止": "Too many reconnect attempts; stopped automatically.",
        "访问页面": "Open Page",
        "输入网址": "Enter URL",

        // MARK: TestConnectionView（测试连接）
        "测试连接": "Test Connection",
        "校验配置": "Validate Configuration",
        "连接跳板机": "Connect Jump Host",
        "连接并认证": "Connect & Authenticate",
        "执行远程命令": "Run Remote Command",
        "桌面访问测试": "Desktop Access Test",
        "测试通过": "Test Passed",
        "测试中，请稍候…": "Testing, please wait…",
        "已取消测试": "Test Cancelled",
        "主机地址不能为空": "Host must not be empty",
        "端口号无效：%@": "Invalid port: %@",
        "用户名不能为空": "Username must not be empty",
        "未选择密钥": "No key selected",
        "无法读取密钥内容": "Unable to read the key material",
        "密钥校验通过：%@": "Key validated: %@",
        "密钥校验失败：%@": "Key validation failed: %@",
        "目标主机：%@:%@": "Target host: %@:%@",
        "用户名：%@": "Username: %@",
        "认证方式：密钥": "Auth method: key",
        "认证方式：密码": "Auth method: password",
        "正在连接跳板机 %@（%@:%@）…": "Connecting to jump host %@ (%@:%@)…",
        "跳板机连接成功": "Jump host connected",
        "跳板机配置不存在": "Jump host configuration no longer exists",
        "跳板机连接失败：%@": "Jump host connection failed: %@",
        "正在连接 %@:%@…": "Connecting to %@:%@…",
        "使用密钥认证（失败时回退密码）": "Using key authentication (password as fallback)",
        "使用密钥认证": "Using key authentication",
        "使用密码认证": "Using password authentication",
        "未提供密码或密钥，认证可能失败": "No password or key provided; authentication may fail",
        "连接并认证成功": "Connected and authenticated",
        "连接失败：%@": "Connection failed: %@",
        "执行远程命令：echo %@": "Running remote command: echo %@",
        "远程命令执行成功": "Remote command succeeded",
        "远程命令执行失败：%@": "Remote command failed: %@",
        "远程命令输出不符合预期": "Remote command output did not match the expected marker",
        "正在检测 sshdesk 服务（command -v desktop）…":
            "Checking sshdesk service (command -v desktop)…",
        "sshdesk 服务可用：%@": "sshdesk service available: %@",
        "桌面访问检测失败：%@": "Desktop access check failed: %@",
        "目标主机未安装 sshdesk 服务": "The sshdesk service is not installed on the target host",
        "项目地址：https://github.com/rarnu/sshdesk-go":
            "Project page: https://github.com/rarnu/sshdesk-go",
        "操作超时": "Operation timed out",
        "测试失败：%@": "Test failed: %@",
    ]
}
