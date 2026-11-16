import SwiftUI
import UIKit

struct ChatView: View {
    @Environment(AppModel.self) private var model
    @Binding var showModels: Bool
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    private var messages: [ChatMessage] {
        model.current?.messages ?? []
    }

    /// Changes whenever new text arrives, to keep the latest line in view.
    private var scrollToken: Int {
        messages.count &* 1_000_003 &+ (messages.last?.text.count ?? 0)
    }

    var body: some View {
        Group {
            if messages.isEmpty {
                EmptyStateView(showModels: $showModels) { suggestion in
                    model.send(suggestion)
                }
            } else {
                messageList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                statusPill
                InputBar(
                    draft: $draft,
                    focused: $inputFocused,
                    isGenerating: model.isGenerating,
                    canSend: model.models.selectedFile != nil,
                    onSend: {
                        let text = draft
                        draft = ""
                        model.send(text)
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
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
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
            .transition(.opacity)
        }
    }
}

// MARK: - Input

struct InputBar: View {
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    let isGenerating: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    private var hasText: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(canSend ? "Сообщение" : "Сначала скачайте модель", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .focused(focused)
                .disabled(!canSend)
                .padding(.leading, 16)
                .padding(.vertical, 12)

            Button {
                if isGenerating { onStop() } else { onSend() }
            } label: {
                Image(systemName: isGenerating ? "stop.fill" : "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Theme.accent, in: Circle())
                    .opacity(isGenerating || (hasText && canSend) ? 1 : 0.35)
            }
            .disabled(!isGenerating && !(hasText && canSend))
            .padding(.trailing, 6)
            .padding(.bottom, 5)
            .accessibilityLabel(isGenerating ? "Остановить" : "Отправить")
        }
        .glassCard(cornerRadius: 24)
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
    }
}

// MARK: - Messages

struct MessageRow: View {
    let message: ChatMessage
    let isLast: Bool
    let isGenerating: Bool
    let onRegenerate: () -> Void

    private var isStreaming: Bool { isLast && isGenerating }

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 48)
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
        } else {
            assistantBody
        }
    }

    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let thinking = message.thinking {
                ThinkingView(text: thinking, inProgress: message.isThinking && isStreaming)
            }

            if message.isError {
                Label(message.text, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            } else if !message.answer.isEmpty {
                MarkdownView(text: message.answer)
                    .textSelection(.enabled)
            } else if isStreaming {
                if message.thinking == nil { TypingDots() }
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
                        } label: {
                            Image(systemName: "doc.on.doc")
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
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            .buttonStyle(.plain)

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

                VStack(spacing: 8) {
                    Text("Чем помочь?")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    Label("Работает без интернета, всё остаётся на телефоне", systemImage: "lock.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if model.models.selectedFile == nil {
                    noModelCard
                } else {
                    VStack(spacing: 10) {
                        ForEach(suggestions) { suggestion in
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
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
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
            .buttonStyle(.plain)
        }
        .padding(18)
        .glassCard()
    }
}
