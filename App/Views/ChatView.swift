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
                EmptyStateView(showModels: $showModels) { suggestion in
                    model.send(suggestion)
                }
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
                    showModels: $showModels,
                    focused: $inputFocused,
                    isGenerating: model.isGenerating,
                    canSend: model.models.selectedFile != nil,
                    canAttachPhotos: model.models.canSeePhotos,
                    onSend: {
                        let text = draft
                        let images = photos.map(\.image)
                        draft = ""
                        withAnimation(.smooth) { photos = [] }
                        model.send(text, photos: images)
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
        if model.engineState == .loading {
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
                    .glassCard(cornerRadius: 18, blurred: true, interactive: true)
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
    @Binding var showModels: Bool
    var focused: FocusState<Bool>.Binding
    let isGenerating: Bool
    let canSend: Bool
    let canAttachPhotos: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var showVisionHint = false
    @State private var showGallery = false
    @State private var showCamera = false
    @State private var showFiles = false

    private var cameraAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }
    private var photoSlotsLeft: Int { max(0, Self.maxPhotos - photos.count) }

    private static let maxPhotos = 3

    private var hasContent: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !photos.isEmpty
    }

    private var sendEnabled: Bool { isGenerating || (hasContent && canSend) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(photos) { photo in
                            thumbnail(photo)
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

                TextField(canSend ? "Сообщение" : "Сначала скачайте модель", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused(focused)
                    .disabled(!canSend)
                    .padding(.vertical, 12)

                Button {
                    if isGenerating { onStop() } else { onSend() }
                } label: {
                    Image(systemName: isGenerating ? "stop.fill" : "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .glass(Circle(), tint: Theme.tint, interactive: true)
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
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        .animation(.smooth, value: photos.count)
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
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                    add(image)
                }
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
        }
        .alert("Эта модель не видит фото", isPresented: $showVisionHint) {
            Button("Открыть модели") { showModels = true }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Чтобы прикреплять фотографии, скачайте и выберите модель с пометкой «Видит фото»: Qwen3-VL 4B или Gemma 3 4B.")
        }
    }

    @ViewBuilder
    private var attachButton: some View {
        let icon = Image(systemName: "photo.on.rectangle.angled")
            .symbolEffect(.bounce, value: photos.count)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(canAttachPhotos ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.secondary))
            .frame(width: 40, height: 36)
            .padding(.leading, 6)
            .padding(.bottom, 5)

        if canAttachPhotos {
            Menu {
                Button {
                    showGallery = true
                } label: {
                    Label("Выбрать из галереи", systemImage: "photo.on.rectangle")
                }
                if cameraAvailable {
                    Button {
                        showCamera = true
                    } label: {
                        Label("Сфотографировать", systemImage: "camera")
                    }
                }
                Button {
                    showFiles = true
                } label: {
                    Label("Выбрать из «Файлов»", systemImage: "folder")
                }
            } label: {
                icon
            }
            .disabled(photoSlotsLeft == 0)
            .accessibilityLabel("Прикрепить фото")
        } else {
            Button {
                showVisionHint = true
            } label: {
                icon
            }
            .buttonStyle(PressableStyle(scale: 0.88))
            .disabled(!canSend)
            .accessibilityLabel("Прикрепить фото")
        }
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
    let onSuggestion: (String) -> Void

    @State private var appeared = false

    private struct Suggestion: Identifiable {
        let icon: String
        let text: String
        var id: String { text }
    }

    private let suggestions = [
        Suggestion(icon: "lightbulb", text: "Объясни простыми словами, как работает нейросеть"),
        Suggestion(icon: "envelope", text: "Помоги написать вежливое письмо с отказом"),
        Suggestion(icon: "fork.knife", text: "Придумай ужин из курицы, риса и овощей"),
        Suggestion(icon: "globe", text: "Переведи на английский: «Рад знакомству!»")
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                OrbLogo(size: 60)
                    .padding(.top, 48)
                    .scaleEffect(appeared ? 1 : 0.7)
                    .opacity(appeared ? 1 : 0)
                    .animation(.spring(response: 0.6, dampingFraction: 0.7), value: appeared)

                VStack(spacing: 8) {
                    Text("Чем помочь?")
                        .font(.system(.title, design: .rounded).weight(.bold))
                    Label("Работает без интернета, всё остаётся на телефоне", systemImage: "lock.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)
                .animation(.smooth.delay(0.08), value: appeared)

                if model.models.selectedFile == nil {
                    noModelCard
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 16)
                        .animation(.smooth.delay(0.16), value: appeared)
                } else {
                    VStack(spacing: 10) {
                        ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                            Button {
                                onSuggestion(suggestion.text)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: suggestion.icon)
                                        .foregroundStyle(Theme.accent)
                                        .frame(width: 24)
                                    Text(suggestion.text)
                                        .font(.subheadline)
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                }
                                .padding(14)
                                .glassCard(cornerRadius: 18, interactive: true)
                            }
                            .buttonStyle(PressableStyle())
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 16)
                            .animation(.smooth.delay(0.14 + Double(index) * 0.06), value: appeared)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { appeared = true }
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
