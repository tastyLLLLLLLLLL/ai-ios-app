import AVKit
import SwiftUI
import UIKit

/// Creates images, video and music on the user's server and shows the results.
struct StudioView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var kind: MediaKind = .image
    @State private var prompt = ""
    @State private var lyrics = ""
    @State private var selectedModel: [MediaKind: String] = [:]
    @State private var imageSize = ImageSize.square
    @State private var videoSeconds = 3
    @State private var videoFast = false
    @State private var musicSeconds = 60
    @State private var sending = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var server: ServerStore { model.server }

    enum ImageSize: String, CaseIterable, Identifiable {
        case square, portrait, landscape
        var id: String { rawValue }
        var title: String {
            switch self {
            case .square: return "Квадрат"
            case .portrait: return "Портрет"
            case .landscape: return "Альбом"
            }
        }
        var size: (Int, Int) {
            switch self {
            case .square: return (1024, 1024)
            case .portrait: return (832, 1216)
            case .landscape: return (1216, 832)
            }
        }
    }

    private var models: [MediaModel] { server.media(of: kind) }

    private var currentModelID: String? {
        if let chosen = selectedModel[kind], models.contains(where: { $0.id == chosen }) { return chosen }
        return models.first?.id
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Что создать", selection: $kind.animation(.smooth)) {
                        ForEach(MediaKind.allCases) { item in
                            Label(item.title, systemImage: item.icon).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)

                    if models.isEmpty {
                        Text("Для раздела «\(kind.title)» на сервере пока нет модели. Дождитесь окончания установки или запустите скрипт установки ещё раз.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassCard(cornerRadius: 20)
                    } else {
                        composer
                    }

                    resultsSection
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .dismissesKeyboardOnTap()
            .background(ScreenBackground())
            .navigationTitle("Студия")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .task {
                await server.refreshJobs()
            }
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Модель").font(.subheadline.weight(.semibold))
                Spacer()
                Picker("Модель", selection: Binding(
                    get: { currentModelID ?? "" },
                    set: { selectedModel[kind] = $0 }
                )) {
                    ForEach(models) { item in
                        Text(item.name).tag(item.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            if let summary = models.first(where: { $0.id == currentModelID })?.summary {
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(kind == .music ? "Стиль музыки" : "Описание")
                    .font(.subheadline.weight(.semibold))
                TextField(placeholder, text: $prompt, axis: .vertical)
                    .lineLimit(3...8)
                    .focused($focused)
                    .padding(12)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text("Можно писать по-русски — сервер сам переведёт описание на английский.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            options

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button {
                create()
            } label: {
                HStack(spacing: 8) {
                    if sending {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "wand.and.stars")
                    }
                    Text(sending ? "Отправляю…" : buttonTitle)
                }
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .accentButtonLabel(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: GlassSupport.active ? .clear : Theme.tint.opacity(0.35), radius: 10, y: 4)
            }
            .liquidButton(prominent: true, shape: .rounded(18))
            .disabled(sending || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)

            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .glassCard(cornerRadius: 24)
    }

    @ViewBuilder
    private var options: some View {
        switch kind {
        case .image:
            Picker("Формат", selection: $imageSize) {
                ForEach(ImageSize.allCases) { size in
                    Text(size.title).tag(size)
                }
            }
            .pickerStyle(.segmented)
        case .video:
            VStack(alignment: .leading, spacing: 8) {
                Picker("Длительность", selection: $videoSeconds) {
                    Text("2 сек").tag(2)
                    Text("3 сек").tag(3)
                    Text("5 сек").tag(5)
                }
                .pickerStyle(.segmented)
                Toggle("Быстрее, но ниже качество (480p)", isOn: $videoFast)
                    .font(.subheadline)
            }
        case .music:
            VStack(alignment: .leading, spacing: 8) {
                Picker("Длительность", selection: $musicSeconds) {
                    Text("30 сек").tag(30)
                    Text("1 мин").tag(60)
                    Text("2 мин").tag(120)
                }
                .pickerStyle(.segmented)
                Text("Текст песни (необязательно)")
                    .font(.subheadline.weight(.semibold))
                TextField("[verse]\nПервая строка…\n[chorus]\nПрипев…", text: $lyrics, axis: .vertical)
                    .lineLimit(3...10)
                    .padding(12)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text("Без текста получится инструментал. Разметка [verse] и [chorus] помогает разделить куплет и припев.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var placeholder: String {
        switch kind {
        case .image: return "Например: рыжий кот в скафандре на Луне, акварель"
        case .video: return "Например: волны разбиваются о скалы на закате, съёмка с дрона"
        case .music: return "Например: энергичный поп-рок, женский вокал, гитара, барабаны"
        }
    }

    private var buttonTitle: String {
        switch kind {
        case .image: return "Нарисовать"
        case .video: return "Создать видео"
        case .music: return "Сочинить музыку"
        }
    }

    private var hint: String {
        switch kind {
        case .image: return "Картинка обычно готова за 10–60 секунд."
        case .video: return "Видео считается несколько минут. Можно закрыть студию — результат появится здесь."
        case .music: return "Музыка обычно готова за 1–3 минуты."
        }
    }

    private func create() {
        guard let modelID = currentModelID else { return }
        focused = false
        sending = true
        error = nil
        var options: [String: Any] = [:]
        switch kind {
        case .image:
            options["width"] = imageSize.size.0
            options["height"] = imageSize.size.1
        case .video:
            options["seconds"] = videoSeconds
            options["width"] = videoFast ? 832 : 1280
            options["height"] = videoFast ? 480 : 704
        case .music:
            options["seconds"] = musicSeconds
            options["lyrics"] = lyrics
        }
        let text = prompt
        Task {
            do {
                try await server.createJob(kind: kind, model: modelID, prompt: text, options: options)
                withAnimation(.smooth) { prompt = "" }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            } catch {
                withAnimation(.smooth) { self.error = error.localizedDescription }
            }
            sending = false
        }
    }

    // MARK: Results

    @ViewBuilder
    private var resultsSection: some View {
        let items = server.jobs(of: kind)
        if !items.isEmpty {
            Text("Готовые работы")
                .font(.headline)
                .padding(.top, 6)
                .padding(.horizontal, 4)
            LazyVStack(spacing: 12) {
                ForEach(items) { job in
                    JobCard(job: job)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .animation(.smooth, value: items.map(\.id))
        }
    }
}

// MARK: - Job card

private struct JobCard: View {
    @Environment(AppModel.self) private var model
    let job: ServerJob

    @State private var fileURL: URL?
    @State private var image: UIImage?
    @State private var loadError: String?
    @State private var confirmDelete = false
    @State private var playback: MediaPlayback?
    @State private var fullScreen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(job.modelName)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.tint.opacity(0.15), in: Capsule())
                Text(job.createdDate.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Image(systemName: "trash")
                        .font(.footnote)
                }
                .accessibilityLabel("Удалить")
            }

            Text(job.prompt)
                .font(.subheadline)
                .lineLimit(3)

            if let english = job.englishPrompt, english != job.prompt {
                Label {
                    Text("Модель получила: \(english)")
                        .lineLimit(4)
                } icon: {
                    Image(systemName: "character.bubble")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }

            content
        }
        .padding(14)
        .glassCard(cornerRadius: 22)
        .task(id: job.status) {
            await loadIfReady()
        }
        .confirmationDialog("Удалить эту работу?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                playback?.pause()
                Task { await model.server.deleteJob(job) }
            }
            Button("Отмена", role: .cancel) {}
        }
        .onDisappear { playback?.pause() }
        .fullScreenCover(isPresented: $fullScreen, onDismiss: { playback?.syncState() }) {
            if let playback { FullScreenVideo(playback: playback) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch job.status {
        case "queued", "running":
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: job.progress)
                    .tint(Theme.tint)
                    .animation(.linear(duration: 0.4), value: job.progress)
                Text(job.status == "queued" ? "В очереди…" : "Создаётся · \(Int(job.progress * 100))%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        case "failed":
            Label(job.error ?? "Не получилось", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
        default:
            result
        }
    }

    @ViewBuilder
    private var result: some View {
        if let loadError {
            Label(loadError, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
        } else if let fileURL {
            VStack(alignment: .leading, spacing: 10) {
                switch job.kind {
                case "image":
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                case "video":
                    if let playback {
                        VideoSurface(player: playback.player)
                            .aspectRatio(playback.aspectRatio ?? 16 / 9, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay {
                                if !playback.isPlaying {
                                    Image(systemName: "play.fill")
                                        .font(.title)
                                        .foregroundStyle(.white)
                                        .frame(width: 64, height: 64)
                                        .background(.black.opacity(0.45), in: Circle())
                                        .allowsHitTesting(false)
                                        .transition(.opacity)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { playback.toggle() } }
                        MediaControls(playback: playback, onFullScreen: {
                            playback.pause()
                            fullScreen = true
                        })
                    }
                default:
                    if let playback {
                        MediaControls(playback: playback)
                    }
                }

                ShareLink(item: fileURL) {
                    Label("Сохранить или поделиться", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .plainButtonLabel(Capsule())
                }
                .liquidButton(prominent: false, shape: .capsule)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView()
                Text("Загружаю результат…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func loadIfReady() async {
        guard job.status == "done", fileURL == nil, !job.outputs.isEmpty else { return }
        do {
            let url = try await model.server.file(for: job, index: 0)
            if job.kind == "image" {
                image = await Task.detached { UIImage(contentsOfFile: url.path)?.preparingForDisplay() }.value
            } else {
                playback = MediaPlayback(url: url)
            }
            withAnimation(.smooth) { fileURL = url }
        } catch {
            loadError = error.localizedDescription
        }
    }
}
