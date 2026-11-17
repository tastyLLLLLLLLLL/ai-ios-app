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
    /// The English prompt the server sent to the model.
    let englishPrompt: String?

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

private struct ServerSettings: Decodable {
    let idleMinutes: Int
}

private struct ErrorResponse: Decodable {
    let error: String
}

enum ServerError: LocalizedError {
    case notConfigured
    case badAddress
    case wrongPassword
    case unreachable
    case slow
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Сервер не подключён. Откройте Модели → Онлайн."
        case .badAddress: return "Неправильный адрес сервера. Он должен начинаться с https://"
        case .wrongPassword: return "Неверный пароль."
        case .unreachable: return "Сервер выключен или не отвечает. Включите его кнопкой в разделе Модели → Онлайн (или на RunPod)."
        case .slow: return "Сервер долго не отвечает — скорее всего, загружает модель. Попробуйте ещё раз через минуту."
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

    enum Power: Equatable {
        case unknown
        case starting
        case stopping
        case off
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
    private(set) var power: Power = .unknown
    /// What the app is doing with the server right now, shown while it starts.
    private(set) var powerNote: String?
    /// Minutes without use after which the server switches itself off (0 = never).
    private(set) var idleMinutes = 10
    /// RunPod account key, needed only to switch a stopped server on. Kept in the keychain.
    private(set) var hasRunPodKey = false

    /// True while the server is loading a model into its graphics card before answering.
    private(set) var modelLoading = false

    /// Called when a job finishes or fails: (job, finished successfully).
    var onJobFinished: ((ServerJob, Bool) -> Void)?

    private var password: String
    private var pollingTask: Task<Void, Never>?

    init() {
        address = UserDefaults.standard.string(forKey: Self.addressKey) ?? ""
        password = Keychain.read() ?? ""
        hasRunPodKey = Keychain.read(account: "runpod") != nil
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

    /// Handles pocketai://connect?address=…&password=… from the QR code printed by the server.
    @discardableResult
    func connect(from url: URL) async -> Bool {
        guard url.scheme == "pocketai", url.host == "connect",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let address = items.first(where: { $0.name == "address" })?.value,
              let password = items.first(where: { $0.name == "password" })?.value else { return false }
        await connect(address: address, password: password)
        return true
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
            power = .unknown
            if let settings: ServerSettings = try? await get("/api/settings") {
                idleMinutes = settings.idleMinutes
            }
            await refreshJobs()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    // MARK: Power

    /// RunPod pod ID, taken from the address https://<pod id>-8080.proxy.runpod.net.
    var podID: String? {
        guard let host = URL(string: address)?.host, host.hasSuffix(".proxy.runpod.net") else { return nil }
        let label = host.components(separatedBy: ".").first ?? ""
        guard let dash = label.lastIndex(of: "-") else { return nil }
        let id = String(label[..<dash])
        return id.isEmpty ? nil : id
    }

    var canStartServer: Bool { hasRunPodKey && podID != nil }

    func saveRunPodKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.delete(account: "runpod")
        } else {
            Keychain.save(trimmed, account: "runpod")
        }
        hasRunPodKey = !trimmed.isEmpty
    }

    func setIdleMinutes(_ minutes: Int) async {
        idleMinutes = minutes
        let _: ServerSettings? = try? await send("/api/settings", method: "POST", body: ["idleMinutes": minutes])
    }

    /// Switches the server off right away (it shuts itself down, so no RunPod key is needed).
    func stopServer() async throws {
        power = .stopping
        do {
            _ = try await sendRaw("/api/shutdown", method: "POST", body: nil)
        } catch {
            if canStartServer {
                try await runPodAction("stop")
            } else {
                power = .unknown
                throw error
            }
        }
        try? await Task.sleep(for: .seconds(4))
        power = .off
        status = .failed("Сервер выключен.")
    }

