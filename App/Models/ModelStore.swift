import Foundation
import Observation

struct DownloadProgress: Equatable {
    var received: Int64
    var total: Int64

    var fraction: Double {
        total > 0 ? min(1, Double(received) / Double(total)) : 0
    }
}

enum UncensoredState: Equatable {
    /// The selected model has no uncensored variant (for example, an imported file).
    case unavailable
    case notDownloaded
    case downloading(DownloadProgress)
    case ready
}

/// Keeps track of model files on disk, running downloads and the selected model.
@MainActor
@Observable
final class ModelStore {
    private static let selectedKey = "selectedModelFile"

    /// Every .gguf file in the models folder, including vision modules and uncensored variants.
    private(set) var files: Set<String> = []
    /// Models the user can pick: catalog models and imported files.
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

    // MARK: - Lookup

    var selectedCatalogModel: CatalogModel? {
        selectedFile.flatMap { ModelCatalog.model(forFile: $0) }
    }

    /// Models that are not in the built-in catalog: imported, downloading by link, or failed.
    var customEntries: [String] {
        let names = Set(installed).union(downloads.keys).union(errors.keys)
        return names.filter { !Self.isCatalogFile($0) }.sorted()
    }

    private static func isCatalogFile(_ fileName: String) -> Bool {
        ModelCatalog.model(forFile: fileName) != nil || isCompanion(fileName)
    }

    private static func isCompanion(_ fileName: String) -> Bool {
        ModelCatalog.companionFileNames.contains(fileName) || fileName.lowercased().hasPrefix("mmproj")
    }

    func path(for fileName: String) -> String {
        Downloader.modelsDirectory.appendingPathComponent(fileName).path
    }

    func sizeLabel(for fileName: String) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path(for: fileName))
        let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// The file that should actually be loaded: the uncensored variant when asked for and available.
    func activeFile(uncensored: Bool) -> String? {
        guard let selectedFile else { return nil }
        if uncensored, let variant = selectedCatalogModel?.uncensored, files.contains(variant.fileName) {
            return variant.fileName
        }
        return selectedFile
    }

    /// Path of the vision module for the selected model, if it is on the device.
    var visionPath: String? {
        guard let vision = selectedCatalogModel?.vision, files.contains(vision.fileName) else { return nil }
        return path(for: vision.fileName)
    }

    var canSeePhotos: Bool { visionPath != nil }

    var uncensoredState: UncensoredState {
        guard let variant = selectedCatalogModel?.uncensored else { return .unavailable }
        if files.contains(variant.fileName) { return .ready }
        if let progress = downloads[variant.fileName] { return .downloading(progress) }
        return .notDownloaded
    }

    /// Combined progress of a catalog model and its vision module.
    func progress(for model: CatalogModel) -> DownloadProgress? {
        let active = [model.fileName, model.vision?.fileName].compactMap { $0 }.compactMap { downloads[$0] }
        guard !active.isEmpty else { return nil }
        if active.contains(where: { $0.total <= 0 }) {
            return DownloadProgress(received: 0, total: 0)
        }
        return DownloadProgress(
            received: active.reduce(0) { $0 + $1.received },
            total: active.reduce(0) { $0 + $1.total }
        )
    }

    func error(for model: CatalogModel) -> String? {
        [model.fileName, model.vision?.fileName, model.uncensored?.fileName]
            .compactMap { $0 }
            .compactMap { errors[$0] }
            .first
    }

    func needsVisionDownload(_ model: CatalogModel) -> Bool {
        guard let vision = model.vision else { return false }
        return files.contains(model.fileName) && !files.contains(vision.fileName) && downloads[vision.fileName] == nil
    }

    // MARK: - Changes

    func refresh() {
        let found = (try? FileManager.default.contentsOfDirectory(atPath: Downloader.modelsDirectory.path)) ?? []
        files = Set(found.filter { $0.lowercased().hasSuffix(".gguf") })
        installed = files.filter { !Self.isCompanion($0) }.sorted()
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
        if let vision = model.vision {
            download(url: vision.url, fileName: vision.fileName)
        }
    }

    func downloadVision(for model: CatalogModel) {
        guard let vision = model.vision else { return }
        download(url: vision.url, fileName: vision.fileName)
    }

    func downloadUncensoredVariant() {
        guard let variant = selectedCatalogModel?.uncensored else { return }
        download(url: variant.url, fileName: variant.fileName)
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
        guard downloads[fileName] == nil, !files.contains(fileName) else { return }
        errors[fileName] = nil
        downloads[fileName] = DownloadProgress(received: 0, total: 0)
        Downloader.shared.start(url: url, fileName: fileName)
    }

    func cancelDownload(_ fileName: String) {
        Downloader.shared.cancel(fileName: fileName)
        downloads[fileName] = nil
    }

    func cancelDownload(_ model: CatalogModel) {
        cancelDownload(model.fileName)
        if let vision = model.vision { cancelDownload(vision.fileName) }
    }

    func cancelUncensoredDownload() {
        if let variant = selectedCatalogModel?.uncensored { cancelDownload(variant.fileName) }
    }

    /// Deletes a model together with its vision module and uncensored variant.
    func delete(_ fileName: String) {
        var names = [fileName]
        if let model = ModelCatalog.model(forFile: fileName) {
            names += [model.vision?.fileName, model.uncensored?.fileName].compactMap { $0 }
        }
        for name in names {
            try? FileManager.default.removeItem(atPath: path(for: name))
        }
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
