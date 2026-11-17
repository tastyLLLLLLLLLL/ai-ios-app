import PDFKit
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PendingPhoto: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct ChatView: View {
    @Environment(AppModel.self) private var model
    @Binding var showModels: Bool
    @State private var draft = ""
    @State private var photos: [PendingPhoto] = []
    @State private var documents: [PendingDocument] = []
    @FocusState private var inputFocused: Bool

    private var messages: [ChatMessage] {
        model.current?.messages ?? []
    }

    /// Changes whenever new text arrives, to keep the latest line in view.
    private var scrollToken: Int {
        messages.count &* 1_000_003 &+ (messages.last?.text.count ?? 0)
    }

    var body: some View {
        ZStack {
            if messages.isEmpty {
                EmptyStateView(showModels: $showModels)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                messageList
                    .id(model.currentID)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: messages.isEmpty)
        .animation(.easeInOut(duration: 0.25), value: model.currentID)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                statusPill
                InputBar(
                    draft: $draft,
                    photos: $photos,
                    documents: $documents,
                    showModels: $showModels,
                    focused: $inputFocused,
                    isGenerating: model.isGenerating,
                    canSend: model.hasActiveModel,
                    canAttachPhotos: !model.useOnline && model.models.canSeePhotos,
                    isOnline: model.useOnline,
                    onSend: {
                        let text = draft
                        let images = photos.map(\.image)
                        let files = documents
                        draft = ""
                        withAnimation(.smooth) {
                            photos = []
                            documents = []
                        }
                        model.send(text, photos: images, documents: files)
                    },
                    onStop: { model.stop() }
                )
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    ForEach(messages) { message in
                        MessageRow(
                            message: message,
                            isLast: message.id == messages.last?.id,
                            isStreaming: model.isGenerating && message.id == messages.last?.id,
                            onRegenerate: { model.regenerate() }
                        )
                        .equatable()
                        .transition(
                            .asymmetric(
                                insertion: message.role == .user
                                    ? .scale(scale: 0.8, anchor: .bottomTrailing).combined(with: .opacity)
                                    : .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity
                            )
                        )
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: scrollToken) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: inputFocused) {
                if inputFocused {
                    withAnimation(.smooth) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        if model.server.power == .starting {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Включаю сервер… обычно 1–3 минуты")
                    .font(.footnote.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassCard(cornerRadius: 18, blurred: true)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if model.server.modelLoading, model.isGenerating {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Модель загружается на сервере… до 1–2 минут")
                    .font(.footnote.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassCard(cornerRadius: 18, blurred: true)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if model.engineState == .loading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Загружаю модель в память…")
                    .font(.footnote.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassCard(cornerRadius: 18, blurred: true)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if model.settings.uncensored, messages.isEmpty {
            uncensoredPill
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Reminds that "Без цензуры" is on but its model file is not ready yet.
    @ViewBuilder
    private var uncensoredPill: some View {
        switch model.models.uncensoredState {
        case .downloading(let progress):
            Label(
                progress.total > 0
                    ? "Скачиваю версию без цензуры · \(Int(progress.fraction * 100))%"
                    : "Скачиваю версию без цензуры…",
                systemImage: "arrow.down.circle"
            )
            .font(.footnote.weight(.medium))
            .monospacedDigit()
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassCard(cornerRadius: 18, blurred: true)
        case .notDownloaded:
            Button {
                model.models.downloadUncensoredVariant()
            } label: {
                Label("Скачать версию без цензуры для этой модели", systemImage: "lock.open")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassCard(cornerRadius: 18, blurred: true)
            }
            .buttonStyle(PressableStyle())
        default:
            EmptyView()
        }
    }
}

// MARK: - Input

struct InputBar: View {
    @Binding var draft: String
    @Binding var photos: [PendingPhoto]
    @Binding var documents: [PendingDocument]
    @Binding var showModels: Bool
    var focused: FocusState<Bool>.Binding
    let isGenerating: Bool
    let canSend: Bool
    let canAttachPhotos: Bool
    /// Chats go to the user's server: the field gets a coloured outline and a cloud mark.
    let isOnline: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var showVisionHint = false
    @State private var showGallery = false
    @State private var showCamera = false
    @State private var showFiles = false
    @State private var importingDocuments = false
    @State private var fileError: String?

    private static let documentTypes: [UTType] = [.pdf, .plainText, .text, .sourceCode, .json, .commaSeparatedText, .xml, .html]

    private var cameraAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }
    private var photoSlotsLeft: Int { max(0, Self.maxPhotos - photos.count) }

    private static let maxPhotos = 3

    private var hasContent: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !photos.isEmpty || !documents.isEmpty
    }

    private var sendEnabled: Bool { isGenerating || (hasContent && canSend) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !photos.isEmpty || !documents.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(photos) { photo in
                            thumbnail(photo)
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                        ForEach(documents) { document in
                            documentChip(document)
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HStack(alignment: .bottom, spacing: 4) {
                attachButton

                TextField(placeholder, text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused(focused)
                    .disabled(!canSend)
                    .padding(.vertical, 12)

                Image(systemName: isOnline ? "cloud.fill" : "iphone")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isOnline ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.secondary.opacity(0.6)))
                    .contentTransition(.symbolEffect(.replace))
                    .padding(.bottom, 16)
                    .accessibilityLabel(isOnline ? "Модель на сервере" : "Модель на телефоне")

                Button {
                    if isGenerating { onStop() } else { onSend() }
                } label: {
                    Image(systemName: isGenerating ? "stop.fill" : "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Theme.accent, in: Circle())
                        .contentShape(Circle())
                        .opacity(sendEnabled ? 1 : 0.35)
                        .scaleEffect(sendEnabled ? 1 : 0.9)
                        .animation(.smooth, value: sendEnabled)
                }
                .buttonStyle(PressableStyle(scale: 0.88))
                .disabled(!sendEnabled)
                .padding(.trailing, 6)
                .padding(.bottom, 5)
                .accessibilityLabel(isGenerating ? "Остановить" : "Отправить")
            }
        }
        .glassCard(cornerRadius: 24, blurred: true)
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Theme.accent, lineWidth: 1.5)
                .opacity(isOnline ? 0.9 : 0)
        )
        .shadow(color: isOnline ? Theme.tint.opacity(0.28) : .black.opacity(0.12), radius: 16, y: 6)
        .animation(.smooth, value: isOnline)
        .animation(.smooth, value: photos.count + documents.count)
        .onChange(of: pickedItems) {
            let items = pickedItems
            guard !items.isEmpty else { return }
            pickedItems = []
            Task {
                for item in items {
                    guard photos.count < Self.maxPhotos else { break }
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        add(image)
                    }
                }
            }
        }
        .photosPicker(
            isPresented: $showGallery,
            selection: $pickedItems,
            maxSelectionCount: max(1, photoSlotsLeft),
            matching: .images
        )
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                add(image)
            }
            .ignoresSafeArea()
        }
        .fileImporter(
            isPresented: $showFiles,
            allowedContentTypes: importingDocuments ? Self.documentTypes : [.image],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if importingDocuments {
                    if let document = Self.readDocument(url) {
                        documents.append(document)
                    } else {
                        fileError = "Не удалось прочитать «\(url.lastPathComponent)». Подходят текстовые файлы, код и PDF с текстом."
                    }
                } else if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                    add(image)
                }
            }
        }
        .alert("Файл не прочитан", isPresented: Binding(get: { fileError != nil }, set: { if !$0 { fileError = nil } })) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text(fileError ?? "")
        }
        .alert("Эта модель не видит фото", isPresented: $showVisionHint) {
            Button("Открыть модели") { showModels = true }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Чтобы прикреплять фотографии, скачайте и выберите модель с пометкой «Видит фото»: Qwen3-VL 4B или Gemma 3 4B.")
        }
    }

    private var placeholder: String {
        guard canSend else { return "Сначала выберите модель" }
        return isOnline ? "Сообщение на сервер" : "Сообщение"
    }

    /// The "+" button: photos (for models that see them) and documents.
    private var attachButton: some View {
        Menu {
            Section("Фото") {
                if canAttachPhotos {
                    Button {
                        showGallery = true
                    } label: {
                        Label("Выбрать из галереи", systemImage: "photo.on.rectangle")
                    }
                    .disabled(photoSlotsLeft == 0)
                    if cameraAvailable {
                        Button {
                            showCamera = true
                        } label: {
                            Label("Сфотографировать", systemImage: "camera")
                        }
                        .disabled(photoSlotsLeft == 0)
                    }
                    Button {
                        importingDocuments = false
                        showFiles = true
                    } label: {
                        Label("Фото из «Файлов»", systemImage: "photo.badge.plus")
                    }
                    .disabled(photoSlotsLeft == 0)
                } else {
                    Button {
                        showVisionHint = true
                    } label: {
                        Label("Фото — нужна модель, которая видит фото", systemImage: "eye.slash")
                    }
                }
            }
            Section("Файлы") {
                Button {
                    importingDocuments = true
                    showFiles = true
                } label: {
                    Label("Документ, текст или код", systemImage: "doc.text")
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(canSend ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.secondary))
                .frame(width: 34, height: 34)
                .background(Theme.tint.opacity(canSend ? 0.14 : 0.06), in: Circle())
                .symbolEffect(.bounce, value: photos.count + documents.count)
                .padding(.leading, 7)
                .padding(.bottom, 6)
        }
        .disabled(!canSend)
        .accessibilityLabel("Добавить файл")
    }

    /// Reads a document as text: PDF through PDFKit, everything else as UTF-8 (or Windows-1251).
    private static func readDocument(_ url: URL) -> PendingDocument? {
        let name = url.lastPathComponent
        var text: String?
        if url.pathExtension.lowercased() == "pdf" {
            text = PDFDocument(url: url)?.string
        } else if let data = try? Data(contentsOf: url) {
            text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1251)
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return PendingDocument(name: name, text: text)
    }

    private func documentChip(_ document: PendingDocument) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text.fill")
                .foregroundStyle(Theme.tint)
            Text(document.name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: 140)
            Button {
                withAnimation(.smooth) { documents.removeAll { $0.id == document.id } }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(PressableStyle(scale: 0.8))
            .accessibilityLabel("Убрать файл")
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func add(_ image: UIImage) {
        guard photos.count < Self.maxPhotos else { return }
        photos.append(PendingPhoto(image: image.downscaled(maxSide: 1024)))
    }

    private func thumbnail(_ photo: PendingPhoto) -> some View {
        Image(uiImage: photo.image)
            .resizable()
            .scaledToFill()
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Button {
                    withAnimation(.smooth) {
                        photos.removeAll { $0.id == photo.id }
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(.black.opacity(0.65), in: Circle())
                }
                .buttonStyle(PressableStyle(scale: 0.8))
                .offset(x: 5, y: -5)
                .accessibilityLabel("Убрать фото")
            }
    }
}

// MARK: - Messages

/// Equatable so that rows which did not change are not redrawn on every new token.
struct MessageRow: View, Equatable {
    let message: ChatMessage
    let isLast: Bool
    let isStreaming: Bool
    let onRegenerate: () -> Void

    @State private var copied = false

    static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message == rhs.message && lhs.isLast == rhs.isLast && lhs.isStreaming == rhs.isStreaming
    }

    var body: some View {
        if message.role == .user {
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(message.imageNames, id: \.self) { name in
                    if let image = ImageStore.image(named: name) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 220, maxHeight: 260)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                            )
                    }
                }
                ForEach(message.fileNames, id: \.self) { name in
                    Label(name, systemImage: "doc.text.fill")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
                Text(message.text)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 10)
                    .background(Theme.bubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = message.text
                        } label: {
                            Label("Копировать", systemImage: "doc.on.doc")
                        }
                    }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 48)
        } else {
            assistantBody
        }
    }

    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let thinking = message.thinking {
                ThinkingView(text: thinking, inProgress: message.isThinking && isStreaming)
                    .transition(.opacity)
            }

            if message.isError {
                Label(message.text, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .transition(.opacity)
            } else if !message.answer.isEmpty {
                MarkdownView(text: message.answer)
                    .textSelection(.enabled)
                    .transition(.opacity)
            } else if isStreaming {
                if message.thinking == nil {
                    TypingDots().transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                }
            } else {
                Text("Ответ остановлен")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if !isStreaming, isLast || !message.answer.isEmpty {
                HStack(spacing: 16) {
                    if !message.answer.isEmpty {
                        Button {
                            UIPasteboard.general.string = message.answer
                            withAnimation(.smooth) { copied = true }
                            Task {
                                try? await Task.sleep(for: .seconds(1.5))
                                withAnimation(.smooth) { copied = false }
                            }
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .contentTransition(.symbolEffect(.replace))
                                .foregroundStyle(copied ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.secondary))
                        }
                        .accessibilityLabel("Копировать ответ")
                    }
                    if isLast {
                        Button(action: onRegenerate) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Ответить заново")
                    }
                    if let speed = message.tokensPerSecond {
                        Text(String(format: "%.1f ток/с", speed))
                            .monospacedDigit()
                    }
                }
                .font(.footnote)
                .buttonStyle(PressableStyle(scale: 0.85))
                .foregroundStyle(.secondary)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.25), value: isStreaming)
        .animation(.easeOut(duration: 0.25), value: message.answer.isEmpty)
    }
}