    /// Switches a stopped server on and waits until it answers.
    func startServer() async throws {
        guard canStartServer else {
            throw ServerError.message("Чтобы включать сервер из приложения, добавьте ключ RunPod в разделе «Онлайн».")
        }
        power = .starting
        powerNote = "Включаю сервер…"
        defer { powerNote = nil }
        do {
            do {
                try await runPodAction("start")
                // The start can be accepted and still fail when the machine's GPU is taken.
                if try await waitForStatus(timeout: 180) == false {
                    try await recreatePod()
                }
            } catch RunPodFailure.gpuUnavailable {
                try await recreatePod()
            }
            powerNote = "Сервер запускается, загружаю программы…"
            try await waitUntilReachable(seconds: 600)
            power = .unknown
            await refresh()
        } catch {
            power = .off
            throw error
        }
    }

    /// Makes sure the server is on before a request: starts it automatically when a RunPod key is saved.
    func ensureRunning() async throws {
        if await isReachable() { return }
        guard canStartServer else { throw ServerError.unreachable }
        try await startServer()
    }

    private func isReachable() async -> Bool {
        guard isConfigured, let url = URL(string: address + "/api/ping") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "GET"
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    private func waitUntilReachable(seconds: Int) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline {
            try Task.checkCancellation()
            if await isReachable() { return }
            try await Task.sleep(for: .seconds(5))
        }
        throw ServerError.message("Сервер включился, но не ответил за 10 минут. Проверьте на RunPod, что он запущен и что в команде запуска стоит bash /workspace/ai-server/autostart.sh.")
    }

    private enum RunPodFailure: Error {
        case gpuUnavailable
    }

    /// Calls the RunPod API with the saved key and returns the status code and body.
    private func runPod(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> (Int, Data) {
        guard let key = Keychain.read(account: "runpod") else { throw ServerError.notConfigured }
        var request = URLRequest(url: URL(string: "https://api.runpod.io/v2" + path)!, timeoutInterval: 45)
        request.httpMethod = method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 {
            throw ServerError.message("RunPod не принял ключ. Создайте новый ключ с правами Read/Write и вставьте его ещё раз.")
        }
        return (code, data)
    }

    private static func mentionsNoGPU(_ text: String) -> Bool {
        ["not enough", "no available", "no instances", "free gpu", "no longer available", "insufficient"]
            .contains { text.localizedCaseInsensitiveContains($0) }
    }

    /// Start or stop through the RunPod API.
    private func runPodAction(_ action: String) async throws {
        guard let pod = podID else { throw ServerError.notConfigured }
        let (code, data) = try await runPod("POST", "/pods/\(pod)/action", body: ["action": action])
        guard (200..<300).contains(code) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            if action == "start", Self.mentionsNoGPU(text) || code == 409 || code == 422 {
                throw RunPodFailure.gpuUnavailable
            }
            throw ServerError.message("RunPod ответил ошибкой \(code). \(text.prefix(200))")
        }
    }

    /// Waits until RunPod reports the pod as running. Returns false if it stopped or failed instead.
    private func waitForStatus(timeout: Int) async throws -> Bool {
        guard let pod = podID else { return false }
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while Date() < deadline {
            try Task.checkCancellation()
            if let (code, data) = try? await runPod("GET", "/pods/\(pod)"), code == 200,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let status = (object["status"] as? String)?.uppercased() {
                if status == "RUNNING" { return true }
                if status == "ERROR" || status == "TERMINATED" { return false }
            }
            try await Task.sleep(for: .seconds(8))
        }
        return false
    }

