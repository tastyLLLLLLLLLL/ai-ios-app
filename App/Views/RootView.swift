import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var showChats = false
    @State private var showModels = false
    @State private var showSettings = false
    @State private var launched = false
    /// How far the chat panel is being dragged closed (negative values).
    @State private var drawerDrag: CGFloat = 0

    private let drawerAnimation = Animation.spring(response: 0.42, dampingFraction: 0.86)

    var body: some View {
        GeometryReader { proxy in
            let drawerWidth = min(proxy.size.width * 0.84, 360)
            let progress = showChats ? max(0, 1 + drawerDrag / drawerWidth) : 0

            ZStack(alignment: .leading) {
                mainScreen
                    .modifier(DrawerPush(progress: progress, width: drawerWidth, light: MotionStore.shared.lightMode))
                    .allowsHitTesting(!showChats)

                // Dimmed main screen; a tap or a swipe to the left closes the panel.
                Color.black
                    .opacity(0.35 * progress)
                    .ignoresSafeArea()
                    .allowsHitTesting(showChats)
                    .onTapGesture { closeChats() }
                    .gesture(closeDrag(width: drawerWidth))

                if showChats {
                    ChatDrawer(onClose: closeChats)
                        .frame(width: drawerWidth)
                        .offset(x: min(0, drawerDrag))
                        .gesture(closeDrag(width: drawerWidth))
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .zIndex(1)
                }
            }
        }
        .background(AuroraBackground())
        .tint(Theme.tint)
        .respectsAnimationSetting()
        .sheet(isPresented: $showModels) {
            ModelsView()
                .respectsAnimationSetting()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .respectsAnimationSetting()
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
            case "chats": openChats()
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
            // iOS does not allow GPU work in the background: the answer pauses and continues on return.
            switch scenePhase {
            case .background: model.handleBackground()
            case .active: model.handleForeground()
            default: break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            model.unloadModel()
        }
    }

    private var mainScreen: some View {
        NavigationStack {
            ChatView(showModels: $showModels)
                .opacity(launched ? 1 : 0)
                .scaleEffect(launched ? 1 : 0.96)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            openChats()
                        } label: {
                            Image(systemName: "line.3.horizontal")
                                .symbolEffect(.bounce, value: showChats)
                        }
                        .accessibilityLabel("Чаты")
                    }
                    ToolbarItem(placement: .principal) {
                        modelChip
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
    }

    private var modelChip: some View {
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
            // On iOS 26 the toolbar already draws glass around its items.
            .modifier(ChipBackground())
            .animation(.smooth, value: model.activeModelName)
            .animation(.smooth, value: model.isUncensoredActive)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Выбрать модель")
    }

    /// Swipe to the left that closes the chat panel, following the finger.
    private func closeDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 15)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                drawerDrag = min(0, value.translation.width)
            }
            .onEnded { value in
                if value.translation.width < -width * 0.3 || value.predictedEndTranslation.width < -width * 0.6 {
                    closeChats()
                } else {
                    withAnimation(drawerAnimation) { drawerDrag = 0 }
                }
            }
    }

    private func openChats() {
        drawerDrag = 0
        withAnimation(drawerAnimation) { showChats = true }
    }

    private func closeChats() {
        withAnimation(drawerAnimation) {
            showChats = false
            drawerDrag = 0
        }
    }
}

private struct ChipBackground: ViewModifier {
    func body(content: Content) -> some View {
        if GlassSupport.isAvailable {
            content
        } else {
            content.glassCard(cornerRadius: 16, blurred: true)
        }
    }
}

// MARK: - Chat panel

/// Panel with the list of chats that slides in from the left edge.
struct ChatDrawer: View {
    @Environment(AppModel.self) private var model
    let onClose: () -> Void

    @State private var appeared = false
    @State private var chatToDelete: Conversation?

    private struct DaySection: Identifiable {
        let title: String
        let chats: [Conversation]
        var id: String { title }
    }

