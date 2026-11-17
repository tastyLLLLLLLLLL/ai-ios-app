import Foundation
import Observation
import SwiftUI
import UIKit

enum EngineState: Equatable {
    case idle
    case loading
    case ready
    case failed(String)
}

/// Central app state: conversations, settings and the running model.
@MainActor
@Observable
final class AppModel {
    var conversations: [Conversation] = []
    var currentID: UUID?
    var settings = AppSettings.load()
    private(set) var engineState: EngineState = .idle
    private(set) var isGenerating = false

    let models = ModelStore()
    let server = ServerStore()
    /// True when chats go to a model on the user's server instead of the phone.
    private(set) var useOnline = UserDefaults.standard.bool(forKey: "useOnlineModel")

    private let engine = LlamaEngine()
    private var loadedFile: String?
    private var loadedContextSize = 0
    /// False after the model was reloaded for the processor to keep working in the background.
    private var loadedOnGPU = true
    /// Set while an answer is moved from the graphics chip to the processor.
    private var switchingProcessor = false
    /// Tokens written for the current answer, across pauses; drives the lock-screen progress.
    private var answerTokens = 0
    private var template = ChatTemplate.chatML
    private var supportsThinking = false
    private var loadedVisionPath: String?
    private var canSeeImages = false
    private var generationTask: Task<Void, Never>?
    /// Chat whose answer is being written.
    private var generatingConversationID: UUID?
    /// Chat whose answer was paused because the app went to the background.
    private var pausedConversationID: UUID?
    private static let pausedNotificationID = "answer-paused"

