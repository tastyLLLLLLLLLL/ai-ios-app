import Foundation

struct CatalogModel: Identifiable, Hashable {
    let name: String
    let summary: String
    let sizeLabel: String
    let badge: String?
    let fileName: String
    let url: URL

    var id: String { fileName }
}

enum ModelCatalog {
    static let models: [CatalogModel] = [
        CatalogModel(
            name: "Qwen3 4B",
            summary: "Самая умная из тех, что уверенно работают на iPhone с 8 ГБ памяти. Умеет рассуждать перед ответом, хорошо знает русский.",
            sizeLabel: "≈ 2,5 ГБ",
            badge: "Рекомендуем",
            fileName: "Qwen3-4B-Q4_K_M.gguf",
            url: URL(string: "https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf")!
        ),
        CatalogModel(
            name: "Gemma 3 4B",
            summary: "Модель Google. Живой и грамотный русский язык, хороша для текстов, переводов и общения.",
            sizeLabel: "≈ 2,5 ГБ",
            badge: nil,
            fileName: "gemma-3-4b-it-Q4_K_M.gguf",
            url: URL(string: "https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF/resolve/main/gemma-3-4b-it-Q4_K_M.gguf")!
        ),
        CatalogModel(
            name: "Qwen3 1.7B",
            summary: "Лёгкая и быстрая. Отвечает заметно проще, зато меньше греет телефон и экономит место.",
            sizeLabel: "≈ 1,8 ГБ",
            badge: "Быстрая",
            fileName: "Qwen3-1.7B-Q8_0.gguf",
            url: URL(string: "https://huggingface.co/Qwen/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q8_0.gguf")!
        )
    ]

    static func model(forFile fileName: String) -> CatalogModel? {
        models.first { $0.fileName == fileName }
    }

    static func displayName(forFile fileName: String) -> String {
        if let model = model(forFile: fileName) { return model.name }
        return (fileName as NSString).deletingPathExtension
    }
}
