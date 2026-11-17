import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var showChats = false
    @State private var showModels = false
    @State private var showSettings = false
    @State private var launched = false

    var body: some View {
        NavigationStack {
            ChatView(showModels: $showModels)
                .opacity(launched ? 1 : 0)
                .scaleEffect(launched ? 1 : 0.96)
                .background(AuroraBackground())
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showChats = true
                        } label: {
                            Image(systemName: "line.3.horizontal")
                                .symbolEffect(.bounce, value: showChats)
                        }
                        .accessibilityLabel("Чаты")
                    }
                    ToolbarItem(placement: .principal) {
                        Button {
                            showModels = true
                        } label: {
                            HStack(spacing: 5) {
                                if model.isUncensoredActive {
                                    Image(systemName: "lock.open.fill")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(Theme.accent)
                                        .transition(.scale.combined(with: .opacity))
                                }
                                Text(model.activeModelName)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                    .contentTransition(.opacity)
                                Image(systemName: "chevron.down")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.secondary)
                                    .rotationEffect(.degrees(showModels ? 180 : 0))
                                    .animation(.smooth, value: showModels)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .glassCard(cornerRadius: 16, blurred: true)
                            .animation(.smooth, value: model.activeModelName)
                            .animation(.smooth, value: model.isUncensoredActive)
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityLabel("Выбрать модель")
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .symbolEffect(.bounce, value: showSettings)
                        }
                        .accessibilityLabel("Настройки")
                        Button {
                            withAnimation(.smooth) { model.newChat() }
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .symbolEffect(.bounce, value: model.currentID)
                        }
                        .accessibilityLabel("Новый чат")
                    }
                }
                .toolbarBackground(.hidden, for: .navigationBar)
        }
        .tint(Theme.tint)
        .sheet(isPresented: $showChats) {
            ChatListView()
        }
        .sheet(isPresented: $showModels) {
            ModelsView()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .animation(.easeInOut(duration: 0.5), value: ThemeStore.shared.palette.id)
        .onAppear {
            ThemeStore.shared.apply(animated: false)
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { launched = true }
        }
        .task {
            // Launch arguments used by the automated screenshot run:
            // -demoScreen models|settings|chats, -demoModel <file>, -demoUncensored YES,
            // -demoImage <path>, -demoPrompt "text", -demoPalette <id>, -demoAppearance light|dark.
            let defaults = UserDefaults.standard
            if let palette = defaults.string(forKey: "demoPalette") {
                ThemeStore.shared.setPalette(palette)
            }
            if let mode = defaults.string(forKey: "demoAppearance").flatMap(AppearanceMode.init(rawValue:)) {
                ThemeStore.shared.setAppearance(mode)
            }
            if let file = defaults.string(forKey: "demoModel"), model.models.installed.contains(file) {
                model.models.select(file)
            }
            if defaults.bool(forKey: "demoUncensored") {
                model.settings.uncensored = true
            }
            switch defaults.string(forKey: "demoScreen") {
            case "models": showModels = true
            case "settings": showSettings = true
            case "chats": showChats = true
            default: break
            }
            if let prompt = defaults.string(forKey: "demoPrompt") {
                var photos: [UIImage] = []
                if let path = defaults.string(forKey: "demoImage"), let image = UIImage(contentsOfFile: path) {
                    photos.append(image)
                }
                model.send(prompt, photos: photos)
            }
        }
        .onChange(of: scenePhase) {
            // iOS does not allow GPU work in the background, so generation must stop.
            if scenePhase == .background { model.stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            model.unloadModel()
        }
    }
}

struct ChatListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var appeared = false
    @State private var chatToDelete: Conversation?

    var body: some View {
        NavigationStack {
            Group {
                if model.sortedConversations.isEmpty {
                    ContentUnavailableView(
                        "Пока нет чатов",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Здесь появятся ваши разговоры.")
                    )
                } else {
                    List {
                        ForEach(Array(model.sortedConversations.enumerated()), id: \.element.id) { index, conversation in
                            HStack(spacing: 12) {
                            Button {
                                withAnimation(.smooth) { model.open(conversation.id) }
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(conversation.displayTitle)
                                        .font(.body.weight(.medium))
                                        .lineLimit(1)
                                    Text(conversation.updated.formatted(.relative(presentation: .named)))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PressableStyle(scale: 0.98))

                            Button {
                                chatToDelete = conversation
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.red)
                                    .frame(width: 36, height: 36)
                                    .background(Color.red.opacity(0.12), in: Circle())
                            }
                            .buttonStyle(PressableStyle(scale: 0.85))
                            .accessibilityLabel("Удалить чат")
                            }
                            .opacity(appeared ? 1 : 0)
                            .offset(x: appeared ? 0 : -18)
                            .animation(.smooth.delay(Double(min(index, 10)) * 0.04), value: appeared)
                            .listRowBackground(
                                conversation.id == model.currentID ? Theme.tint.opacity(0.14) : Color.clear
                            )
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .animation(.smooth, value: model.sortedConversations.map(\.id))
                }
            }
            .background(AuroraBackground())
            .onAppear { appeared = true }
            .confirmationDialog(
                "Удалить чат «\(chatToDelete?.displayTitle ?? "")»?",
                isPresented: Binding(get: { chatToDelete != nil }, set: { if !$0 { chatToDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Удалить", role: .destructive) {
                    if let id = chatToDelete?.id {
                        withAnimation(.smooth) { model.delete(id) }
                    }
                    chatToDelete = nil
                }
                Button("Отмена", role: .cancel) { chatToDelete = nil }
            }
            .navigationTitle("Чаты")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation(.smooth) { model.newChat() }
                        dismiss()
                    } label: {
                        Label("Новый чат", systemImage: "square.and.pencil")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}
