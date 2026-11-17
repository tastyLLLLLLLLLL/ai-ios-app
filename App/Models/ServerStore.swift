import Foundation
import Observation
import Security
import UIKit

// MARK: - Types from the server

struct OnlineModel: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let category: String
    let summary: String
    let uncensored: Bool
}

struct MediaModel: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let kind: String
    let summary: String
}

enum MediaKind: String, CaseIterable, Identifiable {
    case image
    case video
    case music

    var id: String { rawValue }

    var title: String {
        switch self {
        case .image: return "Картинки"
        case .video: return "Видео"
        case .music: return "Музыка"
        }
    }

    var icon: String {
        switch self {
        case .image: return "photo.fill"
        case .video: return "film.fill"
        case .music: return "music.note"
        }
    }
}

struct JobOutput: Codable, Hashable {
    let filename: String
    let subfolder: String

    var fileExtension: String { (filename as NSString).pathExtension.lowercased() }
}

struct ServerJob: Identifiable, Codable, Hashable {
    let id: String
    let kind: String
    let model: String
    let modelName: String
    let prompt: String
    let status: String
    let progress: Double
    let created: Double
    let finished: Double?
    let outputs: [JobOutput]
    let error: String?

    var isActive: Bool { status == "queued" || status == "running" }
    var createdDate: Date { Date(timeIntervalSince1970: created) }
}

private struct ModelsResponse: Decodable {
    let text: [OnlineModel]
    let media: [MediaModel]
}

private struct HealthResponse: Decodable {
    let gpu: String
    let ntfyTopic: String
}

private struct ErrorResponse: Decodable {
    let error: String
}

enum ServerError: LocalizedError {
    case notConfigured
    case badAddress
    case wrongPassword
    case unreachable
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Сервер не подключён. Откройте Модели → Онлайн."
        case .badAddress: return "Неправильный адрес сервера. Он должен начинаться с https://"
        case .wrongPassword: return "Неверный пароль."
        case .unreachable: return "Сервер не отвечает. Запустите его на RunPod и выполните bash /workspace/ai-server/start.sh"
        case .message(let text): return text
        }
    }
}

/// One piece of a streamed chat answer.
struct ChatChunk {
    var thinking = ""
    var content = ""
}

// MARK: - Store

/// Connection to the user's own server: text models, and image, video and music jobs.
@MainActor
@Observable
final class ServerStore {
    enum Status: Equatable {
        case disconnected
        case checking
        case connected
        case failed(String)
    }

    private static let addressKey = "serverAddress"
    private static let modelKey = "serverTextModel"

    private(set) var address: String
    private(set) var status: Status = .disconnected
    private(set) var gpu = ""
    private(set) var ntfyTopic = ""
    private(set) var textModels: [OnlineModel] = []
    private(set) var mediaModels: [MediaModel] = []
    private(set) var jobs: [ServerJob] = []
    private(set) var selectedTextModelID: String?

    /// Called when a job finishes or fails: (job, finished successfully).
    var onJobFinished: ((ServerJob, Bool) -> Void)?

    private var password: String
    private var pollingTask: Task<Void, Never>?

    init() {
        address = UserDefaults.standard.string(forKey: Self.addressKey) ?? ""
        password = Keychain.read() ?? ""
        selectedTextModelID = UserDefaults.standard.string(forKey: Self.modelKey)
        if isConfigured {
            Task { await refresh() }
        }
    }

    var isConfigured: Bool { !address.isEmpty && !password.isEmpty }
    var isConnected: Bool { status == .connected }

    var selectedTextModel: OnlineModel? {
        textModels.first { $0.id == selectedTextModelID }
    }

    func media(of kind: MediaKind) -> [MediaModel] {
        mediaModels.filter { $0.kind == kind.rawValue }
    }

    func jobs(of kind: MediaKind) -> [ServerJob] {
        jobs.filter { $0.kind == kind.rawValue }
    }

    // MARK: Connection

    func connect(address rawAddress: String, password newPassword: String) async {
        var cleaned = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasSuffix("/") { cleaned.removeLast() }
        if !cleaned.hasPrefix("http") { cleaned = "https://" + cleaned }
        address = cleaned
        password = newPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(address, forKey: Self.addressKey)
        Keychain.save(password)
        await refresh()
    }

    func disconnect() {
        pollingTask?.cancel()
        address = ""
        password = ""
        textModels = []
        mediaModels = []
        jobs = []
        status = .disconnected
        UserDefaults.standard.removeObject(forKey: Self.addressKey)
        Keychain.delete()
    }