struct ThinkingView: View {
    let text: String
    let inProgress: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .symbolEffect(.pulse, isActive: inProgress)
                    Text(inProgress ? "Размышляю…" : "Размышления")
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .glassCard(cornerRadius: 14)
            }
            .buttonStyle(PressableStyle())

            if expanded {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.secondary.opacity(0.35))
                            .frame(width: 2)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

struct TypingDots: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 8, height: 8)
                    .scaleEffect(animating ? 1 : 0.5)
                    .opacity(animating ? 1 : 0.4)
                    .animation(
                        .easeInOut(duration: 0.6).repeatForever(autoreverses: true).delay(Double(index) * 0.18),
                        value: animating
                    )
            }
        }
        .padding(.vertical, 6)
        .onAppear { animating = true }
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    @Environment(AppModel.self) private var model
    @Binding var showModels: Bool

    @State private var appeared = false
    @State private var greeting = Greeting.random()

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                PixelMonster(size: 92)
                    .padding(.top, 70)
                    .scaleEffect(appeared ? 1 : 0.7)
                    .opacity(appeared ? 1 : 0)
                    .animation(.spring(response: 0.6, dampingFraction: 0.7), value: appeared)

                VStack(spacing: 8) {
                    Text(greeting.title)
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .multilineTextAlignment(.center)
                    Text(greeting.subtitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 12)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)
                .animation(.smooth.delay(0.08), value: appeared)

                Label(
                    model.useOnline ? "Работает на вашем сервере" : "Работает без интернета, всё остаётся на телефоне",
                    systemImage: model.useOnline ? "cloud.fill" : "lock.fill"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .opacity(appeared ? 1 : 0)
                .animation(.smooth.delay(0.14), value: appeared)

                if !model.hasActiveModel {
                    noModelCard
                        .padding(.top, 8)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 16)
                        .animation(.smooth.delay(0.18), value: appeared)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            greeting = Greeting.random()
            appeared = true
        }
    }

    private var noModelCard: some View {
        VStack(spacing: 14) {
            Text(model.models.downloads.isEmpty ? "Нейросеть ещё не скачана" : "Нейросеть скачивается…")
                .font(.headline)
            Text("Модель скачивается один раз (около 2,5 ГБ, лучше по Wi-Fi). После этого интернет больше не нужен.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showModels = true
            } label: {
                Text(model.models.downloads.isEmpty ? "Выбрать и скачать модель" : "Посмотреть загрузку")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(PressableStyle())
        }
        .padding(18)
        .glassCard()
    }
}