    /// Chats grouped by day so they are easy to tell apart.
    private var sections: [DaySection] {
        let calendar = Calendar.current
        var today: [Conversation] = []
        var yesterday: [Conversation] = []
        var week: [Conversation] = []
        var older: [Conversation] = []
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        for chat in model.sortedConversations {
            if calendar.isDateInToday(chat.updated) {
                today.append(chat)
            } else if calendar.isDateInYesterday(chat.updated) {
                yesterday.append(chat)
            } else if chat.updated > weekAgo {
                week.append(chat)
            } else {
                older.append(chat)
            }
        }
        return [
            DaySection(title: "Сегодня", chats: today),
            DaySection(title: "Вчера", chats: yesterday),
            DaySection(title: "На этой неделе", chats: week),
            DaySection(title: "Ранее", chats: older)
        ].filter { !$0.chats.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 14)

            if model.sortedConversations.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(sections.enumerated()), id: \.element.id) { sectionIndex, section in
                            Text(section.title)
                                .font(.caption.weight(.semibold))
                                .textCase(.uppercase)
                                .foregroundStyle(.secondary)
                                .padding(.top, sectionIndex == 0 ? 0 : 14)
                                .padding(.leading, 6)

                            ForEach(Array(section.chats.enumerated()), id: \.element.id) { index, chat in
                                ChatRowCard(
                                    chat: chat,
                                    isCurrent: chat.id == model.currentID,
                                    onOpen: {
                                        withAnimation(.smooth) { model.open(chat.id) }
                                        onClose()
                                    },
                                    onDelete: { chatToDelete = chat }
                                )
                                .modifier(StaggerIn(
                                    appeared: appeared,
                                    delay: 0.05 + Double(min(index + sectionIndex, 8)) * 0.035,
                                    enabled: !MotionStore.shared.lightMode
                                ))
                                .transition(.asymmetric(
                                    insertion: .opacity,
                                    removal: .scale(scale: 0.9).combined(with: .opacity)
                                ))
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 24)
                    .modifier(StaggerIn(appeared: appeared, delay: 0.05, enabled: MotionStore.shared.lightMode))
                    .animation(.smooth, value: model.sortedConversations.map(\.id))
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            DrawerBackground()
                .ignoresSafeArea()
        }
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
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Чаты")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                Text(chatCountLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer()
            Button {
                withAnimation(.smooth) { model.newChat() }
                onClose()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .glass(Circle(), tint: Theme.tint)
            }
            .buttonStyle(PressableStyle(scale: 0.88))
            .accessibilityLabel("Новый чат")
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : -8)
        .animation(.smooth, value: appeared)
    }

    private var chatCountLabel: String {
        let count = model.sortedConversations.count
        let lastDigit = count % 10
        let lastTwo = count % 100
        let word: String
        if lastDigit == 1 && lastTwo != 11 {
            word = "разговор"
        } else if (2...4).contains(lastDigit) && !(12...14).contains(lastTwo) {
            word = "разговора"
        } else {
            word = "разговоров"
        }
        return "\(count) \(word)"
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("Пока нет чатов")
                .font(.headline)
            Text("Здесь появятся ваши разговоры.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .opacity(appeared ? 1 : 0)
        .animation(.smooth.delay(0.1), value: appeared)
    }
}

/// Background of the chat panel. Full design: frosted panel with a soft shadow.
/// Light mode: an opaque tinted surface that is cheap to draw while it slides.
private struct DrawerBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 36,
            topTrailingRadius: 36,
            style: .continuous
        )
        let dark = colorScheme == .dark
        if MotionStore.shared.lightMode {
            ZStack {
                shape.fill(dark ? Color(red: 0.07, green: 0.07, blue: 0.11) : Color(red: 0.97, green: 0.97, blue: 0.99))
                shape.fill(
                    LinearGradient(
                        colors: [Theme.primary.opacity(dark ? 0.20 : 0.10), .clear],
                        startPoint: .topLeading,
                        endPoint: .center
                    )
                )
                shape.stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
        } else {
            ZStack {
                shape.fill(.regularMaterial)
                shape.fill(
                    LinearGradient(
                        colors: [Theme.primary.opacity(dark ? 0.22 : 0.12), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                shape.stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.25), radius: 24, x: 8)
        }
    }
}

/// How the main screen moves aside for the chat panel.
private struct DrawerPush: ViewModifier {
    let progress: CGFloat
    let width: CGFloat
    let light: Bool

    func body(content: Content) -> some View {
        if light {
            content.offset(x: width * 0.12 * progress)
        } else {
            content
                .scaleEffect(1 - 0.06 * progress, anchor: .trailing)
                .offset(x: width * 0.18 * progress)
                .mask {
                    RoundedRectangle(cornerRadius: 44 * progress, style: .continuous)
                        .ignoresSafeArea()
                }
        }
    }
}

/// Slides a view in from the left once the panel has appeared.
private struct StaggerIn: ViewModifier {
    let appeared: Bool
    let delay: Double
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .opacity(appeared ? 1 : 0)
                .offset(x: appeared ? 0 : -24)
                .animation(.spring(response: 0.45, dampingFraction: 0.82).delay(delay), value: appeared)
        } else {
            content
        }
    }
}

/// One chat in the panel: a separate glass card with an icon, title, preview and delete button.
private struct ChatRowCard: View {
    let chat: Conversation
    let isCurrent: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    Image(systemName: chat.messages.contains { !$0.imageNames.isEmpty } ? "photo" : "text.bubble.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isCurrent ? .white : Theme.tint)
                        .frame(width: 38, height: 38)
                        .background {
                            if isCurrent {
                                Circle().fill(Theme.accent)
                            } else {
                                Circle().fill(Theme.tint.opacity(0.14))
                            }
                        }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(chat.displayTitle)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if !chat.preview.isEmpty {
                            Text(chat.preview)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Text(chat.updated.formatted(date: .omitted, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.97))

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(width: 34, height: 34)
                    .background(Color.red.opacity(0.12), in: Circle())
            }
            .buttonStyle(PressableStyle(scale: 0.85))
            .accessibilityLabel("Удалить чат")
        }
        .padding(12)
        .glassCard(cornerRadius: 20)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Theme.tint, lineWidth: 1.5)
                .opacity(isCurrent ? 0.9 : 0)
        )
    }
}
