import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var showChats = false
    @State private var showModels = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ChatView(showModels: $showModels)
                .background(AuroraBackground())
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showChats = true
                        } label: {
                            Image(systemName: "line.3.horizontal")
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
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .glassCard(cornerRadius: 16)
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
                        }
                        .accessibilityLabel("Настройки")
                        Button {
                            withAnimation(.smooth) { model.newChat() }
                        } label: {
                            Image(systemName: "square.and.pencil")
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
        .onAppear { ThemeStore.shared.apply(animated: false) }
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
                        ForEach(model.sortedConversations) { conversation in
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
                            .buttonStyle(.plain)
                            .listRowBackground(
                                conversation.id == model.currentID ? Theme.tint.opacity(0.14) : Color.clear
                            )
                            .swipeActions {
                                Button(role: .destructive) {
                                    withAnimation(.smooth) { model.delete(conversation.id) }
                                } label: {
                                    Label("Удалить", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(AuroraBackground())
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
