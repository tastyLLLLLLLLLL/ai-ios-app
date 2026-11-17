import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDeleteChats = false
    @State private var confirmUncensoredDownload = false

    private var uncensoredState: UncensoredState { model.models.uncensoredState }

    /// Collapses download progress into one value so only real state changes animate.
    private var uncensoredKind: Int {
        switch uncensoredState {
        case .unavailable: return 0
        case .notDownloaded: return 1
        case .downloading: return 2
        case .ready: return 3
        }
    }

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
                themeSection

                Section {
                    Toggle(isOn: $model.settings.uncensored) {
                        Label {
                            Text("Без цензуры")
                        } icon: {
                            Image(systemName: model.settings.uncensored ? "lock.open.fill" : "lock.fill")
                                .contentTransition(.symbolEffect(.replace))
                                .symbolEffect(.bounce, value: model.settings.uncensored)
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    if model.settings.uncensored {
                        uncensoredStatus
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                } footer: {
                    Text("Модель перестаёт отказываться отвечать и не добавляет предупреждений. Для этого используется версия той же модели со снятыми ограничениями — её нужно один раз скачать. За то, как использовать ответы, отвечаете вы.")
                }

                Section {
                    Toggle(isOn: $model.settings.thinkingEnabled) {
                        Label {
                            Text("Режим размышлений")
                        } icon: {
                            Image(systemName: "brain")
                                .symbolEffect(.bounce, value: model.settings.thinkingEnabled)
                                .foregroundStyle(Theme.accent)
                        }
                    }
                } footer: {
                    Text("Модель сначала обдумывает задачу, потом отвечает. Ответы точнее, но приходят медленнее. Работает с моделями Qwen3; DeepSeek R1 рассуждает всегда.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Креативность")
                            Spacer()
                            Text(String(format: "%.1f", model.settings.temperature))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .foregroundStyle(.secondary)
                                .animation(.snappy, value: model.settings.temperature)
                        }
                        Slider(value: $model.settings.temperature, in: 0...1.5, step: 0.1)
                    }
                } footer: {
                    Text("Ниже — ответы точнее и предсказуемее, выше — разнообразнее.")
                }

                Section {
                    Picker("Память разговора", selection: $model.settings.contextSize) {
                        Text("Небольшая").tag(2048)
                        Text("Обычная").tag(4096)
                        Text("Большая").tag(8192)
                    }
                    Picker("Длина ответа", selection: $model.settings.maxResponseTokens) {
                        Text("Короткая").tag(512)
                        Text("Обычная").tag(1024)
                        Text("Длинная").tag(2048)
                        Text("Очень длинная").tag(4096)
                    }
                } footer: {
                    Text("Чем больше память разговора, тем дольше модель помнит начало чата, но тем больше оперативной памяти ей нужно. Если приложение закрывается само — выберите вариант поменьше.")
                }

                Section {
                    TextEditor(text: $model.settings.systemPrompt)
                        .frame(minHeight: 110)
                    Button("Вернуть стандартные") {
                        withAnimation(.smooth) {
                            model.settings.systemPrompt = AppSettings.defaultSystemPrompt
                        }
                    }
                } header: {
                    Text("Инструкции для модели")
                } footer: {
                    Text("Опишите, как модель должна себя вести: стиль, язык, роль.")
                }

                Section {
                    Button("Удалить все чаты", role: .destructive) {
                        confirmDeleteChats = true
                    }
                }
            }
            .animation(.easeInOut(duration: 0.5), value: ThemeStore.shared.palette.id)
            .animation(.smooth, value: model.settings.uncensored)
            .animation(.smooth, value: uncensoredKind)
            .sensoryFeedback(.selection, trigger: model.settings.uncensored)
            .sensoryFeedback(.selection, trigger: model.settings.thinkingEnabled)
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .onChange(of: model.settings) { old, new in
                new.save()
                if new.uncensored, !old.uncensored, uncensoredState == .notDownloaded {
                    confirmUncensoredDownload = true
                }
            }
            .confirmationDialog("Удалить все чаты без возможности восстановить?", isPresented: $confirmDeleteChats, titleVisibility: .visible) {
                Button("Удалить все", role: .destructive) { model.deleteAllChats() }
                Button("Отмена", role: .cancel) {}
            }
            .alert("Скачать версию без ограничений?", isPresented: $confirmUncensoredDownload) {
                Button("Скачать") { model.models.downloadUncensoredVariant() }
                Button("Не сейчас", role: .cancel) {}
            } message: {
                Text("Это отдельный файл того же размера, что и сама модель. Скачивается один раз, лучше по Wi-Fi. Пока он не скачан, действует только инструкция отвечать без отказов.")
            }
        }
    }

    private var themeSection: some View {
        let theme = ThemeStore.shared
        return Section {
            Picker("Режим", selection: Binding(
                get: { theme.appearance },
                set: { theme.setAppearance($0) }
            )) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(Palette.all) { palette in
                        let isSelected = palette.id == theme.palette.id
                        Button {
                            withAnimation(.easeInOut(duration: 0.5)) { theme.setPalette(palette.id) }
                        } label: {
                            VStack(spacing: 6) {
                                Circle()
                                    .fill(palette.gradient)
                                    .frame(width: 46, height: 46)
                                    .overlay {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 16, weight: .bold))
                                            .foregroundStyle(.white)
                                            .scaleEffect(isSelected ? 1 : 0.3)
                                            .opacity(isSelected ? 1 : 0)
                                    }
                                    .padding(4)
                                    .overlay {
                                        Circle()
                                            .strokeBorder(palette.tint, lineWidth: 2)
                                            .opacity(isSelected ? 1 : 0)
                                    }
                                    .scaleEffect(isSelected ? 1 : 0.92)
                                    .animation(.spring(response: 0.4, dampingFraction: 0.55), value: isSelected)
                                Text(palette.name)
                                    .font(.caption2.weight(isSelected ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                            }
                        }
                        .buttonStyle(PressableStyle(scale: 0.9))
                        .accessibilityLabel("Тема \(palette.name)")
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 2)
            }
            .sensoryFeedback(.selection, trigger: theme.palette.id)

            Toggle(isOn: Binding(
                get: { model.settings.pauseMotionWhileAnswering },
                set: { model.settings.pauseMotionWhileAnswering = $0 }
            )) {
                Label {
                    Text("Замирать во время ответа")
                } icon: {
                    Image(systemName: model.settings.pauseMotionWhileAnswering ? "pause.circle.fill" : "play.circle.fill")
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(Theme.accent)
                }
            }
        } header: {
            Text("Темы")
        } footer: {
            Text("Светлый или тёмный режим и цвет оформления. «Замирать во время ответа» останавливает движение фона, пока нейросеть пишет ответ, чтобы графический чип был занят только ей.")
        }
    }

    @ViewBuilder
    private var uncensoredStatus: some View {
        switch uncensoredState {
        case .ready:
            Label("Используется версия без ограничений", systemImage: "checkmark.circle.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.accent)

        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(progress.total > 0
                         ? "Скачиваю версию без ограничений · \(Int(progress.fraction * 100))%"
                         : "Скачиваю версию без ограничений…")
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Отменить") { model.models.cancelUncensoredDownload() }
                        .font(.footnote.weight(.medium))
                        .buttonStyle(.borderless)
                }
                ProgressView(value: progress.fraction)
                    .tint(Theme.tint)
                    .animation(.linear(duration: 0.3), value: progress.fraction)
            }

        case .notDownloaded:
            VStack(alignment: .leading, spacing: 8) {
                Text("Версия без ограничений ещё не скачана — пока действует только инструкция, и модель может отказывать.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    model.models.downloadUncensoredVariant()
                } label: {
                    Label("Скачать версию без ограничений", systemImage: "arrow.down.circle.fill")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.borderless)
            }

        case .unavailable:
            Text("Для выбранной модели нет версии без ограничений — действует только инструкция, и модель может отказывать. Версии без ограничений есть у Qwen3 4B, Qwen3 8B и Gemma 3 4B.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
