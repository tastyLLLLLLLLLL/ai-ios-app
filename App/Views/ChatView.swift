import PhotosUI
import SwiftUI
import UIKit

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
                            isGenerating: model.isGenerating,
                            onRegenerate: { model.regenerate() }
                        )
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
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
            .glassCard(cornerRadius: 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
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
                        .background(Theme.accent, in: Circle())
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
        .glassCard(cornerRadius: 24)
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
                        photos.append(PendingPhoto(image: image.downscaled(maxSide: 1024)))
                    }
                }
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
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(canAttachPhotos ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.secondary))
            .frame(width: 40, height: 36)
            .padding(.leading, 6)
            .padding(.bottom, 5)

        if canAttachPhotos {
            PhotosPicker(
                selection: $pickedItems,
                maxSelectionCount: Self.maxPhotos,
                matching: .images
            ) {
                icon
            }
            .buttonStyle(PressableStyle(scale: 0.88))
            .disabled(photos.count >= Self.maxPhotos)
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

struct MessageRow: View {
    let message: ChatMessage
    let isLast: Bool
    let isGenerating: Bool
    let onRegenerate: () -> Void

    @State private var copied = false

    private var isStreaming: Bool { isLast && isGenerating }

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
                OrbLogo(size: 96)
                    .padding(.top, 48)
                    .scaleEffect(appeared ? 1 : 0.7)
                    .opacity(appeared ? 1 : 0)
                    .animation(.spring(response: 0.6, dampingFraction: 0.7), value: appeared)

                VStack(spacing: 8) {
                    Text("Чем помочь?")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
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
                                .glassCard(cornerRadius: 18)
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
