import Foundation

struct ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable {
        case user
        case assistant
    }

    var id = UUID()
    var role: Role
    var text: String
    var isError = false
    var tokensPerSecond: Double?

    /// Reasoning the model wrote inside <think> tags, if any.
    var thinking: String? {
        guard let range = thinkRange else { return nil }
        let content = text[range.content].trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? nil : content
    }

    /// True while the model is still inside an unfinished <think> block.
    var isThinking: Bool {
        guard let range = thinkRange else { return false }
        return !range.closed
    }

    /// The reply without the reasoning part.
    var answer: String {
        guard let range = thinkRange else { return text }
        guard range.closed else { return "" }
        return String(text[range.afterEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct ThinkRange {
        let content: Range<String.Index>
        let afterEnd: String.Index
        let closed: Bool
    }

    private var thinkRange: ThinkRange? {
        guard role == .assistant else { return nil }
        let leading = text.prefix { $0.isWhitespace }
        let start = leading.endIndex
        guard text[start...].hasPrefix("<think>") else { return nil }
        let contentStart = text.index(start, offsetBy: 7)
        if let end = text.range(of: "</think>", range: contentStart..<text.endIndex) {
            return ThinkRange(content: contentStart..<end.lowerBound, afterEnd: end.upperBound, closed: true)
        }
        return ThinkRange(content: contentStart..<text.endIndex, afterEnd: text.endIndex, closed: false)
    }
}

struct Conversation: Identifiable, Codable, Equatable {
    var id = UUID()
    var title = ""
    var messages: [ChatMessage] = []
    var updated = Date()

    var displayTitle: String {
        title.isEmpty ? "Новый чат" : title
    }
}

struct AppSettings: Codable, Equatable {
    static let defaultSystemPrompt = "Ты — умный и дружелюбный ассистент. Отвечай на языке пользователя, по делу и без лишней воды."
    private static let key = "appSettings"

    var systemPrompt = AppSettings.defaultSystemPrompt
    var temperature: Double = 0.7
    var thinkingEnabled = false
    var contextSize = 4096
    var maxResponseTokens = 1024

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
