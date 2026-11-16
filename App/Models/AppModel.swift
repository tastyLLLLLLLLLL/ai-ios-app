import Foundation
import Observation
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
        conversations.removeAll { $0.id == id }
        save()
    }

    func deleteAllChats() {
        newChat()
        conversations = []
        save()
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

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating, models.selectedFile != nil else { return }

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
        conversations[index].messages.append(ChatMessage(role: .user, text: text))
        conversations[index].messages.append(ChatMessage(role: .assistant, text: ""))
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
        generationTask = Task {
            do {
                try await ensureModelLoaded()
                let prompt = try await buildPrompt(for: conversationID)
                let options = GenerationOptions(
                    temperature: Float(settings.temperature),
                    maxTokens: settings.maxResponseTokens
                )
                let started = Date()
                var pieces = 0
                for try await piece in engine.generate(prompt: prompt, options: options) {
                    pieces += 1
                    updateLastMessage(in: conversationID) { $0.text += piece }
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
        guard let file = models.selectedFile else { throw EngineError.notLoaded }
        if loadedFile == file, loadedContextSize == settings.contextSize, engineState == .ready { return }

        engineState = .loading
        loadedFile = nil
        do {
            let requestedContext = settings.contextSize
            let info = try await engine.load(path: models.path(for: file), contextSize: requestedContext)
            template = ChatTemplate.detect(from: info.chatTemplate)
            supportsThinking = ChatTemplate.supportsThinking(info.chatTemplate)
            loadedFile = file
            loadedContextSize = requestedContext
            engineState = .ready
        } catch {
            engineState = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Builds the prompt, dropping the oldest messages when the conversation no longer fits the context.
    private func buildPrompt(for conversationID: UUID) async throws -> String {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else {
            throw EngineError.notLoaded
        }
        var turns = conversation.messages.dropLast()
            .filter { !$0.isError }
            .map { PromptTurn(isUser: $0.role == .user, text: $0.role == .user ? $0.text : $0.answer) }
            .filter { !$0.text.isEmpty }

        let budget = settings.contextSize - min(settings.maxResponseTokens, settings.contextSize / 2)
        while true {
            var prompt = template.render(system: settings.systemPrompt, turns: turns)
            if supportsThinking, !settings.thinkingEnabled {
                prompt += "<think>\n\n</think>\n\n"
            }
            if try await engine.tokenCount(prompt) <= budget { return prompt }
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
