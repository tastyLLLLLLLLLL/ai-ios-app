import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDeleteChats = false

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
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
                                .foregroundStyle(.secondary)
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
                        model.settings.systemPrompt = AppSettings.defaultSystemPrompt
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
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .onChange(of: model.settings) {
                model.settings.save()
            }
            .confirmationDialog("Удалить все чаты без возможности восстановить?", isPresented: $confirmDeleteChats, titleVisibility: .visible) {
                Button("Удалить все", role: .destructive) { model.deleteAllChats() }
                Button("Отмена", role: .cancel) {}
            }
        }
    }
}
