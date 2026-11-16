import Foundation
import Observation

struct DownloadProgress: Equatable {
    var received: Int64
    var total: Int64

    var fraction: Double {
        total > 0 ? min(1, Double(received) / Double(total)) : 0
    }
}

/// Keeps track of model files on disk, running downloads and the selected model.
@MainActor
@Observable
final class ModelStore {
    private static let selectedKey = "selectedModelFile"

    private(set) var installed: [String] = []
    private(set) var downloads: [String: DownloadProgress] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var selectedFile: String?
    private(set) var isImporting = false

    init() {
        selectedFile = UserDefaults.standard.string(forKey: Self.selectedKey)
        refresh()

        Downloader.shared.onProgress = { [weak self] fileName, received, total in
            Task { @MainActor in
                guard let self, self.downloads[fileName] != nil else { return }
                self.downloads[fileName] = DownloadProgress(received: received, total: total)
            }
        }
        Downloader.shared.onFinish = { [weak self] fileName, message in
            Task { @MainActor in
                self?.finished(fileName: fileName, message: message)
            }
        }
        Task {
            for fileName in await Downloader.shared.activeFileNames() where downloads[fileName] == nil {
                downloads[fileName] = DownloadProgress(received: 0, total: 0)
            }
        }
    }

    var customFiles: [String] {
        installed.filter { ModelCatalog.model(forFile: $0) == nil }
    }

    /// Models that are not in the built-in catalog: imported, downloading by link, or failed.
    var customEntries: [String] {
        let names = Set(installed).union(downloads.keys).union(errors.keys)
        return names.filter { ModelCatalog.model(forFile: $0) == nil }.sorted()
    }

    func path(for fileName: String) -> String {
        Downloader.modelsDirectory.appendingPathComponent(fileName).path
    }

    func sizeLabel(for fileName: String) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path(for: fileName))
        let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Downloader.modelsDirectory.path)) ?? []
        installed = files.filter { $0.lowercased().hasSuffix(".gguf") }.sorted()
        if let selectedFile, !installed.contains(selectedFile) {
            select(installed.first)
        } else if selectedFile == nil, let first = installed.first {
            select(first)
        }
    }

    func select(_ fileName: String?) {
        selectedFile = fileName
        UserDefaults.standard.set(fileName, forKey: Self.selectedKey)
    }

    func download(_ model: CatalogModel) {
        download(url: model.url, fileName: model.fileName)
    }

    /// Starts a download from a direct link to a .gguf file. Returns false if the link is not usable.
    @discardableResult
    func download(link: String) -> Bool {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "https" || url.scheme == "http" else { return false }
        let fileName = url.lastPathComponent
        guard fileName.lowercased().hasSuffix(".gguf") else { return false }
        download(url: url, fileName: fileName)
        return true
    }

    private func download(url: URL, fileName: String) {
        guard downloads[fileName] == nil, !installed.contains(fileName) else { return }
        errors[fileName] = nil
        downloads[fileName] = DownloadProgress(received: 0, total: 0)
        Downloader.shared.start(url: url, fileName: fileName)
    }

    func cancelDownload(_ fileName: String) {
        Downloader.shared.cancel(fileName: fileName)
        downloads[fileName] = nil
    }

    func delete(_ fileName: String) {
        try? FileManager.default.removeItem(atPath: path(for: fileName))
        refresh()
    }

    func importFile(from source: URL) {
        let destination = Downloader.modelsDirectory.appendingPathComponent(source.lastPathComponent)
        isImporting = true
        Task.detached(priority: .userInitiated) {
            let scoped = source.startAccessingSecurityScopedResource()
            var message: String?
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: source, to: destination)
            } catch {
                message = error.localizedDescription
            }
            if scoped { source.stopAccessingSecurityScopedResource() }
            let failure = message
            await MainActor.run {
                self.isImporting = false
                self.errors[source.lastPathComponent] = failure
                self.refresh()
            }
        }
    }

    func clearError(_ fileName: String) {
        errors[fileName] = nil
    }

    private func finished(fileName: String, message: String?) {
        downloads[fileName] = nil
        if let message, message != "cancelled" {
            errors[fileName] = message
        }
        refresh()
    }
}
