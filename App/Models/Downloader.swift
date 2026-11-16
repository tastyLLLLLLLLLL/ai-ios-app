import Foundation

/// Downloads model files with a background URLSession, so a multi-gigabyte download
/// keeps going while the app is minimised or the screen is locked.
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = Downloader()

    /// (file name, bytes received, bytes expected)
    var onProgress: (@Sendable (String, Int64, Int64) -> Void)?
    /// (file name, error message or nil on success)
    var onFinish: (@Sendable (String, String?) -> Void)?

    private let lock = NSLock()
    private var failures: [String: String] = [:]
    private var lastReport: [String: Date] = [:]

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: "pocketai.model-downloads")
        configuration.isDiscretionary = false
        configuration.allowsCellularAccess = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    static var modelsDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var directory = documents.appendingPathComponent("Models", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)
        }
        return directory
    }

    func start(url: URL, fileName: String) {
        let task = session.downloadTask(with: url)
        task.taskDescription = fileName
        task.resume()
    }

    func cancel(fileName: String) {
        session.getAllTasks { tasks in
            for task in tasks where task.taskDescription == fileName {
                task.cancel()
            }
        }
    }

    /// File names of downloads that are still running (for example after the app was restarted).
    func activeFileNames() async -> [String] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: tasks.compactMap { $0.taskDescription })
            }
        }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let fileName = downloadTask.taskDescription else { return }
        let now = Date()
        lock.lock()
        let last = lastReport[fileName] ?? .distantPast
        let shouldReport = now.timeIntervalSince(last) > 0.25
        if shouldReport { lastReport[fileName] = now }
        lock.unlock()
        if shouldReport {
            onProgress?(fileName, totalBytesWritten, totalBytesExpectedToWrite)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let fileName = downloadTask.taskDescription else { return }

        if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            setFailure("Сервер ответил ошибкой \(response.statusCode). Проверьте ссылку.", for: fileName)
            return
        }

        let destination = Self.modelsDirectory.appendingPathComponent(fileName)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            setFailure("Не удалось сохранить файл: \(error.localizedDescription)", for: fileName)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let fileName = task.taskDescription else { return }

        lock.lock()
        var message = failures.removeValue(forKey: fileName)
        lastReport.removeValue(forKey: fileName)
        lock.unlock()

        if let error {
            if (error as NSError).code == NSURLErrorCancelled {
                message = "cancelled"
            } else if message == nil {
                message = error.localizedDescription
            }
        }
        onFinish?(fileName, message)
    }

    private func setFailure(_ message: String, for fileName: String) {
        lock.lock()
        failures[fileName] = message
        lock.unlock()
    }
}
