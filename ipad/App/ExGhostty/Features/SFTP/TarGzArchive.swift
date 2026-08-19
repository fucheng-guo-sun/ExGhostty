//
//  TarGzArchive.swift
//  ExGhostty_iPad
//
//  tar.gz packing and extraction for SFTP directory transfers, built on
//  SWCompression — the only reason that package is a dependency. Both
//  directions work fully in memory, which is fine for typical directory
//  trees but not for multi-GB ones. Extraction skips entries whose paths
//  would escape the destination; packing preserves symlinks as links and
//  skips special files (sockets, devices) that tar cannot portably pack.
//

import Foundation
import SWCompression

enum TarGzArchive {
    /// Extracts a .tar.gz into `destination`, recreating the archived tree.
    static func extract(archiveURL: URL, into destination: URL) throws {
        let compressed = try Data(contentsOf: archiveURL)
        let tarData = try GzipArchive.unarchive(archive: compressed)
        let entries = try TarContainer.open(container: tarData)

        let fileManager = FileManager.default
        let rootPath = destination.standardizedFileURL.path
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        for entry in entries {
            let target = destination
                .appendingPathComponent(entry.info.name)
                .standardizedFileURL
            // Path-traversal guard: never write outside the destination.
            guard target.path.hasPrefix(rootPath + "/") else { continue }

            switch entry.info.type {
            case .directory:
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            case .regular:
                try fileManager.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try (entry.data ?? Data()).write(to: target)
            case .symbolicLink:
                // Only relative link targets that stay inside the destination.
                let link = entry.info.linkName
                guard !link.isEmpty, !link.hasPrefix("/"), !link.contains("..") else { continue }
                try? fileManager.createSymbolicLink(atPath: target.path, withDestinationPath: link)
            default:
                continue
            }
        }
    }

    /// Packs a local directory into .tar.gz data. The archive contains the
    /// directory itself as the top-level entry, like running
    /// `tar -czf out.tar.gz <name>` from the directory's parent.
    static func pack(directoryAt url: URL) throws -> Data {
        let fileManager = FileManager.default
        var entries: [TarEntry] = []

        // Entry names are relative to the directory's parent.
        func walk(_ itemURL: URL, name: String) throws {
            let attributes = try fileManager.attributesOfItem(atPath: itemURL.path)
            guard let type = attributes[.type] as? FileAttributeType else { return }

            let infoType: ContainerEntryType
            switch type {
            case .typeDirectory: infoType = .directory
            case .typeRegular: infoType = .regular
            case .typeSymbolicLink: infoType = .symbolicLink
            default: return // sockets, devices etc. cannot be packed portably
            }

            var info = TarEntryInfo(name: name, type: infoType)
            info.modificationTime = attributes[.modificationDate] as? Date
            if let posix = (attributes[.posixPermissions] as? NSNumber)?.uint32Value {
                // Mask off the file-type bits; only the mode belongs in tar.
                info.permissions = Permissions(rawValue: posix & 0o7777)
            }

            switch infoType {
            case .directory:
                entries.append(TarEntry(info: info, data: nil))
                for child in try fileManager.contentsOfDirectory(atPath: itemURL.path).sorted() {
                    try walk(itemURL.appendingPathComponent(child), name: name + "/" + child)
                }
            case .symbolicLink:
                info.linkName = try fileManager.destinationOfSymbolicLink(atPath: itemURL.path)
                entries.append(TarEntry(info: info, data: nil))
            default:
                entries.append(TarEntry(info: info, data: try Data(contentsOf: itemURL)))
            }
        }

        try walk(url, name: url.lastPathComponent)
        let tarData = TarContainer.create(from: entries)
        return try GzipArchive.archive(data: tarData)
    }
}
