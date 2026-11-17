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

    private var server: ServerStore { model.server }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if server.isConfigured {
                statusCard
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

            Text("Адрес и пароль показывает скрипт установки на сервере в конце работы, а также команда start.sh.")
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
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(PressableStyle())
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
                        .glass(Capsule())
                }
                .buttonStyle(PressableStyle())

                Button(role: .destructive) {
                    if model.useOnline { model.chooseOfflineIfPossible() }
                    server.disconnect()
                } label: {
                    Label("Отключить", systemImage: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glass(Capsule())
                }
                .buttonStyle(PressableStyle())
            }

            if case .failed = server.status {
                Text("Если сервер выключен, запустите его на RunPod и выполните в консоли:\nbash /workspace/ai-server/start.sh")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 22)
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
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(PressableStyle())
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
                Image(systemName: "cloud.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text(item.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if item.uncensored {
                Label("Без цензуры", systemImage: "lock.open.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.tint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.tint.opacity(0.14), in: Capsule())
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
                        .background(Theme.accent, in: Capsule())
                        .shadow(color: Theme.tint.opacity(0.35), radius: 8, y: 3)
                }
                .buttonStyle(PressableStyle())
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
