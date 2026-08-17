//
//  SSHKeyManagementView.swift
//  ExGhostty_iPad
//
//  Lists imported SSH private keys and offers two import paths:
//  picking a key file, or pasting the key text directly.
//  Key material itself lives in Keychain (see SSHKeyStore).
//  `SSHKeyListContent` is the navigation-free list (embedded directly in
//  Settings); `SSHKeyManagementView` wraps it for push-style entry points.
//

import SwiftUI
import UniformTypeIdentifiers

/// Push 入口用的整页包装（连接编辑页等处仍在用）。
struct SSHKeyManagementView: View {
    @StateObject private var l10n = LocalizationManager.shared

    var body: some View {
        ScrollView {
            SSHKeyListContent()
                .padding(16)
        }
        .navigationTitle(L("密钥管理"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 密钥列表 + 导入/删除的内容视图，无导航壳，可直接内嵌到设置页等
/// ScrollView 容器里。删除用行内垃圾桶按钮（不依赖 List 的 swipeActions）。
struct SSHKeyListContent: View {
    @StateObject private var l10n = LocalizationManager.shared
    @StateObject private var keyStore = SSHKeyStore.shared

    @State private var showFilePicker = false
    @State private var showPasteSheet = false
    /// Key text read from a picked file, waiting for the user to confirm a name.
    @State private var pendingFileImport: PendingImport?
    @State private var importName = ""
    @State private var importError: String?

    private struct PendingImport: Identifiable {
        let id = UUID()
        let suggestedName: String
        let text: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer()
                importMenu
            }

            if keyStore.keys.isEmpty {
                emptyState
            } else {
                ForEach(keyStore.keys) { key in
                    keyRow(key)
                }
            }
        }
        .sheet(isPresented: $showFilePicker) {
            KeyFilePicker { result in
                handlePickedFile(result)
            }
        }
        .sheet(isPresented: $showPasteSheet) {
            PasteKeySheet { name, text in
                try keyStore.importKey(name: name, text: text)
            } onError: { error in
                importError = error.localizedDescription
            }
        }
        .alert(L("命名密钥"), isPresented: namingAlertBinding, presenting: pendingFileImport) { pending in
            TextField(L("密钥名称"), text: $importName)
            Button(L("导入")) {
                importKey(name: importName, text: pending.text)
            }
            Button(L("取消"), role: .cancel) {}
        } message: { _ in
            Text(L("为这把密钥起一个便于识别的名称"))
        }
        .alert(L("导入失败"), isPresented: errorAlertBinding) {
            Button(L("好"), role: .cancel) {}
        } message: {
            Text(L(importError ?? ""))
        }
    }

    private var importMenu: some View {
        Menu {
            Button {
                showFilePicker = true
            } label: {
                Label(L("从文件导入"), systemImage: "doc")
            }
            Button {
                showPasteSheet = true
            } label: {
                Label(L("粘贴文本"), systemImage: "doc.on.clipboard")
            }
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.teal)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("没有 SSH 密钥"))
                .font(.subheadline)
            Text(L("点击 + 导入密钥文件，或直接粘贴密钥文本"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 8))
    }

    private func keyRow(_ key: SSHKeyMeta) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "key.fill")
                .font(.system(size: 18))
                .foregroundStyle(.teal)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(key.name)
                    .font(.system(size: 16, weight: .semibold))
                Text(key.keyType)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(key.createdAt.formatted(date: .numeric, time: .shortened))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                keyStore.delete(key)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 8))
    }

    private var namingAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingFileImport != nil },
            set: { if !$0 { pendingFileImport = nil } }
        )
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )
    }

    private func handlePickedFile(_ result: Result<(name: String, text: String), Error>) {
        switch result {
        case .success(let file):
            importName = file.name
            pendingFileImport = PendingImport(suggestedName: file.name, text: file.text)
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func importKey(name: String, text: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try keyStore.importKey(name: trimmed.isEmpty ? "未命名密钥" : trimmed, text: text)
        } catch {
            importError = error.localizedDescription
        }
    }
}

// MARK: - File picker

/// Wraps UIDocumentPickerViewController to read a private key file as text.
private struct KeyFilePicker: UIViewControllerRepresentable {
    enum PickError: LocalizedError {
        case notText

        var errorDescription: String? {
            switch self {
            case .notText: return "无法读取文件内容，请选择文本格式的私钥文件"
            }
        }
    }

    let onPick: (Result<(name: String, text: String), Error>) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.item, .text, .data],
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (Result<(name: String, text: String), Error>) -> Void

        init(onPick: @escaping (Result<(name: String, text: String), Error>) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let name = url.deletingPathExtension().lastPathComponent
                onPick(.success((name: name, text: text)))
            } catch {
                onPick(.failure(PickError.notText))
            }
        }
    }
}

// MARK: - Paste sheet

/// Sheet for pasting private key text directly, with a name field.
private struct PasteKeySheet: View {
    @StateObject private var l10n = LocalizationManager.shared
    @Environment(\.dismiss) private var dismiss

    /// Attempts the import; must throw on failure.
    let onImport: (String, String) throws -> Void
    let onError: (Error) -> Void

    @State private var name = ""
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(L("名称")) {
                    TextField(L("密钥名称"), text: $name)
                }
                Section {
                    TextEditor(text: $text)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(minHeight: 220)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text(L("密钥文本"))
                } footer: {
                    Text(L("粘贴以 -----BEGIN 开头的私钥内容，支持未加密的 OpenSSH 和 PEM 格式。"))
                }
            }
            .navigationTitle(L("粘贴密钥"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L("取消")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("导入")) { importPasted() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func importPasted() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try onImport(trimmedName.isEmpty ? "粘贴的密钥" : trimmedName, text)
            dismiss()
        } catch {
            onError(error)
        }
    }
}

#Preview {
    NavigationStack {
        SSHKeyManagementView()
    }
}
