import Foundation

struct PromptTurn {
    let isUser: Bool
    let text: String
}

/// Prompt formats of the common open model families. The format is detected from the
/// template stored inside the model file, so imported models work without configuration.
enum ChatTemplate {
    case chatML
    case gemma
    case llama3
    case phi

    static func detect(from template: String) -> ChatTemplate {
        if template.contains("<start_of_turn>") { return .gemma }
        if template.contains("<|start_header_id|>") { return .llama3 }
        if template.contains("<|im_start|>") { return .chatML }
        if template.contains("<|assistant|>") { return .phi }
        return .chatML
    }

    /// True for models that can reason inside <think> tags before answering (Qwen3, DeepSeek R1 and similar).
    static func supportsThinking(_ template: String) -> Bool {
        template.contains("enable_thinking") || template.contains("<think>")
    }

    func render(system: String, turns: [PromptTurn]) -> String {
        let system = system.trimmingCharacters(in: .whitespacesAndNewlines)
        var prompt = ""

        switch self {
        case .chatML:
            if !system.isEmpty {
                prompt += "<|im_start|>system\n\(system)<|im_end|>\n"
            }
            for turn in turns {
                prompt += "<|im_start|>\(turn.isUser ? "user" : "assistant")\n\(turn.text)<|im_end|>\n"
            }
            prompt += "<|im_start|>assistant\n"

        case .gemma:
            var systemPending = !system.isEmpty
            for turn in turns {
                if turn.isUser {
                    let prefix = systemPending ? "\(system)\n\n" : ""
                    systemPending = false
                    prompt += "<start_of_turn>user\n\(prefix)\(turn.text)<end_of_turn>\n"
                } else {
                    prompt += "<start_of_turn>model\n\(turn.text)<end_of_turn>\n"
                }
            }
            prompt += "<start_of_turn>model\n"

        case .llama3:
            if !system.isEmpty {
                prompt += "<|start_header_id|>system<|end_header_id|>\n\n\(system)<|eot_id|>"
            }
            for turn in turns {
                let role = turn.isUser ? "user" : "assistant"
                prompt += "<|start_header_id|>\(role)<|end_header_id|>\n\n\(turn.text)<|eot_id|>"
            }
            prompt += "<|start_header_id|>assistant<|end_header_id|>\n\n"

        case .phi:
            if !system.isEmpty {
                prompt += "<|system|>\(system)<|end|>"
            }
            for turn in turns {
                prompt += "<|\(turn.isUser ? "user" : "assistant")|>\(turn.text)<|end|>"
            }
            prompt += "<|assistant|>"
        }

        return prompt
    }
}