    /// The machine's GPU is taken: creates a new pod with the same settings on the same network
    /// volume (all models stay), removes the old one and switches the app to the new address.
    private func recreatePod() async throws {
        guard let oldID = podID else { throw ServerError.notConfigured }
        powerNote = "Видеокарта на старой машине занята — создаю новый сервер на вашем диске…"

        let (code, data) = try await runPod("GET", "/pods/\(oldID)")
        guard code == 200, let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServerError.message("Не удалось прочитать настройки сервера на RunPod (код \(code)).")
        }
        let mounts = old["mounts"] as? [String: Any]
        guard let network = (mounts?["network"] as? [[String: Any]])?.first,
              let volumeID = network["volumeId"] as? String else {
            throw ServerError.message("На машине RunPod нет свободной видеокарты, а сервер не на сетевом диске, поэтому пересоздать его автоматически нельзя. Попробуйте позже или перенесите сервер на Network Volume.")
        }
        let path = network["path"] as? String ?? "/workspace"
        let image = old["image"] as? String ?? "runpod/pytorch:2.1.0-cu1320-torch280-ubuntu2404"
        let disk = old["disk"] as? Int ?? 50
        var ports = old["ports"] as? [String] ?? []
        for port in ["8080/http", "22/tcp"] where !ports.contains(port) { ports.append(port) }
        let oldGPU = (old["gpu"] as? [String: Any])?["id"] as? String
        let dataCenter = old["dataCenterId"] as? String
        let env = old["env"] as? [String: Any] ?? [:]

        // The old card first, then other cards that fit the models, cheapest first.
        var candidates = [oldGPU].compactMap { $0 }
        for gpu in ["NVIDIA A40", "NVIDIA RTX A6000", "NVIDIA L40S", "NVIDIA RTX PRO 4500 Blackwell",
                    "NVIDIA RTX 6000 Ada Generation", "NVIDIA L40", "NVIDIA GeForce RTX 5090"]
            where !candidates.contains(gpu) {
            candidates.append(gpu)
        }

        var lastError = ""
        for gpu in candidates {
            var body: [String: Any] = [
                "name": old["name"] as? String ?? "ai-server",
                "image": image,
                "gpu": ["id": gpu, "count": 1],
                "disk": disk,
                "mounts": ["network": [["volumeId": volumeID, "path": path]]],
                "ports": ports,
                "args": "bash /workspace/ai-server/autostart.sh",
                "cloud": "SECURE",
                "env": env
            ]
            if let dataCenter { body["dataCenterIds"] = [dataCenter] }
            let (createCode, created) = try await runPod("POST", "/pods", body: body)
            guard (200..<300).contains(createCode),
                  let pod = try? JSONSerialization.jsonObject(with: created) as? [String: Any],
                  let newID = pod["id"] as? String else {
                lastError = String((String(data: created, encoding: .utf8) ?? "").prefix(200))
                continue
            }
            _ = try? await runPod("DELETE", "/pods/\(oldID)")
            address = "https://\(newID)-8080.proxy.runpod.net"
            UserDefaults.standard.set(address, forKey: Self.addressKey)
            powerNote = "Новый сервер создан. Он запускается — первый раз это до 5–10 минут…"
            return
        }
        throw ServerError.message("Сейчас в дата-центре вашего диска нет свободных подходящих видеокарт. Попробуйте через 10–30 минут.\n\nОтвет RunPod: \(lastError)")
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
                    defer { self.modelLoading = false }
                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let error = object["error"] as? String {
                            throw ServerError.message(error)
                        }
                        if object["status"] as? String == "loading" {
                            self.modelLoading = true
                            continue
                        }
                        self.modelLoading = false
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
        try await ensureRunning()
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
            switch (error as NSError).code {
            case NSURLErrorCancelled: return CancellationError()
            case NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost: return ServerError.slow
            default: return ServerError.unreachable
            }
        }
        return error
    }
}

// MARK: - Keychain

/// Keeps the server password in the iPhone keychain rather than in plain settings.
private enum Keychain {
    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "PocketAI.server",
            kSecAttrAccount as String: account
        ]
    }

    static func save(_ value: String, account: String = "password") {
        delete(account: account)
        var item = query(account)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    static func read(account: String = "password") -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String = "password") {
        SecItemDelete(query(account) as CFDictionary)
    }
}
