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
    @State private var source: ModelSource = .offline

    private enum ModelSource: String, CaseIterable, Identifiable {
        case offline
        case online
        var id: String { rawValue }
        var title: String { self == .offline ? "Офлайн" : "Онлайн" }
    }

    private var store: ModelStore { model.models }

    var body: some View {
        NavigationStack {
            ScrollView {
                Picker("Где работает модель", selection: $source.animation(.smooth)) {
                    ForEach(ModelSource.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)

                if source == .online {
                    OnlineModelsPlaceholder()
                        .padding(16)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                } else {
                LazyVStack(alignment: .leading, spacing: 14) {
                    Text("Модель скачивается один раз и дальше работает без интернета. Загрузка продолжается, даже если свернуть приложение.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    ForEach(ModelGroup.allCases) { group in
                        groupHeader(icon: group.icon, title: group.title, subtitle: group.subtitle)
                        ForEach(ModelCatalog.models(in: group)) { item in
                            CatalogModelCard(item: item)
                        }
                    }

                    groupHeader(
                        icon: "tray.and.arrow.down.fill",
                        title: "Свои модели",
                        subtitle: "Любая модель в формате GGUF — по ссылке или из «Файлов»"
                    )
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
                // One light fade for the whole list instead of animating every card separately.
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(.easeOut(duration: 0.22), value: appeared)
                .animation(.smooth, value: store.customEntries)
                .transition(.opacity.combined(with: .move(edge: .leading)))
                }
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

extension ModelsView {
    /// Heading that separates groups of models.
    private func groupHeader(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 14)
        .padding(.horizontal, 4)
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
            supportsUncensored: item.uncensored != nil,
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
            if item.uncensored != nil, store.installed.contains(item.fileName) {
                UncensoredRow(item: item)
                    .transition(.opacity)
            }
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
            supportsUncensored: false,
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
    let supportsUncensored: Bool
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

            if supportsUncensored {
                Label("Без цензуры", systemImage: "lock.open.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.tint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.tint.opacity(0.14), in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.tint.opacity(0.35), lineWidth: 1))
            }

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
                    .tint(Theme.tint)
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
                            .glass(Capsule(), interactive: true)
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
                    .glass(Capsule(), tint: Theme.tint, interactive: true)
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

// MARK: - Uncensored variant

/// Download state of a model's uncensored variant, shown on its card.
private struct UncensoredRow: View {
    @Environment(AppModel.self) private var model
    let item: CatalogModel

    @State private var confirmDelete = false

    private var store: ModelStore { model.models }

    var body: some View {
        HStack(spacing: 10) {
            switch store.uncensoredState(for: item) {
            case .ready:
                Label(
                    model.settings.uncensored ? "Версия без цензуры включена" : "Версия без цензуры скачана",
                    systemImage: "checkmark.seal.fill"
                )
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.tint)
                Spacer()
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Image(systemName: "trash")
                        .font(.footnote)
                }
                .accessibilityLabel("Удалить версию без цензуры")

            case .downloading(let progress):
                VStack(alignment: .leading, spacing: 4) {
                    Text(progress.total > 0
                         ? "Скачиваю версию без цензуры · \(Int(progress.fraction * 100))%"
                         : "Скачиваю версию без цензуры…")
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    ProgressView(value: progress.fraction)
                        .tint(Theme.tint)
                }
                Button("Отменить") { store.cancelUncensored(for: item) }
                    .font(.footnote.weight(.medium))

            case .notDownloaded:
                Button {
                    store.downloadUncensored(for: item)
                } label: {
                    Label("Скачать версию без цензуры", systemImage: "lock.open")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .glass(Capsule(), interactive: true)
                }
                .buttonStyle(PressableStyle())
                Spacer(minLength: 0)

            case .unavailable:
                EmptyView()
            }
        }
        .confirmationDialog("Удалить версию без цензуры для «\(item.name)»?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { store.deleteUncensored(for: item) }
            Button("Отмена", role: .cancel) {}
        }
    }
}

// MARK: - Online

/// Placeholder for models that will run on the user's own server.
private struct OnlineModelsPlaceholder: View {
    private let categories: [(icon: String, title: String)] = [
        ("text.bubble.fill", "Текст"),
        ("chevron.left.forwardslash.chevron.right", "Код"),
        ("photo.fill", "Картинки"),
        ("music.note", "Музыка"),
        ("film.fill", "Видео")
    ]

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "server.rack")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.white)
                .frame(width: 84, height: 84)
                .glass(Circle(), tint: Theme.tint)

            VStack(spacing: 6) {
                Text("Онлайн-модели — скоро")
                    .font(.title3.weight(.semibold))
                Text("Здесь появятся модели с вашего сервера: большие и умные, которые не помещаются в телефон. Нужен интернет.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                ForEach(categories, id: \.title) { category in
                    VStack(spacing: 6) {
                        Image(systemName: category.icon)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.tint)
                        Text(category.title)
                            .font(.caption.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .glassCard(cornerRadius: 16)
                    .opacity(0.75)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .glassCard(cornerRadius: 26)
    }
}
