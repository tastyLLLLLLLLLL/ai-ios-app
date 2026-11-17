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
                Section {
                    Toggle(isOn: $model.settings.uncensored) {
                        Label {
                            Text("Без цензуры")
                        } icon: {
                            Image(systemName: model.settings.uncensored ? "lock.open.fill" : "lock.fill")
                                .contentTransition(.symbolEffect(.replace))
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
                    Toggle("Режим размышлений", isOn: $model.settings.thinkingEnabled)
                } footer: {
                    Text("Модель сначала обдумывает задачу, потом отвечает. Ответы точнее, но приходят медленнее. Работает с моделями Qwen3 и другими «думающими».")
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
                Text("Это отдельный файл модели размером около 2,5 ГБ. Скачивается один раз, лучше по Wi-Fi. Пока он не скачан, действует только инструкция отвечать без отказов.")
            }
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
                    .tint(Theme.blue)
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
                    Label("Скачать (≈ 2,5 ГБ)", systemImage: "arrow.down.circle.fill")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.borderless)
            }

        case .unavailable:
            Text("Для выбранной модели нет версии без ограничений — действует только инструкция, и модель может отказывать. Версии без ограничений есть у Qwen3 4B и Gemma 3 4B.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
