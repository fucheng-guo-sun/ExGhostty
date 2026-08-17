//
//  AIAssistantHistoryStore.swift
//  iOSTerminal
//
//  Persists AI assistant conversations in UserDefaults as JSON.
//  Each conversation keeps at most 100 messages; the store keeps at most
//  100 conversations.
//

import Foundation
import Combine

/// 负责持久化与查询 AI 对话历史。
@MainActor
final class AIAssistantHistoryStore: ObservableObject {
    static let shared = AIAssistantHistoryStore()

    private static let storageKey = "ai.assistant.history"
    private static let maxConversations = 100
    private static let maxMessagesPerConversation = 100

    @Published private(set) var conversations: [AIConversation] = []

    private let defaults = UserDefaults.standard
    private var saveTask: Task<Void, Never>?

    private init() {
        load()
    }

    /// 加载所有历史对话。
    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey) else { return }
        do {
            conversations = try JSONDecoder().decode([AIConversation].self, from: data)
        } catch {
            conversations = []
        }
    }

    /// 延迟合并写入，避免流式更新期间频繁落盘。
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self, defaults] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            guard let conversations = self?.conversations else { return }
            if let data = try? JSONEncoder().encode(conversations) {
                defaults.set(data, forKey: Self.storageKey)
            }
        }
    }

    /// 保存或更新一条对话；若已存在则替换，否则插入到最前面。
    /// 超出 100 条消息时丢弃最早的消息。
    func save(_ conversation: AIConversation) {
        var conversation = conversation
        if conversation.messages.count > Self.maxMessagesPerConversation {
            conversation.messages = Array(
                conversation.messages.suffix(Self.maxMessagesPerConversation)
            )
        }
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
        } else {
            conversations.insert(conversation, at: 0)
        }
        enforceLimit()
        scheduleSave()
    }

    /// 根据 ID 查找对话。
    func conversation(id: UUID) -> AIConversation? {
        conversations.first { $0.id == id }
    }

    /// 删除指定对话。
    func delete(id: UUID) {
        conversations.removeAll { $0.id == id }
        scheduleSave()
    }

    /// 面板关闭时立即落盘，避免延迟写入被取消导致数据丢失。
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        if let data = try? JSONEncoder().encode(conversations) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    private func enforceLimit() {
        guard conversations.count > Self.maxConversations else { return }
        conversations = Array(conversations.prefix(Self.maxConversations))
    }
}
