//
//  Translations.ai.swift
//  ExGhostty_iPad
//
//  English translations for the ai area (see Translations.swift).
//

import Foundation

extension Translations {
    static let ai: [String: String] = [
        // MARK: AI 助手面板
        "AI 助手未配置": "AI Assistant Not Configured",
        "请先在设置页填写 AI 接口地址、API Key 和模型名称，\n然后回到此面板开始对话。":
            "Set the AI endpoint, API key, and model in Settings first,\nthen come back here to start chatting.",
        "新对话": "New Chat",
        "历史": "History",
        "向 AI 提问关于这台服务器的问题\n回答中的命令可以直接发送到终端执行":
            "Ask the AI about this server.\nCommands in replies can be sent straight to the terminal.",
        "正在采集服务器环境信息…": "Collecting server environment…",
        "正在等待 AI 回复…": "Waiting for AI reply…",
        "请求失败": "Request Failed",
        "重试": "Retry",
        "输入你的问题…": "Type your question…",
        "暂无历史对话": "No chat history yet",
        "%d 条": "%d messages",
        "删除": "Delete",
        "代码": "Code",
        "发送到终端": "Send to Terminal",
        "已复制": "Copied",
        "复制": "Copy",
        // MARK: AI 服务错误
        "AI 服务未配置，请先在设置页填写 API Key。":
            "AI service is not configured. Set the API key in Settings first.",
        "AI 接口地址无效。": "Invalid AI endpoint URL.",
        "AI 服务返回了无效的响应。": "The AI service returned an invalid response.",
        "AI 请求失败（%d）：%@": "AI request failed (%d): %@",
        "未知错误": "Unknown error",
    ]
}