    /// Checks the connection and reloads the model list.
    func refresh() async {
        guard isConfigured else {
            status = .disconnected
            return
        }
        status = .checking
        do {
            let health: HealthResponse = try await get("/api/health")
            let models: ModelsResponse = try await get("/api/models")
            gpu = health.gpu
            ntfyTopic = health.ntfyTopic
            textModels = models.text
            mediaModels = models.media
            if selectedTextModelID == nil || !textModels.contains(where: { $0.id == selectedTextModelID }) {
                selectedTextModelID = textModels.first?.id
            }
            status = .connected
            await refreshJobs()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func selectTextModel(_ id: String) {
        selectedTextModelID = id
        UserDefaults.standard.set(id, forKey: Self.modelKey)
    }

    // MARK: Chat

    func chat(
        model: String,
        messages: [[String: String]],
        think: Bool,
        temperature: Double,
        maxTokens: Int
    ) -> AsyncThrowingStream<ChatChunk, Error> {
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "think": think,
            "options": ["temperature": temperature, "num_predict": maxTokens, "num_ctx": 8192]
        ]
        let request = try? makeRequest("/api/chat", method: "POST", body: body, timeout: 600)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let request else { throw ServerError.notConfigured }
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    try Self.check(response)
                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let error = object["error"] as? String {
                            throw ServerError.message(error)
                        }
                        let message = object["message"] as? [String: Any]
                        let chunk = ChatChunk(
                            thinking: message?["thinking"] as? String ?? "",
                            content: message?["content"] as? String ?? ""
                        )
                        if !chunk.thinking.isEmpty || !chunk.content.isEmpty {
                            continuation.yield(chunk)
                        }
                        if object["done"] as? Bool == true { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.friendly(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Jobs

    func createJob(kind: MediaKind, model: String, prompt: String, options: [String: Any]) async throws {
        var body = options
        body["kind"] = kind.rawValue
        body["model"] = model
        body["prompt"] = prompt
        let job: ServerJob = try await send("/api/jobs", method: "POST", body: body)
        jobs.insert(job, at: 0)
        startPolling()
    }

    func deleteJob(_ job: ServerJob) async {
        jobs.removeAll { $0.id == job.id }
        _ = try? await sendRaw("/api/jobs/\(job.id)", method: "DELETE", body: nil)
        for index in job.outputs.indices {
            try? FileManager.default.removeItem(at: localURL(for: job, index: index))
        }
    }

    func refreshJobs() async {
        guard isConfigured, let fresh: [ServerJob] = try? await get("/api/jobs") else { return }
        let previous = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
        jobs = fresh
        for job in fresh {
            if let old = previous[job.id], old.isActive, !job.isActive {
                onJobFinished?(job, job.status == "done")
            }
        }
        if fresh.contains(where: \.isActive) { startPolling() }
    }

    /// Checks jobs every few seconds while any of them is still being made.
    func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                await self.refreshJobs()
                if !self.jobs.contains(where: \.isActive) { break }
            }
            self?.pollingTask = nil
        }
    }

    /// Where a finished file is kept on the phone.
    func localURL(for job: ServerJob, index: Int) -> URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Studio", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = job.outputs.indices.contains(index) ? job.outputs[index].fileExtension : "bin"
        return directory.appendingPathComponent("\(job.id)-\(index).\(ext)")
    }

    /// Downloads a finished file once and returns its local copy.
    func file(for job: ServerJob, index: Int) async throws -> URL {
        let local = localURL(for: job, index: index)
        if FileManager.default.fileExists(atPath: local.path) { return local }
        let request = try makeRequest("/api/jobs/\(job.id)/files/\(index)", method: "GET", body: nil, timeout: 300)
        let (temporary, response) = try await URLSession.shared.download(for: request)
        try Self.check(response)
        try? FileManager.default.removeItem(at: local)
        try FileManager.default.moveItem(at: temporary, to: local)
        return local
    }

    // MARK: HTTP

    private func makeRequest(_ path: String, method: String, body: [String: Any]?, timeout: TimeInterval = 30) throws -> URLRequest {
        guard isConfigured else { throw ServerError.notConfigured }
        guard let url = URL(string: address + path), url.scheme?.hasPrefix("http") == true else {
            throw ServerError.badAddress
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(password)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private func sendRaw(_ path: String, method: String, body: [String: Any]?) async throws -> Data {
        let request = try makeRequest(path, method: method, body: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.check(response, data: data)
            return data
        } catch {
            throw Self.friendly(error)
        }
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await sendRaw(path, method: "GET", body: nil))
    }

    private func send<T: Decodable>(_ path: String, method: String, body: [String: Any]) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await sendRaw(path, method: method, body: body))
    }

    private static func check(_ response: URLResponse, data: Data? = nil) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 { throw ServerError.wrongPassword }
        guard (200..<300).contains(http.statusCode) else {
            if let data, let error = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw ServerError.message(error.error)
            }
            // RunPod answers 502/404 while the pod or the gateway is not running.
            throw ServerError.unreachable
        }
    }

    private static func friendly(_ error: Error) -> Error {
        if error is ServerError { return error }
        if (error as NSError).domain == NSURLErrorDomain {
            if (error as NSError).code == NSURLErrorCancelled { return CancellationError() }
            return ServerError.unreachable
        }
        return error
    }
}

// MARK: - Keychain

/// Keeps the server password in the iPhone keychain rather than in plain settings.
private enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "PocketAI.server",
        kSecAttrAccount as String: "password"
    ]

    static func save(_ value: String) {
        delete()
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    static func read() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