// MARK: - Camera

/// The system camera, used to take a photo for a message.
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage, dismiss: { dismiss() })
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onImage: (UIImage) -> Void
        private let dismiss: () -> Void

        init(onImage: @escaping (UIImage) -> Void, dismiss: @escaping () -> Void) {
            self.onImage = onImage
            self.dismiss = dismiss
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onImage(image)
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}

// MARK: - Greeting

/// Greeting on the empty chat screen, depending on the time of day.
struct Greeting {
    let title: String
    let subtitle: String

    static func random(at date: Date = Date()) -> Greeting {
        let hour = Calendar.current.component(.hour, from: date)
        let options: [(String, String)]
        switch hour {
        case 5..<12:
            options = [
                ("Доброе утро", "С чего начнём день?"),
                ("Доброе утро ☀️", "Чем могу помочь?"),
                ("Утро — время идей", "О чём подумаем?"),
                ("Доброе утро", "Кофе уже есть? Тогда за дело")
            ]
        case 12..<18:
            options = [
                ("Добрый день", "Чем займёмся?"),
                ("Добрый день", "Что будем делать сегодня?"),
                ("Привет!", "Над чем поработаем?"),
                ("Хороший день", "чтобы что-нибудь придумать")
            ]
        case 18..<23:
            options = [
                ("Добрый вечер", "Как прошёл день?"),
                ("Добрый вечер 🌙", "Чем помочь?"),
                ("Вечер — время подумать", "О чём поговорим?"),
                ("Добрый вечер", "Что обсудим?")
            ]
        default:
            options = [
                ("Доброй ночи", "Не спится?"),
                ("Ночь — время идей", "О чём подумаем?"),
                ("Доброй ночи 🌌", "Я здесь, если нужно"),
                ("Поздновато", "но я всегда на связи")
            ]
        }
        let pick = options.randomElement() ?? options[0]
        return Greeting(title: pick.0, subtitle: pick.1)
    }
}
