//
//  SFTPPanelView.swift
//  iOSTerminal
//
//  SFTP file manager panel: breadcrumb path bar, toolbar, remote file list
//  with download / rename / delete actions, document-picker uploads and
//  share-sheet downloads. Transfers show a progress bar at the bottom.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SFTPPanelView: View {
    @StateObject private var viewModel: SFTPViewModel

    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var renamingItem: SFTPItem?
    @State private var renameText = ""
    @State private var deletingItem: SFTPItem?
    @State private var actionItem: SFTPItem?
    @State private var showDocumentPicker = false
    @State private var shareURL: URL?

    init(session: SSHSession) {
        _viewModel = StateObject(wrappedValue: SFTPViewModel(session: session))
    }

    var body: some View {
        VStack(spacing: 0) {
            switch viewModel.state {
            case .idle, .loading:
                loadingView
            case .failed(let message):
                errorView(message)
            case .loaded:
                loadedView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { viewModel.open() }
        .onDisappear { viewModel.close() }
        .alert("新建文件夹", isPresented: $showNewFolderAlert) {
            TextField("文件夹名称", text: $newFolderName)
            Button("取消", role: .cancel) { newFolderName = "" }
            Button("创建") {
                let name = newFolderName
                newFolderName = ""
                Task { await viewModel.createFolder(named: name) }
            }
        }
        .alert("重命名", isPresented: renamingItemBinding) {
            TextField("新名称", text: $renameText)
            Button("取消", role: .cancel) { renamingItem = nil }
            Button("确定") {
                if let item = renamingItem {
                    renamingItem = nil
                    Task { await viewModel.rename(item, to: renameText) }
                }
            }
        }
        .alert("删除", isPresented: deletingItemBinding) {
            Button("取消", role: .cancel) { deletingItem = nil }
            Button("删除", role: .destructive) {
                if let item = deletingItem {
                    deletingItem = nil
                    Task { await viewModel.delete(item) }
                }
            }
        } message: {
            if let item = deletingItem {
                Text(item.isDirectory
                     ? "确定删除目录 “\(item.name)” 及其全部内容吗？"
                     : "确定删除文件 “\(item.name)” 吗？")
            }
        }
        .alert("错误", isPresented: errorBinding) {
            Button("确定", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .confirmationDialog(
            actionItem?.name ?? "",
            isPresented: actionItemBinding,
            titleVisibility: .visible
        ) {
            if let item = actionItem {
                Button("下载") {
                    actionItem = nil
                    downloadAndShare(item)
                }
                Button("重命名") {
                    actionItem = nil
                    renameText = item.name
                    renamingItem = item
                }
                Button("删除", role: .destructive) {
                    actionItem = nil
                    deletingItem = item
                }
                Button("取消", role: .cancel) { actionItem = nil }
            }
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPicker { url in
                guard let url else { return }
                Task { await uploadPickedFile(url) }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: shareSheetBinding) {
            if let shareURL {
                ShareSheet(items: [shareURL])
                    .ignoresSafeArea()
            }
        }
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(.teal)
            Text("正在打开 SFTP 会话…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("SFTP 打开失败")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("重试") { viewModel.open() }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadedView: some View {
        VStack(spacing: 0) {
            pathBar
            toolbar
            Divider()
            fileList
            if let transfer = viewModel.transfer {
                transferBar(transfer)
            }
        }
    }

    // MARK: - Path bar & toolbar

    private var pathBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(viewModel.breadcrumbs) { crumb in
                    if crumb.path != "/" {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        viewModel.navigate(to: crumb.path)
                    } label: {
                        Text(crumb.name)
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(crumb.path == viewModel.currentPath ? Color.teal : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(white: 0.13))
    }

    private var toolbar: some View {
        HStack(spacing: 20) {
            toolbarButton(icon: "arrow.up", help: "上级目录") {
                viewModel.goUp()
            }
            .disabled(viewModel.currentPath == "/")

            toolbarButton(icon: "arrow.clockwise", help: "刷新") {
                Task { await viewModel.refreshShowingErrors() }
            }

            toolbarButton(
                icon: viewModel.showHiddenFiles ? "eye" : "eye.slash",
                help: "显示/隐藏隐藏文件"
            ) {
                viewModel.showHiddenFiles.toggle()
            }

            toolbarButton(icon: "folder.badge.plus", help: "新建文件夹") {
                newFolderName = ""
                showNewFolderAlert = true
            }

            toolbarButton(icon: "square.and.arrow.up", help: "上传文件") {
                showDocumentPicker = true
            }

            Spacer()

            if viewModel.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .tint(.teal)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(white: 0.13))
    }

    private func toolbarButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.teal)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(help)
    }

    // MARK: - File list

    private var fileList: some View {
        List {
            if viewModel.visibleItems.isEmpty {
                Text("空目录")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(viewModel.visibleItems) { item in
                    fileRow(item)
                        .contentShape(Rectangle())
                        .onTapGesture { handleTap(item) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                deletingItem = item
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button {
                                renameText = item.name
                                renamingItem = item
                            } label: {
                                Label("重命名", systemImage: "pencil")
                            }
                            .tint(.orange)
                            if !item.isDirectory {
                                Button {
                                    downloadAndShare(item)
                                } label: {
                                    Label("下载", systemImage: "arrow.down.circle")
                                }
                                .tint(.teal)
                            }
                        }
                        .contextMenu {
                            if !item.isDirectory {
                                Button {
                                    downloadAndShare(item)
                                } label: {
                                    Label("下载", systemImage: "arrow.down.circle")
                                }
                            }
                            Button {
                                renameText = item.name
                                renamingItem = item
                            } label: {
                                Label("重命名", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                deletingItem = item
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            await viewModel.refreshShowingErrors()
        }
    }

    private func fileRow(_ item: SFTPItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.isDirectory ? "folder.fill" : fileIcon(for: item.name))
                .font(.title3)
                .foregroundStyle(item.isDirectory ? Color.teal : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    if !item.isDirectory {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                    }
                    if let date = item.modificationDate {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            Spacer()
            if item.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(Color(white: 0.15))
    }

    private func fileIcon(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "svg": return "photo"
        case "mp3", "wav", "aac", "flac", "m4a": return "music.note"
        case "mp4", "mov", "mkv", "avi": return "film"
        case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar": return "doc.zipper"
        case "txt", "md", "log", "json", "yaml", "yml", "xml", "conf", "sh", "py": return "doc.text"
        case "pdf": return "doc.richtext"
        default: return "doc"
        }
    }

    // MARK: - Transfer bar

    private func transferBar(_ transfer: SFTPViewModel.TransferProgress) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(transfer.title)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(transfer.sent), countStyle: .file)) / \(transfer.total > 0 ? ByteCountFormatter.string(fromByteCount: Int64(transfer.total), countStyle: .file) : "未知")")
                    .font(.system(.caption2, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if transfer.total > 0 {
                ProgressView(value: Double(transfer.sent), total: Double(transfer.total))
                    .tint(.teal)
            } else {
                ProgressView()
                    .tint(.teal)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(white: 0.13))
    }

    // MARK: - Actions

    private func handleTap(_ item: SFTPItem) {
        if item.isDirectory {
            viewModel.navigate(to: item.path)
        } else {
            actionItem = item
        }
    }

    private func downloadAndShare(_ item: SFTPItem) {
        Task {
            do {
                let localURL = try await viewModel.download(item)
                shareURL = localURL
            } catch {
                if !Task.isCancelled {
                    viewModel.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func uploadPickedFile(_ url: URL) async {
        // Copy the security-scoped pick into our temp directory first so the
        // upload does not depend on the picker keeping the file alive.
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("sftp-upload-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let localCopy = staging.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: localCopy)
            try await viewModel.upload(localURL: localCopy)
            try? FileManager.default.removeItem(at: staging)
        } catch {
            if !Task.isCancelled {
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Presentation bindings

    private var renamingItemBinding: Binding<Bool> {
        Binding(
            get: { renamingItem != nil },
            set: { if !$0 { renamingItem = nil } }
        )
    }

    private var deletingItemBinding: Binding<Bool> {
        Binding(
            get: { deletingItem != nil },
            set: { if !$0 { deletingItem = nil } }
        )
    }

    private var actionItemBinding: Binding<Bool> {
        Binding(
            get: { actionItem != nil },
            set: { if !$0 { actionItem = nil } }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }

    private var shareSheetBinding: Binding<Bool> {
        Binding(
            get: { shareURL != nil },
            set: { if !$0 { shareURL = nil } }
        )
    }
}

// MARK: - Document picker (local file upload)

/// Wraps UIDocumentPickerViewController to pick any local file (Files app,
/// iCloud Drive, third-party providers) instead of PhotosPicker.
private struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL?) -> Void

        init(onPick: @escaping (URL?) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPick(nil)
        }
    }
}

// MARK: - Share sheet (download destination)

/// Wraps UIActivityViewController so a downloaded file can be saved to
/// Files, AirDropped, or shared elsewhere.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
