import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDeleteChats = false
    @State private var appeared = false
    @State private var notificationsDenied = false

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
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    themeSection

                    SettingsSection(
                        footer: "Модель перестаёт отказываться отвечать и не добавляет предупреждений. Для этого используется версия той же модели со снятыми ограничениями — она скачивается один раз. За то, как использовать ответы, отвечаете вы."
                    ) {
                        Toggle(isOn: $model.settings.uncensored) {
                            SettingsLabel(
                                title: "Без цензуры",
                                icon: model.settings.uncensored ? "lock.open.fill" : "lock.fill",
                                bounce: model.settings.uncensored
                            )
                        }
                        if model.settings.uncensored {
                            uncensoredStatus
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }

                    SettingsSection(
                        footer: "Придёт уведомление, когда скачается модель. Если свернуть приложение во время ответа, iPhone ставит нейросеть на паузу — придёт напоминание, а когда вернётесь, ответ допишется сам. Пока идёт ответ, экран не гаснет."
                    ) {
                        Toggle(isOn: $model.settings.notificationsEnabled) {
                            SettingsLabel(
                                title: "Уведомления",
                                icon: model.settings.notificationsEnabled ? "bell.badge.fill" : "bell.fill",
                                bounce: model.settings.notificationsEnabled
                            )
                        }
                    }

                    SettingsSection(
                        footer: "Модель сначала обдумывает задачу, потом отвечает. Ответы точнее, но приходят медленнее. Работает с моделями Qwen3."
                    ) {
                        Toggle(isOn: $model.settings.thinkingEnabled) {
                            SettingsLabel(title: "Режим размышлений", icon: "brain", bounce: model.settings.thinkingEnabled)
                        }
                    }

                    SettingsSection(footer: "Ниже — ответы точнее и предсказуемее, выше — разнообразнее.") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                SettingsLabel(title: "Креативность", icon: "wand.and.stars", bounce: false)
                                Spacer()
                                Text(String(format: "%.1f", model.settings.temperature))
                                    .monospacedDigit()
                                    .contentTransition(.numericText())
                                    .foregroundStyle(.secondary)
                                    .animation(.snappy, value: model.settings.temperature)
                            }
                            Slider(value: $model.settings.temperature, in: 0...1.5, step: 0.1)
                        }
                    }

                    SettingsSection(
                        footer: "Чем больше память разговора, тем дольше модель помнит начало чата, но тем больше оперативной памяти ей нужно. Если приложение закрывается само — выберите вариант поменьше."
                    ) {
                        HStack {
                            SettingsLabel(title: "Память разговора", icon: "memorychip", bounce: false)
                            Spacer()
                            Picker("Память разговора", selection: $model.settings.contextSize) {
                                Text("Небольшая").tag(2048)
                                Text("Обычная").tag(4096)
                                Text("Большая").tag(8192)
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                        Divider()
                        HStack {
                            SettingsLabel(title: "Длина ответа", icon: "text.alignleft", bounce: false)
                            Spacer()
                            Picker("Длина ответа", selection: $model.settings.maxResponseTokens) {
                                Text("Короткая").tag(512)
                                Text("Обычная").tag(1024)
                                Text("Длинная").tag(2048)
                                Text("Очень длинная").tag(4096)
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                    }

                    SettingsSection(
                        header: "Инструкции для модели",
                        footer: "Опишите, как модель должна себя вести: стиль, язык, роль."
                    ) {
                        TextEditor(text: $model.settings.systemPrompt)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 110)
                        Divider()
                        Button {
                            withAnimation(.smooth) {
                                model.settings.systemPrompt = AppSettings.defaultSystemPrompt
                            }
                        } label: {
                            Label("Вернуть стандартные", systemImage: "arrow.uturn.backward")
                                .font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(PressableStyle())
                    }

                    Button {
                        confirmDeleteChats = true
                    } label: {
                        Label("Удалить все чаты", systemImage: "trash")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .glassCard(cornerRadius: 20, interactive: true)
                    }
                    .buttonStyle(PressableStyle(scale: 0.97))
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 30)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)
                .animation(.easeOut(duration: 0.25), value: appeared)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AuroraBackground())
            .tint(Theme.tint)
            .onAppear { appeared = true }
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
                // Turning the switch on starts the download right away, so it cannot be missed.
                if new.uncensored, !old.uncensored, uncensoredState == .notDownloaded {
                    model.models.downloadUncensoredVariant()
                }
                if new.notificationsEnabled, !old.notificationsEnabled {
                    Task {
                        if !(await NotificationService.shared.requestPermission()) {
                            model.settings.notificationsEnabled = false
                            notificationsDenied = true
                        }
                    }
                }
            }
            .alert("Уведомления выключены", isPresented: $notificationsDenied) {
                Button("Открыть настройки iPhone") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Разрешите уведомления для Pocket AI в настройках iPhone.")
            }
            .confirmationDialog("Удалить все чаты без возможности восстановить?", isPresented: $confirmDeleteChats, titleVisibility: .visible) {
                Button("Удалить все", role: .destructive) { model.deleteAllChats() }
                Button("Отмена", role: .cancel) {}
            }
        }
    }

    private var themeSection: some View {
        let theme = ThemeStore.shared
        return SettingsSection(
            header: "Темы",
            footer: "«Замирать во время ответа» останавливает движение фона, пока нейросеть пишет ответ, чтобы графический чип был занят только ей."
        ) {
            Picker("Режим", selection: Binding(
                get: { theme.appearance },
                set: { theme.setAppearance($0) }
            )) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text("Цвет оформления")
                .font(.subheadline.weight(.medium))
                .padding(.top, 4)
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
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }
            .sensoryFeedback(.selection, trigger: theme.palette.id)

            Divider()

            Text("Иконка приложения")
                .font(.subheadline.weight(.medium))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(Palette.all) { palette in
                        let isSelected = palette.id == theme.iconID
                        Button {
                            theme.setIcon(palette.id)
                        } label: {
                            Image("IconPreview-\(palette.id)")
                                .resizable()
                                .frame(width: 52, height: 52)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .padding(4)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .strokeBorder(palette.tint, lineWidth: 2)
                                        .opacity(isSelected ? 1 : 0)
                                }
                                .scaleEffect(isSelected ? 1 : 0.92)
                                .animation(.spring(response: 0.4, dampingFraction: 0.55), value: isSelected)
                        }
                        .buttonStyle(PressableStyle(scale: 0.9))
                        .accessibilityLabel("Иконка \(palette.name)")
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }

            Divider()

            Toggle(isOn: Binding(
                get: { model.settings.pauseMotionWhileAnswering },
                set: { model.settings.pauseMotionWhileAnswering = $0 }
            )) {
                SettingsLabel(
                    title: "Замирать во время ответа",
                    icon: model.settings.pauseMotionWhileAnswering ? "pause.circle.fill" : "play.circle.fill",
                    bounce: model.settings.pauseMotionWhileAnswering
                )
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
                    .tint(Theme.tint)
                    .animation(.linear(duration: 0.3), value: progress.fraction)
                Text("Пока файл не скачан, действует только инструкция, и модель может отказывать.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .notDownloaded:
            VStack(alignment: .leading, spacing: 8) {
                Text("Версия без ограничений для этой модели ещё не скачана — пока действует только инструкция, и модель может отказывать.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    model.models.downloadUncensoredVariant()
                } label: {
                    Label("Скачать версию без ограничений", systemImage: "arrow.down.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glass(Capsule(), tint: Theme.tint, interactive: true)
                }
                .buttonStyle(PressableStyle())
            }

        case .unavailable:
            Text("Для выбранной модели нет версии без ограничений — действует только инструкция, и модель может отказывать. Модели с такой версией отмечены плашкой «Без цензуры».")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Building blocks

/// A group of settings on one glass card, with an optional heading and explanation.
private struct SettingsSection<Content: View>: View {
    var header: String?
    var footer: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header {
                Text(header)
                    .font(.footnote.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
            }
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 24)

            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            }
        }
    }
}

/// Title with a coloured icon, used for setting rows.
private struct SettingsLabel: View {
    let title: String
    let icon: String
    let bounce: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: bounce)
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            Text(title)
        }
    }
}
