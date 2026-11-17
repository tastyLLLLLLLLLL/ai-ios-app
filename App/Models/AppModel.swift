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

    private let engine = LlamaEngine()
    private var loadedFile: String?
    private var loadedContextSize = 0
    private var template = ChatTemplate.chatML
    private var supportsThinking = false
    private var loadedVisionPath: String?
    private var canSeeImages = false
    private var generationTask: Task<Void, Never>?

    private static var storageURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chats.json")
    }

    init() {
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
        guard let file = models.selectedFile else { return "Нет модели" }
        return ModelCatalog.displayName(forFile: file)
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
        guard !trimmed.isEmpty || !imageNames.isEmpty, !isGenerating, models.selectedFile != nil else {
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
        guard !isGenerating, models.selectedFile != nil,
              let index = conversations.firstIndex(where: { $0.id == currentID }),
              let last = conversations[index].messages.last, last.role == .assistant else { return }
        conversations[index].messages[conversations[index].messages.count - 1] = ChatMessage(role: .assistant, text: "")
        generate(in: conversations[index].id)
    }

    func stop() {
        generationTask?.cancel()
        engine.cancelAll()
    }

    private func generate(in conversationID: UUID) {
        isGenerating = true
        MotionStore.shared.paused = settings.pauseMotionWhileAnswering
        generationTask = Task {
            do {
                try await ensureModelLoaded()
                let (prompt, images, prefill) = try await buildPrompt(for: conversationID)
                if !prefill.isEmpty {
                    updateLastMessage(in: conversationID) { $0.text = prefill }
                }
                let options = GenerationOptions(
                    temperature: Float(settings.temperature),
                    maxTokens: settings.maxResponseTokens
                )
                let started = Date()
                var pieces = 0
                // Tokens are shown in small batches: redrawing the screen for each one wastes time.
                var pending = ""
                var lastFlush = Date.distantPast
                for try await piece in engine.generate(prompt: prompt, images: images, options: options) {
                    pieces += 1
                    pending += piece
                    if Date().timeIntervalSince(lastFlush) >= 0.06 {
                        let chunk = pending
                        pending = ""
                        lastFlush = Date()
                        updateLastMessage(in: conversationID) { $0.text += chunk }
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
            MotionStore.shared.paused = false
            save()
        }
    }

    private func updateLastMessage(in conversationID: UUID, _ change: (inout ChatMessage) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }),
              let last = conversations[index].messages.indices.last,
              conversations[index].messages[last].role == .assistant else { return }
        change(&conversations[index].messages[last])
    }

    private func ensureModelLoaded() async throws {
        guard let file = models.activeFile(uncensored: settings.uncensored) else { throw EngineError.notLoaded }
        let visionPath = models.visionPath
        if loadedFile == file, loadedVisionPath == visionPath,
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
                contextSize: requestedContext
            )
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
