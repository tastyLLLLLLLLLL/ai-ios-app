import Foundation

/// An extra file that belongs to a catalog model (vision module or the uncensored variant).
struct CompanionFile: Hashable {
    let fileName: String
    let url: URL
}

struct CatalogModel: Identifiable, Hashable {
    let name: String
    let summary: String
    let sizeLabel: String
    let badge: String?
    let fileName: String
    let url: URL
    /// Lets the model look at photos. Downloaded together with the model.
    var vision: CompanionFile?
    /// The same model with refusals removed. Downloaded when "Без цензуры" is switched on.
    var uncensored: CompanionFile?

    var id: String { fileName }
}

enum ModelCatalog {
    static let models: [CatalogModel] = [
        CatalogModel(
            name: "Qwen3 4B",
            summary: "Самая умная из тех, что уверенно работают на iPhone с 8 ГБ памяти. Умеет рассуждать перед ответом, хорошо знает русский. Фото не видит.",
            sizeLabel: "≈ 2,5 ГБ",
            badge: "Рекомендуем",
            fileName: "Qwen3-4B-Q4_K_M.gguf",
            url: URL(string: "https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf")!,
            uncensored: CompanionFile(
                fileName: "uncensored-Qwen3-4B-Q4_K_M.gguf",
                url: URL(string: "https://huggingface.co/bartowski/mlabonne_Qwen3-4B-abliterated-GGUF/resolve/main/mlabonne_Qwen3-4B-abliterated-Q4_K_M.gguf")!
            )
        ),
        CatalogModel(
            name: "Gemma 3 4B",
            summary: "Модель Google, которая видит фотографии: можно прикрепить снимок и спросить о нём. Живой и грамотный русский язык.",
            sizeLabel: "≈ 3,3 ГБ",
            badge: "Видит фото",
            fileName: "gemma-3-4b-it-Q4_K_M.gguf",
            url: URL(string: "https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF/resolve/main/gemma-3-4b-it-Q4_K_M.gguf")!,
            vision: CompanionFile(
                fileName: "mmproj-gemma-3-4b-it.gguf",
                url: URL(string: "https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF/resolve/main/mmproj-model-f16.gguf")!
            ),
            uncensored: CompanionFile(
                fileName: "uncensored-gemma-3-4b-it-Q4_K_M.gguf",
                url: URL(string: "https://huggingface.co/mlabonne/gemma-3-4b-it-abliterated-v2-GGUF/resolve/main/gemma-3-4b-it-abliterated-v2.q4_k_m.gguf")!
            )
        ),
        CatalogModel(
            name: "Qwen3 1.7B",
            summary: "Лёгкая и быстрая. Отвечает заметно проще, зато меньше греет телефон и экономит место. Фото не видит.",
            sizeLabel: "≈ 1,8 ГБ",
            badge: "Быстрая",
            fileName: "Qwen3-1.7B-Q8_0.gguf",
            url: URL(string: "https://huggingface.co/Qwen/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q8_0.gguf")!
        )
    ]

    /// Files that are parts of catalog models and must not be listed as separate models.
    static let companionFileNames: Set<String> = Set(
        models.flatMap { [$0.vision?.fileName, $0.uncensored?.fileName].compactMap { $0 } }
    )

    static func model(forFile fileName: String) -> CatalogModel? {
        models.first { $0.fileName == fileName }
    }

    static func displayName(forFile fileName: String) -> String {
        if let model = model(forFile: fileName) { return model.name }
        return (fileName as NSString).deletingPathExtension
    }
}
