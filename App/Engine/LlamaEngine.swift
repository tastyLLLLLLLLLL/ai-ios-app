import Foundation
import llama

struct GenerationOptions: Sendable {
    var temperature: Float
    var maxTokens: Int
}

enum EngineError: LocalizedError {
    case notLoaded
    case loadFailed
    case contextFailed
    case tokenizeFailed
    case promptTooLong
    case decodeFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .notLoaded: return "Модель не загружена."
        case .loadFailed: return "Не удалось загрузить модель. Возможно, файл повреждён или не хватает памяти."
        case .contextFailed: return "Не удалось подготовить модель к работе: не хватает памяти. Уменьшите размер контекста в настройках."
        case .tokenizeFailed: return "Не удалось обработать текст запроса."
        case .promptTooLong: return "Сообщение слишком длинное для выбранного размера контекста."
        case .decodeFailed(let code): return "Ошибка вычислений (код \(code)). Попробуйте ещё раз."
        }
    }
}

/// Thin wrapper around the llama.cpp C API. All calls into llama.cpp happen on one serial queue.
final class LlamaEngine: @unchecked Sendable {
    struct LoadedInfo: Sendable {
        let chatTemplate: String
        let contextSize: Int
    }

    private static let batchSize: Int32 = 512
    private static let backend: Void = { llama_backend_init() }()

    private let queue = DispatchQueue(label: "pocketai.llama", qos: .userInitiated)
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var contextSize: Int32 = 0
    /// Tokens currently held in the model's memory, so a follow-up prompt only evaluates what changed.
    private var cached: [llama_token] = []

    private let lock = NSLock()
    private var currentID = 0
    private var cancelledID = -1

    // MARK: - Public API

    func load(path: String, contextSize: Int) async throws -> LoadedInfo {
        try await run { try self.loadSync(path: path, contextSize: contextSize) }
    }

    func unload() async {
        _ = try? await run { self.unloadSync() }
    }

    func tokenCount(_ text: String) async throws -> Int {
        try await run { try self.tokenizeSync(text).count }
    }

    func generate(prompt: String, options: GenerationOptions) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let id = self.nextID()
            continuation.onTermination = { [weak self] _ in self?.cancel(upTo: id) }
            self.queue.async {
                do {
                    try self.generateSync(id: id, prompt: prompt, options: options) { piece in
                        continuation.yield(piece)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func cancelAll() {
        lock.lock()
        cancelledID = currentID
        lock.unlock()
    }

    // MARK: - Cancellation

    private func nextID() -> Int {
        lock.lock()
        defer { lock.unlock() }
        currentID += 1
        return currentID
    }

    private func cancel(upTo id: Int) {
        lock.lock()
        if id > cancelledID { cancelledID = id }
        lock.unlock()
    }

    private func isCancelled(_ id: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return id <= cancelledID
    }

    // MARK: - Work on the serial queue

    private func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            queue.async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func unloadSync() {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        context = nil
        model = nil
        vocab = nil
        cached = []
        contextSize = 0
    }

    private func loadSync(path: String, contextSize: Int) throws -> LoadedInfo {
        _ = Self.backend
        unloadSync()

        var modelParams = llama_model_default_params()
        #if targetEnvironment(simulator)
        modelParams.n_gpu_layers = 0
        #else
        modelParams.n_gpu_layers = 99
        #endif

        guard let loadedModel = llama_model_load_from_file(path, modelParams) else {
            throw EngineError.loadFailed
        }

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(contextSize)
        contextParams.n_batch = UInt32(Self.batchSize)
        contextParams.n_threads = 4
        contextParams.n_threads_batch = 4
        #if targetEnvironment(simulator)
        contextParams.offload_kqv = false
        #endif

        guard let loadedContext = llama_init_from_model(loadedModel, contextParams) else {
            llama_model_free(loadedModel)
            throw EngineError.contextFailed
        }

        model = loadedModel
        context = loadedContext
        vocab = llama_model_get_vocab(loadedModel)
        self.contextSize = Int32(llama_n_ctx(loadedContext))

        var template = ""
        if let pointer = llama_model_chat_template(loadedModel, nil) {
            template = String(cString: pointer)
        }
        return LoadedInfo(chatTemplate: template, contextSize: Int(self.contextSize))
    }

    private func tokenizeSync(_ text: String) throws -> [llama_token] {
        guard let vocab else { throw EngineError.notLoaded }
        let byteCount = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(byteCount) + 16)
        var count = llama_tokenize(vocab, text, byteCount, &tokens, Int32(tokens.count), true, true)
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, text, byteCount, &tokens, Int32(tokens.count), true, true)
        }
        guard count >= 0 else { throw EngineError.tokenizeFailed }
        return Array(tokens.prefix(Int(count)))
    }

