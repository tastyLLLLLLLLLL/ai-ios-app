import Observation
import SwiftUI
import UIKit

/// A colour scheme the user can pick in the settings.
struct Palette: Identifiable, Equatable {
    let id: String
    let name: String
    let primary: Color
    let tint: Color
    let tertiary: Color

    var gradient: LinearGradient {
        LinearGradient(colors: [primary, tint, tertiary], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(red: red, green: green, blue: blue)
    }

    static let all: [Palette] = [
        Palette(id: "ocean", name: "Океан", primary: rgb(0.49, 0.36, 1.0), tint: rgb(0.31, 0.55, 1.0), tertiary: rgb(0.21, 0.82, 0.90)),
        Palette(id: "ruby", name: "Рубин", primary: rgb(0.86, 0.12, 0.38), tint: rgb(0.95, 0.24, 0.30), tertiary: rgb(1.0, 0.50, 0.42)),
        Palette(id: "sunset", name: "Закат", primary: rgb(0.98, 0.36, 0.22), tint: rgb(1.0, 0.55, 0.12), tertiary: rgb(1.0, 0.76, 0.24)),
        Palette(id: "forest", name: "Лес", primary: rgb(0.05, 0.62, 0.52), tint: rgb(0.14, 0.74, 0.42), tertiary: rgb(0.58, 0.85, 0.30)),
        Palette(id: "lilac", name: "Сирень", primary: rgb(0.66, 0.33, 0.97), tint: rgb(0.89, 0.34, 0.78), tertiary: rgb(1.0, 0.53, 0.62)),
        Palette(id: "graphite", name: "Графит", primary: rgb(0.40, 0.43, 0.50), tint: rgb(0.54, 0.58, 0.66), tertiary: rgb(0.74, 0.77, 0.83))
    ]
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Как в системе"
        case .light: return "Светлая"
        case .dark: return "Тёмная"
        }
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// The chosen appearance and colour scheme. Views read colours through `Theme`.
@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    private static let paletteKey = "themePalette"
    private static let appearanceKey = "themeAppearance"

    private(set) var palette: Palette
    private(set) var appearance: AppearanceMode

    private init() {
        let defaults = UserDefaults.standard
        let savedPalette = defaults.string(forKey: Self.paletteKey)
        palette = Palette.all.first { $0.id == savedPalette } ?? Palette.all[0]
        appearance = AppearanceMode(rawValue: defaults.string(forKey: Self.appearanceKey) ?? "") ?? .system
    }

    @MainActor
    func setPalette(_ id: String) {
        guard let chosen = Palette.all.first(where: { $0.id == id }) else { return }
        palette = chosen
        UserDefaults.standard.set(id, forKey: Self.paletteKey)
        apply(animated: false)
    }

    @MainActor
    func setAppearance(_ mode: AppearanceMode) {
        appearance = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.appearanceKey)
        apply(animated: true)
    }

    /// Pushes the light/dark choice and the tint colour to every window, including open sheets.
    @MainActor
    func apply(animated: Bool) {
        let style = appearance.interfaceStyle
        let tint = UIColor(palette.tint)
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.tintColor = tint
                guard window.overrideUserInterfaceStyle != style else { continue }
                if animated {
                    UIView.transition(with: window, duration: 0.35, options: .transitionCrossDissolve) {
                        window.overrideUserInterfaceStyle = style
                    }
                } else {
                    window.overrideUserInterfaceStyle = style
                }
            }
        }
    }
}

/// Colours of the current palette.
enum Theme {
    static var primary: Color { ThemeStore.shared.palette.primary }
    static var tint: Color { ThemeStore.shared.palette.tint }
    static var tertiary: Color { ThemeStore.shared.palette.tertiary }

    static var accent: LinearGradient { ThemeStore.shared.palette.gradient }

    static var bubble: LinearGradient {
        LinearGradient(colors: [primary, tint], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Ambient motion (drifting background, rotating logo). Switched off for the automated screenshot run.
enum Motion {
    static let ambient = !UserDefaults.standard.bool(forKey: "demoStill")
}

/// Soft coloured glow behind every screen. The glows drift slowly and flare up when the theme changes.
struct AuroraBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var drift = false
    @State private var flare = false

    var body: some View {
        let dark = colorScheme == .dark
        let paletteID = ThemeStore.shared.palette.id
        let shift: CGFloat = drift ? 1 : 0
        let scale: CGFloat = flare ? 1.35 : 1

        ZStack {
            (dark ? Color(red: 0.035, green: 0.035, blue: 0.07) : Color(red: 0.965, green: 0.96, blue: 0.985))

            GeometryReader { proxy in
                let size = proxy.size
                Circle()
                    .fill(Theme.primary.opacity(dark ? 0.38 : 0.22))
                    .frame(width: size.width * 0.9)
                    .blur(radius: 110)
                    .scaleEffect(scale)
                    .offset(x: size.width * (-0.35 + 0.14 * shift), y: size.width * (-0.3 + 0.10 * shift))
                Circle()
                    .fill(Theme.tertiary.opacity(dark ? 0.22 : 0.18))
                    .frame(width: size.width * 0.8)
                    .blur(radius: 120)
                    .scaleEffect(scale)
                    .offset(x: size.width * (0.5 - 0.16 * shift), y: size.height * (0.25 + 0.06 * shift))
                Circle()
                    .fill(Theme.tint.opacity(dark ? 0.26 : 0.16))
                    .frame(width: size.width * 0.9)
                    .blur(radius: 130)
                    .scaleEffect(scale)
                    .offset(x: size.width * (-0.2 + 0.18 * shift), y: size.height * (0.72 - 0.07 * shift))
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: paletteID)
        .animation(.easeInOut(duration: 0.4), value: dark)
        .onAppear {
            guard Motion.ambient else { return }
            withAnimation(.easeInOut(duration: 16).repeatForever(autoreverses: true)) {
                drift = true
            }
        }
        .onChange(of: paletteID) {
            withAnimation(.easeOut(duration: 0.3)) { flare = true }
            Task {
                try? await Task.sleep(for: .seconds(0.3))
                withAnimation(.spring(response: 0.9, dampingFraction: 0.6)) { flare = false }
            }
        }
    }
}

/// Frosted card used for panels and list rows.
struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 22

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 22) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius))
    }
}

/// The glowing orb used as the app's mark.
struct OrbLogo: View {
    var size: CGFloat = 96
    @State private var pulse = false
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.accent)
                .blur(radius: size * 0.28)
                .opacity(pulse ? 0.75 : 0.45)
                .scaleEffect(pulse ? 1.12 : 0.96)
            Circle()
                .fill(Theme.accent)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .overlay(
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [.white.opacity(0.55), .clear],
                                center: UnitPoint(x: 0.3, y: 0.25),
                                startRadius: 0,
                                endRadius: size * 0.6
                            )
                        )
                )
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard Motion.ambient else { return }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                pulse = true
            }
            withAnimation(.linear(duration: 18).repeatForever(autoreverses: false)) {
                spin = true
            }
        }
    }
}

/// Buttons shrink slightly while pressed.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
