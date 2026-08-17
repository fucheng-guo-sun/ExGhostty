//
//  SSHKeyManagementView.swift
//  iOSTerminal
//
//  Lists imported SSH private keys and offers two import paths:
//  picking a key file, or pasting the key text directly.
//  Key material itself lives in Keychain (see SSHKeyStore).
//

import SwiftUI
import UniformTypeIdentifiers

struct SSHKeyManagementView: View {
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
        Group {
            if keyStore.keys.isEmpty {
                ContentUnavailableView {
                    Label("没有 SSH 密钥", systemImage: "key")
                } description: {
                    Text("点击右上角导入密钥文件，或直接粘贴密钥文本")
                }
            } else {
                keyList
            }
        }
        .navigationTitle("密钥管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showFilePicker = true
                    } label: {
                        Label("从文件导入", systemImage: "doc")
                    }
                    Button {
                        showPasteSheet = true
                    } label: {
                        Label("粘贴文本", systemImage: "doc.on.clipboard")
                    }
                } label: {
                    Image(systemName: "plus")
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
        .alert("命名密钥", isPresented: namingAlertBinding, presenting: pendingFileImport) { pending in
            TextField("密钥名称", text: $importName)
            Button("导入") {
                importKey(name: importName, text: pending.text)
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("为这把密钥起一个便于识别的名称")
        }
        .alert("导入失败", isPresented: errorAlertBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    private var keyList: some View {
        List {
            ForEach(keyStore.keys) { key in
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
                }
                .padding(.vertical, 4)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        keyStore.delete(key)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
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
    @Environment(\.dismiss) private var dismiss

    /// Attempts the import; must throw on failure.
    let onImport: (String, String) throws -> Void
    let onError: (Error) -> Void

    @State private var name = ""
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("密钥名称", text: $name)
                }
                Section {
                    TextEditor(text: $text)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(minHeight: 220)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("密钥文本")
                } footer: {
                    Text("粘贴以 -----BEGIN 开头的私钥内容，支持未加密的 OpenSSH 和 PEM 格式。")
                }
            }
            .navigationTitle("粘贴密钥")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("导入") { importPasted() }
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
