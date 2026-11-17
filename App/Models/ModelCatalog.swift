import Foundation

/// An extra file that belongs to a catalog model (vision module or the uncensored variant).
struct CompanionFile: Hashable {
    let fileName: String
    let url: URL
}

/// Sections of the model list.
enum ModelGroup: String, CaseIterable, Identifiable {
    case everyday
    case vision
    case fast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .everyday: return "На каждый день"
        case .vision: return "С фотографиями"
        case .fast: return "Для скорости"
        }
    }

    var subtitle: String {
        switch self {
        case .everyday: return "Лучший баланс ума и скорости для iPhone с 8 ГБ памяти"
        case .vision: return "Понимают прикреплённые снимки"
        case .fast: return "Отвечают быстрее, меньше греют телефон"
        }
    }

    var icon: String {
        switch self {
        case .everyday: return "star.fill"
        case .vision: return "photo.fill"
        case .fast: return "bolt.fill"
        }
    }
}

struct CatalogModel: Identifiable, Hashable {
    let group: ModelGroup
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
            group: .everyday,
            name: "Qwen3 4B",
            summary: "Самая умная из тех, что уверенно работают на iPhone с 8 ГБ памяти. Умеет рассуждать перед ответом, хорошо знает русский.",
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
            group: .vision,
            name: "Qwen3-VL 4B",
            summary: "Версия Qwen, которая видит фотографии: можно прикрепить снимок и спросить о нём. Хорошо читает текст на фото.",
            sizeLabel: "≈ 3,3 ГБ",
            badge: "Видит фото",
            fileName: "Qwen3-VL-4B-Instruct-Q4_K_M.gguf",
            url: URL(string: "https://huggingface.co/unsloth/Qwen3-VL-4B-Instruct-GGUF/resolve/main/Qwen3-VL-4B-Instruct-Q4_K_M.gguf")!,
            vision: CompanionFile(
                fileName: "mmproj-Qwen3-VL-4B-Instruct.gguf",
                url: URL(string: "https://huggingface.co/unsloth/Qwen3-VL-4B-Instruct-GGUF/resolve/main/mmproj-F16.gguf")!
            ),
            uncensored: CompanionFile(
                fileName: "uncensored-Qwen3-VL-4B-Instruct-Q4_K_M.gguf",
                url: URL(string: "https://huggingface.co/noctrex/Huihui-Qwen3-VL-4B-Instruct-abliterated-GGUF/resolve/main/Huihui-Qwen3-VL-4B-Instruct-abliterated-Q4_K_M.gguf")!
            )
        ),
        CatalogModel(
            group: .vision,
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
            group: .fast,
            name: "Qwen3 1.7B",
            summary: "Лёгкая и быстрая. Отвечает заметно проще, зато меньше греет телефон и экономит место.",
            sizeLabel: "≈ 1,8 ГБ",
            badge: "Быстрая",
            fileName: "Qwen3-1.7B-Q8_0.gguf",
            url: URL(string: "https://huggingface.co/Qwen/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q8_0.gguf")!,
            uncensored: CompanionFile(
                fileName: "uncensored-Qwen3-1.7B-Q8_0.gguf",
                url: URL(string: "https://huggingface.co/bartowski/mlabonne_Qwen3-1.7B-abliterated-GGUF/resolve/main/mlabonne_Qwen3-1.7B-abliterated-Q8_0.gguf")!
            )
        )
    ]

    /// Files that are parts of catalog models and must not be listed as separate models.
    static let companionFileNames: Set<String> = Set(
        models.flatMap { [$0.vision?.fileName, $0.uncensored?.fileName].compactMap { $0 } }
    )

    /// Files of models that were removed from the catalog; deleted on launch to free space.
    static let retiredFileNames = [
        "Qwen3-8B-Q4_K_M.gguf",
        "uncensored-Qwen3-8B-Q4_K_M.gguf",
        "DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf"
    ]

    static func models(in group: ModelGroup) -> [CatalogModel] {
        models.filter { $0.group == group }
    }

    static func model(forFile fileName: String) -> CatalogModel? {
        models.first { $0.fileName == fileName }
    }

    static func displayName(forFile fileName: String) -> String {
        if let model = model(forFile: fileName) { return model.name }
        return (fileName as NSString).deletingPathExtension
    }
}
