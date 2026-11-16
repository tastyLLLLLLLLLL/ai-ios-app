import SwiftUI
import UniformTypeIdentifiers

struct ModelsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false
    @State private var showLinkPrompt = false
    @State private var link = ""
    @State private var linkError = false

    private var store: ModelStore { model.models }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Модель скачивается один раз и дальше работает без интернета. Загрузка продолжается, даже если свернуть приложение.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    ForEach(ModelCatalog.models) { item in
                        ModelCard(
                            name: item.name,
                            summary: item.summary,
                            sizeLabel: item.sizeLabel,
                            badge: item.badge,
                            fileName: item.fileName,
                            onDownload: { store.download(item) }
                        )
                    }

                    Text("Свои модели")
                        .font(.headline)
                        .padding(.top, 10)
                        .padding(.horizontal, 4)

                    ForEach(store.customEntries, id: \.self) { fileName in
                        ModelCard(
                            name: ModelCatalog.displayName(forFile: fileName),
                            summary: "Добавлена вручную",
                            sizeLabel: store.installed.contains(fileName) ? store.sizeLabel(for: fileName) : "",
                            badge: nil,
                            fileName: fileName,
                            actionTitle: "Убрать из списка",
                            actionIcon: "xmark.circle.fill",
                            onDownload: { store.clearError(fileName) }
                        )
                    }

                    VStack(spacing: 0) {
                        Button {
                            link = ""
                            showLinkPrompt = true
                        } label: {
                            Label("Скачать по ссылке на файл .gguf", systemImage: "link")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                        }
                        Divider().padding(.leading, 14)
                        Button {
                            showImporter = true
                        } label: {
                            HStack {
                                Label("Добавить файл .gguf из «Файлов»", systemImage: "folder")
                                Spacer()
                                if store.isImporting { ProgressView() }
                            }
                            .padding(14)
                        }
                        .disabled(store.isImporting)
                    }
                    .buttonStyle(.plain)
                    .glassCard(cornerRadius: 18)

                    Text("Подойдёт любая модель в формате GGUF. Для iPhone с 8 ГБ памяти выбирайте файлы до 3 ГБ.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                .padding(16)
            }
            .background(AuroraBackground())
            .navigationTitle("Модели")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data]) { result in
                if case .success(let url) = result {
                    store.importFile(from: url)
                }
            }
            .alert("Ссылка на модель", isPresented: $showLinkPrompt) {
                TextField("https://…/model.gguf", text: $link)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Скачать") {
                    if !store.download(link: link) { linkError = true }
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Вставьте прямую ссылку на файл .gguf, например с сайта Hugging Face.")
            }
            .alert("Не получилось", isPresented: $linkError) {
                Button("Понятно", role: .cancel) {}
            } message: {
                Text("Нужна прямая ссылка, которая заканчивается на .gguf.")
            }
        }
    }
}

struct ModelCard: View {
    @Environment(AppModel.self) private var model
    let name: String
    let summary: String
    let sizeLabel: String
    let badge: String?
    let fileName: String
    var actionTitle = "Скачать"
    var actionIcon = "arrow.down.circle.fill"
    let onDownload: () -> Void

    @State private var confirmDelete = false

    private var store: ModelStore { model.models }
    private var isInstalled: Bool { store.installed.contains(fileName) }
    private var isSelected: Bool { store.selectedFile == fileName }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.accent, in: Capsule())
                }
                Spacer(minLength: 0)
                Text(sizeLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let error = store.errors[fileName] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            controls
        }
        .padding(16)
        .glassCard()
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Theme.accent, lineWidth: isSelected ? 2 : 0)
        )
        .confirmationDialog("Удалить модель «\(name)» с телефона?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { store.delete(fileName) }
            Button("Отмена", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var controls: some View {
        if let progress = store.downloads[fileName] {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress.fraction)
                    .tint(Theme.blue)
                HStack {
                    Text(progressLabel(progress))
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Отменить") { store.cancelDownload(fileName) }
                        .font(.footnote.weight(.medium))
                }
            }
        } else if isInstalled {
            HStack {
                if isSelected {
                    Label("Используется", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                } else {
                    Button {
                        store.select(fileName)
                    } label: {
                        Text("Использовать")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Удалить модель")
            }
        } else {
            Button(action: onDownload) {
                Label(actionTitle, systemImage: actionIcon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func progressLabel(_ progress: DownloadProgress) -> String {
        guard progress.total > 0 else { return "Подключаюсь…" }
        let received = ByteCountFormatter.string(fromByteCount: progress.received, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: progress.total, countStyle: .file)
        return "\(received) из \(total) · \(Int(progress.fraction * 100))%"
    }
}
