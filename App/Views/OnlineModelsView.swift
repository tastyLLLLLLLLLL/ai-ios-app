import SwiftUI
import UIKit

/// "Онлайн" tab of the model list: connection to the user's server and its models.
struct OnlineModelsView: View {
    @Environment(AppModel.self) private var model
    @Binding var showStudio: Bool

    @State private var address = ""
    @State private var password = ""
    @State private var connecting = false
    @State private var copied = false
    @State private var runPodKey = ""
    @State private var powerError: String?
    @State private var powerBusy = false

    private var server: ServerStore { model.server }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if server.isConfigured {
                statusCard
                powerCard
                if server.isConnected {
                    connectedContent
                }
            } else {
                connectForm
            }
        }
        .onAppear {
            address = server.address
        }
    }

    // MARK: Connection

    private var connectForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ваш сервер")
                        .font(.title3.weight(.semibold))
                    Text("Большие модели, картинки, видео и музыка")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Label("Проще всего: наведите камеру iPhone на QR-код, который показывает сервер в конце установки, и нажмите «Открыть в Pocket AI».", systemImage: "qrcode.viewfinder")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Или введите адрес и пароль из того же вывода вручную:")
                .font(.footnote)
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                TextField("https://…-8080.proxy.runpod.net", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .padding(12)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                SecureField("Пароль", text: $password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if case .failed(let message) = server.status {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button {
                connect()
            } label: {
                HStack {
                    if connecting { ProgressView().tint(.white) }
                    Text(connecting ? "Подключаюсь…" : "Подключить")
                }
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .accentButtonLabel(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .liquidButton(prominent: true, shape: .rounded(16))
            .disabled(connecting || address.isEmpty || password.isEmpty)
            .opacity(address.isEmpty || password.isEmpty ? 0.5 : 1)
        }
        .padding(18)
        .glassCard(cornerRadius: 24)
    }

    private func connect() {
        connecting = true
        Task {
            await server.connect(address: address, password: password)
            connecting = false
            if server.isConnected {
                password = ""
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                switch server.status {
                case .connected:
                    Circle().fill(.green).frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Сервер подключён").font(.headline)
                        if !server.gpu.isEmpty {
                            Text(server.gpu).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                case .checking:
                    ProgressView()
                    Text("Проверяю сервер…").font(.headline)
                case .failed(let message):
                    Circle().fill(.red).frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Нет связи с сервером").font(.headline)
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                case .disconnected:
                    Circle().fill(.gray).frame(width: 10, height: 10)
                    Text("Не подключён").font(.headline)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await server.refresh() }
                } label: {
                    Label("Обновить", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .plainButtonLabel(Capsule())
                }
                .liquidButton(prominent: false, shape: .capsule)

                Button(role: .destructive) {
                    if model.useOnline { model.chooseOfflineIfPossible() }
                    server.disconnect()
                } label: {
                    Label("Отключить", systemImage: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .plainButtonLabel(Capsule())
                }
                .liquidButton(prominent: false, shape: .capsule)
            }


        }
        .padding(16)
        .glassCard(cornerRadius: 22)
    }

    // MARK: Power

    private var powerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Питание сервера", systemImage: "power")
                .font(.headline)

            powerButton

            if let powerError {
                Label(powerError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Divider()

            HStack {
                Text("Выключать после простоя")
                    .font(.subheadline)
                Spacer()
                Picker("Выключать после простоя", selection: Binding(
                    get: { server.idleMinutes },
                    set: { value in Task { await server.setIdleMinutes(value) } }
                )) {
                    Text("10 мин").tag(10)
                    Text("20 мин").tag(20)
                    Text("30 мин").tag(30)
                    Text("1 час").tag(60)
                    Text("Никогда").tag(0)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(!server.isConnected)
            }
            Text("Сервер сам выключится, если им не пользоваться, — деньги за работу перестанут списываться. Пока идёт ответ или создаётся картинка, он не выключится.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            if server.hasRunPodKey {
                HStack {
                    Label("Ключ RunPod сохранён", systemImage: "checkmark.seal.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.tint)
                    Spacer()
                    Button("Удалить", role: .destructive) { server.saveRunPodKey("") }
                        .font(.footnote.weight(.medium))
                }
                Text("Если сервер выключен, приложение само включит его, когда вы напишете онлайн-модели или создадите что-то в Студии.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Чтобы включать сервер из приложения, нужен ключ RunPod: на сайте RunPod откройте Settings → API Keys → Create API Key, выберите права Read/Write и скопируйте ключ. Он хранится только на этом iPhone, никому его не пересылайте.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    SecureField("Ключ RunPod", text: $runPodKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(10)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Button("Сохранить") {
                        server.saveRunPodKey(runPodKey)
                        runPodKey = ""
                    }
                    .font(.subheadline.weight(.semibold))
                    .disabled(runPodKey.isEmpty)
                }
            }

            DisclosureGroup("Как сделать, чтобы сервер запускался сам") {
                Text("Один раз, когда установка закончится: на RunPod откройте сервер → ⋮ → Edit Pod → в поле Container Start Command вставьте\n\nbash /workspace/ai-server/autostart.sh\n\nи сохраните. Сервер перезапустится и дальше после каждого включения будет готов сам, без консоли.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 6)
            }
            .font(.subheadline)
        }
        .padding(16)
        .glassCard(cornerRadius: 22)
    }

    @ViewBuilder
    private var powerButton: some View {
        switch server.power {
        case .starting:
            HStack(spacing: 10) {
                ProgressView()
                Text(server.powerNote ?? "Включаю сервер… обычно 1–3 минуты").font(.subheadline)
            }
        case .stopping:
            HStack(spacing: 10) {
                ProgressView()
                Text("Выключаю сервер…").font(.subheadline)
            }
        default:
            if server.isConnected {
                powerAction(title: "Выключить сервер", icon: "power", tint: .red) {
                    try await server.stopServer()
                }
            } else {
                powerAction(title: "Включить сервер", icon: "power", tint: Theme.tint) {
                    try await server.startServer()
                }
                .disabled(!server.canStartServer)
                .opacity(server.canStartServer ? 1 : 0.5)
            }
        }
    }

    private func powerAction(title: String, icon: String, tint: Color, action: @escaping () async throws -> Void) -> some View {
        Button {
            powerError = nil
            powerBusy = true
            Task {
                do {
                    try await action()
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } catch {
                    withAnimation(.smooth) { powerError = error.localizedDescription }
                }
                powerBusy = false
            }
        } label: {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .accentButtonLabel(RoundedRectangle(cornerRadius: 16, style: .continuous), tint: tint)
        }
        .liquidButton(prominent: true, tint: tint, shape: .rounded(16))
        .disabled(powerBusy)
    }

    // MARK: Models

    @ViewBuilder
    private var connectedContent: some View {
        let text = server.textModels.filter { $0.category != "code" }
        let code = server.textModels.filter { $0.category == "code" }

        if !text.isEmpty {
            header(icon: "text.bubble.fill", title: "Текст", subtitle: "Умные модели для общения и вопросов")
            ForEach(text) { item in
                OnlineModelCard(item: item)
            }
        }
        if !code.isEmpty {
            header(icon: "chevron.left.forwardslash.chevron.right", title: "Код", subtitle: "Для программирования")
            ForEach(code) { item in
                OnlineModelCard(item: item)
            }
        }
        if server.textModels.isEmpty {
            Text("На сервере пока нет текстовых моделей. Дождитесь окончания установки и нажмите «Обновить».")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        header(icon: "sparkles", title: "Студия", subtitle: "Картинки, видео и музыка по описанию")
        studioCard

        if !server.ntfyTopic.isEmpty {
            ntfyCard
        }
    }

    private var studioCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(MediaKind.allCases) { kind in
                let items = server.media(of: kind)
                HStack(spacing: 10) {
                    Image(systemName: kind.icon)
                        .foregroundStyle(Theme.tint)
                        .frame(width: 22)
                    Text(kind.title).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(items.isEmpty ? "не установлено" : items.map(\.name).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Button {
                showStudio = true
            } label: {
                Label("Открыть студию", systemImage: "wand.and.stars")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .accentButtonLabel(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .liquidButton(prominent: true, shape: .rounded(16))
            .disabled(server.mediaModels.isEmpty)
            .opacity(server.mediaModels.isEmpty ? 0.5 : 1)
        }
        .padding(16)
        .glassCard(cornerRadius: 22)
    }

    private var ntfyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Уведомления, когда приложение закрыто", systemImage: "bell.badge.fill")
                .font(.subheadline.weight(.semibold))
            Text("Установите из App Store бесплатное приложение ntfy, нажмите «+» и вставьте эту тему — тогда о готовых картинках, видео и музыке придёт уведомление, даже если Pocket AI закрыт.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                UIPasteboard.general.string = server.ntfyTopic
                withAnimation(.smooth) { copied = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    withAnimation(.smooth) { copied = false }
                }
            } label: {
                HStack {
                    Text(server.ntfyTopic)
                        .font(.system(.footnote, design: .monospaced))
                    Spacer()
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .padding(10)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(PressableStyle())
        }
        .padding(16)
        .glassCard(cornerRadius: 22)
    }

    private func header(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 10)
        .padding(.horizontal, 4)
    }
}

private struct OnlineModelCard: View {
    @Environment(AppModel.self) private var model
    let item: OnlineModel

    private var isSelected: Bool {
        model.useOnline && model.server.selectedTextModelID == item.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            Text(item.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            let perks = Array(ModelPerk.perks(for: item).prefix(3))
            if !perks.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(perks) { perk in
                        let color = perk.isDrawback ? Color.orange : Theme.tint
                        Label(perk.text, systemImage: perk.icon)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(color)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(color.opacity(0.14), in: Capsule())
                            .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 1))
                    }
                }
            }
            if isSelected {
                Label("Используется", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            } else {
                Button {
                    withAnimation(.smooth) { model.chooseOnline(item.id) }
                } label: {
                    Label("Использовать", systemImage: "checkmark.circle")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .accentButtonLabel(Capsule())
                        .shadow(color: GlassSupport.active ? .clear : Theme.tint.opacity(0.35), radius: 8, y: 3)
                }
                .liquidButton(prominent: true, shape: .capsule)
            }
        }
        .padding(16)
        .glassCard()
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Theme.accent, lineWidth: 2)
                .opacity(isSelected ? 1 : 0)
        )
        .animation(.smooth, value: isSelected)
    }
}

// MARK: - Model strengths

/// A short, concrete strength (or drawback) of a server model, shown as a chip on its card.
struct ModelPerk: Identifiable {
    let text: String
    let icon: String
    var isDrawback = false

    var id: String { text }

    static func perks(for model: OnlineModel) -> [ModelPerk] {
        let id = model.id.lowercased()
        var perks: [ModelPerk] = []
        if model.uncensored || id.contains("abliterated") || id.contains("uncensored") {
            perks.append(ModelPerk(text: "Без цензуры", icon: "lock.open.fill"))
        }
        if id.hasPrefix("qwen3.6") {
            perks += [
                ModelPerk(text: "Самая умная", icon: "crown.fill"),
                ModelPerk(text: "Отличный русский", icon: "character.bubble.fill"),
                ModelPerk(text: "Умеет рассуждать", icon: "brain"),
                ModelPerk(text: "Хорошо пишет код", icon: "chevron.left.forwardslash.chevron.right")
            ]
        } else if id.hasPrefix("qwen3:32b") {
            perks += [
                ModelPerk(text: "Отличный русский", icon: "character.bubble.fill"),
                ModelPerk(text: "Умеет рассуждать", icon: "brain")
            ]
        } else if id.hasPrefix("qwen3:4b") {
            perks += [
                ModelPerk(text: "Очень быстрая", icon: "bolt.fill"),
                ModelPerk(text: "Для простых вопросов", icon: "questionmark.bubble.fill"),
                ModelPerk(text: "Попроще умом", icon: "exclamationmark.triangle.fill", isDrawback: true)
            ]
        } else if id.hasPrefix("qwen3-coder") {
            perks += [
                ModelPerk(text: "Лучшая для кода", icon: "chevron.left.forwardslash.chevron.right"),
                ModelPerk(text: "Быстрая", icon: "bolt.fill"),
                ModelPerk(text: "Большие файлы", icon: "doc.text.fill")
            ]
        } else if id.hasPrefix("gemma") || id.contains("gemma") {
            perks += [
                ModelPerk(text: "Живой язык", icon: "text.quote"),
                ModelPerk(text: "Тексты и переводы", icon: "globe"),
                ModelPerk(text: "Длинные разговоры", icon: "text.bubble.fill")
            ]
        } else if id.hasPrefix("gpt-oss") {
            perks += [
                ModelPerk(text: "Быстрая", icon: "bolt.fill"),
                ModelPerk(text: "Сильная логика", icon: "function"),
                ModelPerk(text: "Всегда рассуждает", icon: "brain")
            ]
        } else if id.hasPrefix("deepseek-r1") {
            perks += [
                ModelPerk(text: "Математика и логика", icon: "function"),
                ModelPerk(text: "Подробные рассуждения", icon: "brain"),
                ModelPerk(text: "Медленная", icon: "tortoise.fill", isDrawback: true)
            ]
        }
        return perks
    }
}

/// Lays chips out in rows, moving to the next row when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: subviews.isEmpty ? 0 : y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