    private static var storageURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chats.json")
    }

    init() {
        models.onDownloadFinished = { [weak self] fileName, error in
            self?.notifyDownload(fileName: fileName, error: error)
        }
        settings.applyDisplay()
        server.onJobFinished = { [weak self] job, success in
            self?.notifyJob(job, success: success)
        }
        BackgroundAnswer.shared.onExpire = { [weak self] in
            self?.backgroundTimeExpired()
        }
        if let data = try? Data(contentsOf: Self.storageURL),
           let saved = try? JSONDecoder().decode([Conversation].self, from: data) {
            conversations = saved
        }
    }

    // MARK: - Conversations

    var current: Conversation? {
        conversations.first { $0.id == currentID }
    }

    var sortedConversations: [Conversation] {
        conversations.filter { !$0.messages.isEmpty }.sorted { $0.updated > $1.updated }
    }

    var activeModelName: String {
        if useOnline {
            return server.selectedTextModel?.name ?? "Сервер"
        }
        guard let file = models.selectedFile else { return "Нет модели" }
        return ModelCatalog.displayName(forFile: file)
    }

    /// A model is chosen and chatting is possible.
    var hasActiveModel: Bool {
        useOnline ? server.selectedTextModelID != nil : models.selectedFile != nil
    }

    func chooseOnline(_ id: String) {
        server.selectTextModel(id)
        useOnline = true
        UserDefaults.standard.set(true, forKey: "useOnlineModel")
    }

    func chooseOffline(_ file: String) {
        models.select(file)
        useOnline = false
        UserDefaults.standard.set(false, forKey: "useOnlineModel")
    }

    /// Switches back to a model on the phone, if one is downloaded.
    func chooseOfflineIfPossible() {
        useOnline = false
        UserDefaults.standard.set(false, forKey: "useOnlineModel")
    }

    private func notifyJob(_ job: ServerJob, success: Bool) {
        guard settings.notificationsEnabled, UIApplication.shared.applicationState != .active else { return }
        let title: String
        switch job.kind {
        case "image": title = success ? "Картинка готова" : "Картинка не получилась"
        case "video": title = success ? "Видео готово" : "Видео не получилось"
        default: title = success ? "Музыка готова" : "Музыка не получилась"
        }
        NotificationService.shared.post(title: title, body: String(job.prompt.prefix(120)))
    }

    func newChat() {
        stop()
        currentID = nil
    }

    func open(_ id: UUID) {
        stop()
        currentID = id
    }

    func delete(_ id: UUID) {
        if currentID == id { newChat() }
        if let conversation = conversations.first(where: { $0.id == id }) {
            ImageStore.delete(conversation.messages.flatMap(\.imageNames))
        }
        conversations.removeAll { $0.id == id }
        save()
    }

    func deleteAllChats() {
        newChat()
        ImageStore.delete(conversations.flatMap { $0.messages.flatMap(\.imageNames) })
        conversations = []
        save()
    }

    /// True when the uncensored variant of the selected model is in use.
    var isUncensoredActive: Bool {
        settings.uncensored && models.uncensoredState == .ready
    }

    private func save() {
        let snapshot = conversations.filter { !$0.messages.isEmpty }
        let url = Self.storageURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: - Generation

    func send(_ text: String, photos: [UIImage] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageNames = photos.compactMap { ImageStore.save($0) }
        guard !trimmed.isEmpty || !imageNames.isEmpty, !isGenerating, hasActiveModel else {
            ImageStore.delete(imageNames)
            return
        }
        let text = trimmed.isEmpty ? "Что на этой фотографии?" : trimmed

        if current == nil {
            let conversation = Conversation()
            conversations.append(conversation)
            currentID = conversation.id
        }
        guard let index = conversations.firstIndex(where: { $0.id == currentID }) else { return }

        if conversations[index].title.isEmpty {
            let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
            conversations[index].title = String(firstLine.prefix(48))
        }
        var userMessage = ChatMessage(role: .user, text: text)
        if !imageNames.isEmpty { userMessage.images = imageNames }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            conversations[index].messages.append(userMessage)
            conversations[index].messages.append(ChatMessage(role: .assistant, text: ""))
        }
        conversations[index].updated = Date()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        generate(in: conversations[index].id)
    }

    func regenerate() {
        guard !isGenerating, hasActiveModel,
              let index = conversations.firstIndex(where: { $0.id == currentID }),
              let last = conversations[index].messages.last, last.role == .assistant else { return }
        conversations[index].messages[conversations[index].messages.count - 1] = ChatMessage(role: .assistant, text: "")
        generate(in: conversations[index].id)
    }

    func stop() {
        pausedConversationID = nil
        generationTask?.cancel()
        engine.cancelAll()
    }

    // MARK: - Background

    /// iOS does not let the model use the graphics chip in the background, so the answer is paused
    /// and continued when the user comes back.
    func handleBackground() {
        guard isGenerating, let id = generatingConversationID else { return }
        if useOnline, BackgroundAnswer.shared.isRunning {
            // The server keeps writing; iOS lets the connection run while the background task lasts.
            return
        }
        if !useOnline, BackgroundAnswer.shared.isRunning {
            continueOnProcessor(id)
        } else {
            pause(id, reason: "iPhone не даёт нейросети работать в фоне. Откройте приложение — ответ допишется сам.")
        }
    }

    private func pause(_ id: UUID, reason: String) {
        stop()
        pausedConversationID = id
        if settings.notificationsEnabled {
            NotificationService.shared.post(id: Self.pausedNotificationID, title: "Ответ на паузе", body: reason)
        }
    }

    /// The graphics chip is off limits in the background, so the model is reloaded for the processor
    /// and the answer continues from where it stopped (slower, but without opening the app).
    private func continueOnProcessor(_ id: UUID) {
        switchingProcessor = true
        let previous = generationTask
        generationTask?.cancel()
        engine.cancelAll()
        Task {
            await previous?.value
            switchingProcessor = false
            guard BackgroundAnswer.shared.isRunning else {
                pause(id, reason: "iOS не дал времени на работу в фоне. Откройте приложение — ответ допишется сам.")
                return
            }
            generate(in: id, resume: true, onProcessor: true)
        }
    }

    private func backgroundTimeExpired() {
        guard isGenerating, let id = generatingConversationID else { return }
        pause(id, reason: "iOS остановил работу в фоне. Откройте приложение — ответ допишется сам.")
    }

    func handleForeground() {
        NotificationService.shared.remove(id: Self.pausedNotificationID)
        guard let id = pausedConversationID else { return }
        pausedConversationID = nil
        let previous = generationTask
        Task {
            await previous?.value
            guard !isGenerating,
                  let conversation = conversations.first(where: { $0.id == id }),
                  conversation.messages.last?.role == .assistant else { return }
            generate(in: id, resume: true)
        }
    }

    private func notifyDownload(fileName: String, error: String?) {
        guard settings.notificationsEnabled else { return }
        let name = models.describe(fileName: fileName)
        if let error {
            NotificationService.shared.post(title: "Не удалось скачать", body: "\(name): \(error)")
        } else {
            NotificationService.shared.post(title: "Скачано", body: "\(name) готова к работе без интернета.")
        }
    }

    // MARK: - Generation

    /// - Parameter resume: continue the unfinished last answer instead of starting it over.
    /// - Parameter onProcessor: load the model for the processor, which iOS allows in the background.
    private func generate(in conversationID: UUID, resume: Bool = false, onProcessor: Bool = false) {
        if !resume {
            answerTokens = 0
            if settings.backgroundAnswers, BackgroundAnswer.isSupported {
                let title = conversations.first(where: { $0.id == conversationID })?.displayTitle ?? "Новый чат"
                BackgroundAnswer.shared.begin(
                    title: "Pocket AI пишет ответ",
                    subtitle: title,
                    totalUnits: settings.maxResponseTokens
                )
            }
        }
        isGenerating = true
        generatingConversationID = conversationID
        MotionStore.shared.paused = settings.pauseMotionWhileAnswering
        // Keeps the screen on while the model writes, so the phone does not lock and pause it.
        UIApplication.shared.isIdleTimerDisabled = true
        generationTask = Task {
            let started = Date()
            do {
                if useOnline {
                    try await streamOnline(conversationID, resume: resume)
                } else {
                try await ensureModelLoaded(useGPU: !onProcessor)
                let (builtPrompt, images, prefill) = try await buildPrompt(for: conversationID)
                var prompt = builtPrompt
                if resume {
                    let partial = conversations.first(where: { $0.id == conversationID })?.messages.last?.text ?? ""
                    prompt += partial
                } else if !prefill.isEmpty {
                    updateLastMessage(in: conversationID) { $0.text = prefill }
                }
                let options = GenerationOptions(
                    temperature: Float(settings.temperature),
                    maxTokens: settings.maxResponseTokens
                )
                var pieces = 0
                // Tokens are shown in small batches: redrawing the screen for each one wastes time.
                var pending = ""
                var lastFlush = Date.distantPast
                for try await piece in engine.generate(prompt: prompt, images: images, options: options) {
                    pieces += 1
                    answerTokens += 1
                    pending += piece
                    if Date().timeIntervalSince(lastFlush) >= 0.06 {
                        let chunk = pending
                        pending = ""
                        lastFlush = Date()
                        updateLastMessage(in: conversationID) { $0.text += chunk }
                        BackgroundAnswer.shared.report(completedUnits: answerTokens)
                    }
                }
                if !pending.isEmpty {
                    let chunk = pending
                    updateLastMessage(in: conversationID) { $0.text += chunk }
                }
                let elapsed = Date().timeIntervalSince(started)
                if pieces > 1, elapsed > 0 {
                    updateLastMessage(in: conversationID) { $0.tokensPerSecond = Double(pieces) / elapsed }
                }
                }
            } catch is CancellationError {
                // Stopped by the user.
            } catch {
                updateLastMessage(in: conversationID) { message in
                    if message.text.isEmpty {
                        message.text = error.localizedDescription
                        message.isError = true
                    }
                }
            }
            isGenerating = false
            generatingConversationID = nil
            save()
            // While switching to the processor the answer is not over yet.
            guard !switchingProcessor else { return }
            MotionStore.shared.paused = false
            UIApplication.shared.isIdleTimerDisabled = false
            BackgroundAnswer.shared.finish(success: true)
            finishNotice(for: conversationID, startedAt: started)
        }
    }

    /// Streams an answer from a text model on the user's server.
    private func streamOnline(_ conversationID: UUID, resume: Bool) async throws {
        guard let modelID = server.selectedTextModelID else { throw ServerError.notConfigured }
        if resume {
            // The server cannot continue a half-written answer, so it starts over.
            updateLastMessage(in: conversationID) { $0.text = "" }
        }
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return }

        var system = settings.systemPrompt
        if settings.uncensored {
            system = AppSettings.uncensoredInstruction + "\n\n" + system
        }
        var messages: [[String: String]] = [["role": "system", "content": system]]
        for message in conversation.messages.dropLast().suffix(40) where !message.isError {
            let text = message.role == .user ? message.text : message.answer
            guard !text.isEmpty else { continue }
            messages.append(["role": message.role == .user ? "user" : "assistant", "content": text])
        }

        let started = Date()
        var pieces = 0
        var inThinking = false
        var pending = ""
        var lastFlush = Date.distantPast
        let stream = server.chat(
            model: modelID,
            messages: messages,
            think: settings.thinkingEnabled,
            temperature: settings.temperature,
            maxTokens: settings.maxResponseTokens
        )
        for try await chunk in stream {
            // Reasoning is wrapped in <think> tags so the chat shows it folded, as for models on the phone.
            if !chunk.thinking.isEmpty {
                if !inThinking {
                    pending += "<think>"
                    inThinking = true
                }
                pending += chunk.thinking
            }
            if !chunk.content.isEmpty {
                if inThinking {
                    pending += "</think>\n\n"
                    inThinking = false
                }
                pending += chunk.content
            }
            pieces += 1
            answerTokens += 1
            if Date().timeIntervalSince(lastFlush) >= 0.06 {
                let text = pending
                pending = ""
                lastFlush = Date()
                updateLastMessage(in: conversationID) { $0.text += text }
                BackgroundAnswer.shared.report(completedUnits: answerTokens)
            }
        }
        if inThinking { pending += "</think>" }
        if !pending.isEmpty {
            let text = pending
            updateLastMessage(in: conversationID) { $0.text += text }
        }
        let elapsed = Date().timeIntervalSince(started)
        if pieces > 1, elapsed > 0 {
            updateLastMessage(in: conversationID) { $0.tokensPerSecond = Double(pieces) / elapsed }
        }
    }

    /// A light vibration after a long answer, or a notification if the app is not in front.
    private func finishNotice(for conversationID: UUID, startedAt: Date) {
        guard pausedConversationID == nil,
              let message = conversations.first(where: { $0.id == conversationID })?.messages.last,
              message.role == .assistant, !message.isError, !message.answer.isEmpty else { return }
        if UIApplication.shared.applicationState != .active {
            if settings.notificationsEnabled {
                NotificationService.shared.post(title: "Ответ готов", body: String(message.answer.prefix(140)))
            }
        } else if Date().timeIntervalSince(startedAt) > 8 {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    private func updateLastMessage(in conversationID: UUID, _ change: (inout ChatMessage) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }),
              let last = conversations[index].messages.indices.last,
              conversations[index].messages[last].role == .assistant else { return }
        change(&conversations[index].messages[last])
    }

    private func ensureModelLoaded(useGPU: Bool = true) async throws {
        guard let file = models.activeFile(uncensored: settings.uncensored) else { throw EngineError.notLoaded }
        let visionPath = models.visionPath
        if loadedFile == file, loadedVisionPath == visionPath, loadedOnGPU == useGPU,
           loadedContextSize == settings.contextSize, engineState == .ready {
            return
        }

        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { engineState = .loading }
        loadedFile = nil
        do {
            let requestedContext = settings.contextSize
            let info = try await engine.load(
                path: models.path(for: file),
                visionPath: visionPath,
                contextSize: requestedContext,
                useGPU: useGPU
            )
            loadedOnGPU = useGPU
            template = ChatTemplate.detect(from: info.chatTemplate)
            supportsThinking = ChatTemplate.supportsThinking(info.chatTemplate)
            canSeeImages = info.canSeeImages
            loadedFile = file
            loadedVisionPath = visionPath
            loadedContextSize = requestedContext
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { engineState = .ready }
        } catch {
            withAnimation { engineState = .failed(error.localizedDescription) }
            throw error
        }
    }

    /// Builds the prompt, dropping the oldest messages when the conversation no longer fits the context.
    /// Also returns text the reply must start with (an opened <think> block for models that always reason).
    private func buildPrompt(for conversationID: UUID) async throws -> (String, [EngineImage], String) {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else {
            throw EngineError.notLoaded
        }

        struct Turn {
            let isUser: Bool
            let text: String
            let images: [EngineImage]
        }
        let marker = LlamaEngine.mediaMarker
        let useImages = canSeeImages
        // Photos are decoded away from the main thread so the interface stays responsive.
        let imageNames = useImages ? Set(conversation.messages.flatMap(\.imageNames)) : []
        let decoded: [String: EngineImage] = await Task.detached(priority: .userInitiated) {
            var result: [String: EngineImage] = [:]
            for name in imageNames {
                result[name] = ImageStore.engineImage(named: name)
            }
            return result
        }.value
        var turns: [Turn] = conversation.messages.dropLast()
            .filter { !$0.isError }
            .map { message -> Turn in
                let images = useImages ? message.imageNames.compactMap { decoded[$0] } : []
                return Turn(
                    isUser: message.role == .user,
                    text: message.role == .user ? message.text : message.answer,
                    images: images
                )
            }
            .filter { !$0.text.isEmpty }

        var system = settings.systemPrompt
        if settings.uncensored {
            // Placed first so the model weighs it above everything else.
            system = AppSettings.uncensoredInstruction + "\n\n" + system
        }

        let budget = settings.contextSize - min(settings.maxResponseTokens, settings.contextSize / 2)
        while true {
            let promptTurns = turns.map { turn in
                PromptTurn(
                    isUser: turn.isUser,
                    text: String(repeating: marker + "\n", count: turn.images.count) + turn.text
                )
            }
            var prompt = template.render(system: system, turns: promptTurns)
            var prefill = ""
            if template.alwaysThinks {
                prefill = "<think>\n"
                prompt += prefill
            } else if supportsThinking, !settings.thinkingEnabled {
                prompt += "<think>\n\n</think>\n\n"
            }
            let images = turns.flatMap(\.images)
            if try await engine.tokenCount(prompt, images: images) <= budget { return (prompt, images, prefill) }
            guard turns.count > 1 else { throw EngineError.promptTooLong }
            turns.removeFirst(turns.count > 2 ? 2 : 1)
        }
    }

    /// Frees the model's memory, for example after a memory warning.
    func unloadModel() {
        guard !isGenerating else { return }
        loadedFile = nil
        engineState = .idle
        Task { await engine.unload() }
    }
}