    private func piece(for token: llama_token, vocab: OpaquePointer) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if count < 0 {
            buffer = [CChar](repeating: 0, count: Int(-count))
            count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        guard count > 0 else { return [] }
        return buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }
    }

    private func add(_ token: llama_token, at position: Int32, logits: Bool, to batch: inout llama_batch) {
        let index = Int(batch.n_tokens)
        batch.token[index] = token
        batch.pos[index] = position
        batch.n_seq_id[index] = 1
        batch.seq_id[index]![0] = 0
        batch.logits[index] = logits ? 1 : 0
        batch.n_tokens += 1
    }

    private func resetMemory(_ context: OpaquePointer) {
        llama_memory_clear(llama_get_memory(context), true)
        cached = []
    }

    private func generateSync(
        id: Int,
        prompt: String,
        options: GenerationOptions,
        emit: (String) -> Void
    ) throws {
        guard let context, let vocab else { throw EngineError.notLoaded }

        let tokens = try tokenizeSync(prompt)
        guard !tokens.isEmpty else { throw EngineError.tokenizeFailed }
        guard tokens.count < Int(contextSize) - 16 else { throw EngineError.promptTooLong }

        // Reuse the part of the conversation the model has already seen.
        var common = 0
        while common < cached.count, common < tokens.count, cached[common] == tokens[common] {
            common += 1
        }
        if common == tokens.count { common -= 1 }
        if common > 0, llama_memory_seq_rm(llama_get_memory(context), 0, Int32(common), -1) {
            cached = Array(tokens[0..<common])
        } else {
            resetMemory(context)
            common = 0
        }

        var batch = llama_batch_init(Self.batchSize, 0, 1)
        defer { llama_batch_free(batch) }

        var index = common
        while index < tokens.count {
            if isCancelled(id) { return }
            let end = min(index + Int(Self.batchSize), tokens.count)
            batch.n_tokens = 0
            for position in index..<end {
                add(tokens[position], at: Int32(position), logits: position == tokens.count - 1, to: &batch)
            }
            let result = llama_decode(context, batch)
            guard result == 0 else {
                resetMemory(context)
                throw EngineError.decodeFailed(result)
            }
            cached.append(contentsOf: tokens[index..<end])
            index = end
        }

        guard let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            throw EngineError.contextFailed
        }
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.95, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_min_p(0.05, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(max(options.temperature, 0.01)))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))

        var pending: [UInt8] = []
        var produced = 0
        var position = Int32(tokens.count)

        while produced < options.maxTokens, position < contextSize {
            if isCancelled(id) { break }

            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }

            pending.append(contentsOf: piece(for: token, vocab: vocab))
            if let text = String(bytes: pending, encoding: .utf8) {
                if !text.isEmpty { emit(text) }
                pending.removeAll(keepingCapacity: true)
            } else if pending.count > 16 {
                emit(String(decoding: pending, as: UTF8.self))
                pending.removeAll(keepingCapacity: true)
            }

            batch.n_tokens = 0
            add(token, at: position, logits: true, to: &batch)
            let result = llama_decode(context, batch)
            guard result == 0 else {
                resetMemory(context)
                throw EngineError.decodeFailed(result)
            }
            cached.append(token)
            position += 1
            produced += 1
        }

        if !pending.isEmpty {
            emit(String(decoding: pending, as: UTF8.self))
        }
    }
}
