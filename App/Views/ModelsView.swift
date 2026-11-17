import SwiftUI
import UniformTypeIdentifiers

struct ModelsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false
    @State private var showLinkPrompt = false
    @State private var link = ""
    @State private var linkError = false
    @State private var appeared = false

    private var store: ModelStore { model.models }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Модель скачивается один раз и дальше работает без интернета. Загрузка продолжается, даже если свернуть приложение.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    ForEach(Array(ModelCatalog.models.enumerated()), id: \.element.id) { index, item in
                        CatalogModelCard(item: item)
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 18)
                            .animation(.smooth.delay(Double(index) * 0.06), value: appeared)
                    }

                    Text("Свои модели")
                        .font(.headline)
                        .padding(.top, 10)
                        .padding(.horizontal, 4)

                    ForEach(store.customEntries, id: \.self) { fileName in
                        CustomModelCard(fileName: fileName)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }

                    VStack(spacing: 0) {
                        Button {
                            link = ""
                            showLinkPrompt = true
                        } label: {
                            Label("Скачать по ссылке на файл .gguf", systemImage: "link")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .contentShape(Rectangle())
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
                            .contentShape(Rectangle())
                        }
                        .disabled(store.isImporting)
                    }
                    .buttonStyle(PressableStyle(scale: 0.98))
                    .glassCard(cornerRadius: 18)

                    Text("Подойдёт любая модель в формате GGUF. Для iPhone с 8 ГБ памяти выбирайте файлы до 3 ГБ.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                .padding(16)
                .animation(.smooth, value: store.customEntries)
            }
            .background(AuroraBackground())
            .navigationTitle("Модели")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .onAppear { appeared = true }
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

// MARK: - Cards

/// What a model card shows under the description.
private enum CardState: Equatable {
    case notInstalled
    case downloading(DownloadProgress)
    case installed
}

struct CatalogModelCard: View {
    @Environment(AppModel.self) private var model
    let item: CatalogModel

    private var store: ModelStore { model.models }

    private var state: CardState {
        if let progress = store.progress(for: item) { return .downloading(progress) }
        return store.installed.contains(item.fileName) ? .installed : .notInstalled
    }

    var body: some View {
        ModelCardShell(
            name: item.name,
            summary: item.summary,
            sizeLabel: item.sizeLabel,
            badge: item.badge,
            error: store.error(for: item),
            state: state,
            isSelected: store.selectedFile == item.fileName,
            actionTitle: "Скачать",
            actionIcon: "arrow.down.circle.fill",
            onAction: { store.download(item) },
            onCancel: { store.cancelDownload(item) },
            onSelect: { store.select(item.fileName) },
            onDelete: { store.delete(item.fileName) }
        ) {
            if store.needsVisionDownload(item) {
                Button {
                    store.downloadVision(for: item)
                } label: {
                    Label("Скачать модуль зрения (≈ 0,85 ГБ)", systemImage: "eye")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(PressableStyle())
                .transition(.opacity)
            }
        }
    }
}

struct CustomModelCard: View {
    @Environment(AppModel.self) private var model
    let fileName: String

    private var store: ModelStore { model.models }

    private var state: CardState {
        if let progress = store.downloads[fileName] { return .downloading(progress) }
        return store.installed.contains(fileName) ? .installed : .notInstalled
    }

    var body: some View {
        ModelCardShell(
            name: ModelCatalog.displayName(forFile: fileName),
            summary: "Добавлена вручную",
            sizeLabel: store.installed.contains(fileName) ? store.sizeLabel(for: fileName) : "",
            badge: nil,
            error: store.errors[fileName],
            state: state,
            isSelected: store.selectedFile == fileName,
            actionTitle: "Убрать из списка",
            actionIcon: "xmark.circle.fill",
            onAction: { store.clearError(fileName) },
            onCancel: { store.cancelDownload(fileName) },
            onSelect: { store.select(fileName) },
            onDelete: { store.delete(fileName) }
        ) {
            EmptyView()
        }
    }
}

private struct ModelCardShell<Extra: View>: View {
    let name: String
    let summary: String
    let sizeLabel: String
    let badge: String?
    let error: String?
    let state: CardState
    let isSelected: Bool
    let actionTitle: String
    let actionIcon: String
    let onAction: () -> Void
    let onCancel: () -> Void
    let onSelect: () -> Void
    let onDelete: () -> Void
    @ViewBuilder let extra: () -> Extra

    @State private var confirmDelete = false

    /// Collapses progress updates into one value so only real state changes animate.
    private var stateKind: Int {
        switch state {
        case .notInstalled: return 0
        case .downloading: return 1
        case .installed: return 2
        }
    }

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

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .transition(.opacity)
            }

            controls
            extra()
        }
        .padding(16)
        .glassCard()
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Theme.accent, lineWidth: 2)
                .opacity(isSelected ? 1 : 0)
        )
        .scaleEffect(isSelected ? 1 : 0.985)
        .animation(.smooth, value: isSelected)
        .animation(.smooth, value: stateKind)
        .sensoryFeedback(.selection, trigger: isSelected)
        .confirmationDialog("Удалить модель «\(name)» с телефона?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                withAnimation(.smooth) { onDelete() }
            }
            Button("Отмена", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch state {
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress.fraction)
                    .tint(Theme.blue)
                    .animation(.linear(duration: 0.3), value: progress.fraction)
                HStack {
                    Text(progressLabel(progress))
                        .font(.footnote)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Отменить", action: onCancel)
                        .font(.footnote.weight(.medium))
                }
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))

        case .installed:
            HStack {
                if isSelected {
                    Label("Используется", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
                } else {
                    Button(action: onSelect) {
                        Text("Использовать")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(PressableStyle())
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
                }
                Spacer()
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Удалить модель")
            }
            .transition(.opacity)

        case .notInstalled:
            Button(action: onAction) {
                Label(actionTitle, systemImage: actionIcon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(PressableStyle())
            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
        }
    }

    private func progressLabel(_ progress: DownloadProgress) -> String {
        guard progress.total > 0 else { return "Подключаюсь…" }
        let received = ByteCountFormatter.string(fromByteCount: progress.received, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: progress.total, countStyle: .file)
        return "\(received) из \(total) · \(Int(progress.fraction * 100))%"
    }
}
