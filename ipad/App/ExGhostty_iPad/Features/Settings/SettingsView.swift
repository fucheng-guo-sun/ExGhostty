//
//  SettingsView.swift
//  ExGhostty_iPad
//
//  Settings page: AI assistant configuration, terminal appearance
//  and iCloud sync.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var settings = SettingsStore.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Endpoint", text: $settings.aiEndpoint)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API Key", text: $settings.aiAPIKey)
                    TextField("Model", text: $settings.aiModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("AI 助手")
                } footer: {
                    Text("兼容 OpenAI 的 /chat/completions 接口")
                }

                Section("密钥") {
                    NavigationLink("密钥管理") {
                        SSHKeyManagementView()
                    }
                }

                Section {
                    HStack {
                        Text("字号")
                        Spacer()
                        Text("\(Int(settings.terminalFontSize))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Stepper(
                            "",
                            value: $settings.terminalFontSize,
                            in: 9...24,
                            step: 1
                        )
                        .labelsHidden()
                    }
                    Picker("编辑器", selection: $settings.terminalEditor) {
                        ForEach(TerminalEditor.allCases) { editor in
                            Text(editor.rawValue).tag(editor.rawValue)
                        }
                    }
                } header: {
                    Text("终端")
                } footer: {
                    Text("SFTP 文件列表中「使用编辑器打开」会在终端里执行该编辑器。")
                }

                Section {
                    Toggle("开启同步", isOn: $settings.iCloudSyncEnabled)
                        .tint(.teal)
                        .onChange(of: settings.iCloudSyncEnabled) { _, enabled in
                            if enabled {
                                ICloudSyncManager.shared.start()
                                ICloudSyncManager.shared.syncNow()
                            } else {
                                ICloudSyncManager.shared.stop()
                            }
                        }
                    if settings.iCloudSyncEnabled {
                        Button("立即同步") {
                            ICloudSyncManager.shared.syncNow()
                        }
                        .tint(.teal)
                    }
                } header: {
                    Text("iCloud")
                } footer: {
                    Text("连接配置和密钥元数据通过 iCloud 键值存储同步；密码与私钥通过 iCloud 钥匙串同步。其他设备上的变更将在下次启动时生效。")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}

/// SFTP「使用编辑器打开」所用的终端编辑器（与 Mac 版 SettingsTerminalEditor
/// 保持一致）。rawValue 即远端可执行文件名，持久化在 SettingsStore。
enum TerminalEditor: String, CaseIterable, Identifiable {
    case vim, nvim, nano, emacs, micro, fresh

    var id: String { rawValue }
}
