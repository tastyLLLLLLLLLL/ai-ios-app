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

/// A home-screen icon the user can choose.
struct AppIconOption: Identifiable {
    let id: String
    let name: String

    /// The same logo drawn in different styles, like Telegram's alternative icons.
    static let styled: [AppIconOption] = [
        AppIconOption(id: "pixel", name: "Пиксели"),
        AppIconOption(id: "neon", name: "Неон"),
        AppIconOption(id: "minimal", name: "Минимал"),
        AppIconOption(id: "dark", name: "Тёмная"),
        AppIconOption(id: "glass", name: "Стекло"),
        AppIconOption(id: "outline", name: "Контур")
    ]

    static let themed: [AppIconOption] = Palette.all.map { AppIconOption(id: $0.id, name: $0.name) }

    static let all = themed + styled

    /// Icon set name in the app bundle; nil is the main icon. The "V2" names are new so iOS
    /// does not show a picture it cached for an older icon with the same name.
    static func alternateName(for id: String) -> String? {
        id == Palette.all[0].id ? nil : "AppIconV2-\(id)"
    }

    static func previewName(for id: String) -> String {
        "IconPreviewV2-\(id)"
    }
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
    private static let iconKey = "themeIcon"
    private static let backgroundKey = "themeBackground"

    private(set) var palette: Palette
    private(set) var appearance: AppearanceMode
    /// Palette id of the home-screen icon in use.
    private(set) var iconID: String
    private(set) var backgroundStyle: BackgroundStyle

    private init() {
        let defaults = UserDefaults.standard
        let savedPalette = defaults.string(forKey: Self.paletteKey)
        palette = Palette.all.first { $0.id == savedPalette } ?? Palette.all[0]
        appearance = AppearanceMode(rawValue: defaults.string(forKey: Self.appearanceKey) ?? "") ?? .system
        iconID = defaults.string(forKey: Self.iconKey) ?? Palette.all[0].id
        backgroundStyle = BackgroundStyle(rawValue: defaults.string(forKey: Self.backgroundKey) ?? "") ?? .aurora
        // An icon from an older version may no longer exist.
        if !AppIconOption.all.contains(where: { $0.id == iconID }) {
            iconID = Palette.all[0].id
            defaults.set(iconID, forKey: Self.iconKey)
        }
        // Older versions used other icon names; point the home screen at the current picture.
        let expected = AppIconOption.alternateName(for: iconID)
        Task { @MainActor in
            if UIApplication.shared.supportsAlternateIcons, UIApplication.shared.alternateIconName != expected {
                UIApplication.shared.setAlternateIconName(expected) { _ in }
            }
        }
    }

    @MainActor
    func setBackground(_ style: BackgroundStyle) {
        backgroundStyle = style
        UserDefaults.standard.set(style.rawValue, forKey: Self.backgroundKey)
    }

    /// Changes the app icon on the home screen. iOS confirms the change with its own message.
    @MainActor
    func setIcon(_ id: String) {
        guard AppIconOption.all.contains(where: { $0.id == id }), id != iconID else { return }
        let name = AppIconOption.alternateName(for: id)
        guard UIApplication.shared.supportsAlternateIcons else { return }
        iconID = id
        UserDefaults.standard.set(id, forKey: Self.iconKey)
        UIApplication.shared.setAlternateIconName(name) { _ in }
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

    /// True while the drifting background and the rotating logo should move.
    static var isRunning: Bool {
        let store = MotionStore.shared
        return ambient && !store.paused && !store.animationsOff && !store.lightMode
    }
}

/// Lets the app freeze ambient motion while the model is answering, so the graphics chip is free for it.
@Observable
final class MotionStore {
    static let shared = MotionStore()
    var paused = false
    /// "Лёгкий режим": plain cards and backgrounds instead of glass, blur and shadows.
    var lightMode = false
    /// "Без анимаций": every transition happens instantly.
    var animationsOff = false

    private init() {}
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

            if ThemeStore.shared.backgroundStyle != .aurora {
                PatternBackground(style: ThemeStore.shared.backgroundStyle, dark: dark, animated: Motion.isRunning)
                    .scaleEffect(scale)
            } else if MotionStore.shared.lightMode {
                lightGlows(dark: dark, scale: scale)
            } else {
                // Full design: soft blurred glows that drift slowly.
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
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: paletteID)
        .animation(.easeInOut(duration: 0.4), value: dark)
        .onAppear {
            if Motion.isRunning { startDrift() }
        }
        .onChange(of: Motion.isRunning) {
            if Motion.isRunning {
                startDrift()
            } else {
                withAnimation(.easeOut(duration: 1.2)) { drift = false }
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

    /// Light mode: the same colours as still radial gradients, cheap to draw.
    private func lightGlows(dark: Bool, scale: CGFloat) -> some View {
        GeometryReader { proxy in
            let size = proxy.size
            glow(Theme.primary.opacity(dark ? 0.42 : 0.26), diameter: size.width * 1.9)
                    .scaleEffect(scale)
                .position(x: size.width * 0.10, y: size.width * 0.15)
                glow(Theme.tertiary.opacity(dark ? 0.26 : 0.20), diameter: size.width * 1.8)
                    .scaleEffect(scale)
                .position(x: size.width * 0.95, y: size.height * 0.45)
            glow(Theme.tint.opacity(dark ? 0.30 : 0.18), diameter: size.width * 2.0)
                .scaleEffect(scale)
                .position(x: size.width * 0.25, y: size.height * 0.92)
        }
    }
}

extension AuroraBackground {
    private func glow(_ color: Color, diameter: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color, color.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: diameter / 2
                )
            )
            .frame(width: diameter, height: diameter)
    }

    private func startDrift() {
        withAnimation(.easeInOut(duration: 16).repeatForever(autoreverses: true)) {
            drift = true
        }
    }
}

// MARK: - Glass

/// Liquid glass on iOS 26 and newer; a translucent fill or material on older systems.
struct GlassBackground<S: Shape>: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let shape: S
    /// Coloured glass for primary buttons.
    var tint: Color?
    /// Glass that reacts to touches (iOS 26).
    var interactive = false
    /// Real background blur on older systems. Costly, so only for elements floating over content.
    var blurred = false

    func body(content: Content) -> some View {
        if MotionStore.shared.lightMode {
            plain(content)
        } else {
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                content.glassEffect(glass, in: shape)
            } else {
                fallback(content)
            }
            #else
            fallback(content)
            #endif
        }
    }

    /// Light mode: a flat translucent fill, no glass and no blur.
    @ViewBuilder
    private func plain(_ content: Content) -> some View {
        if let tint {
            content.background(shape.fill(tint))
        } else {
            content
                .background(shape.fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.7)))
                .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 1))
        }
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    private var glass: Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
    #endif

    @ViewBuilder
    private func fallback(_ content: Content) -> some View {
        if let tint {
            content.background(
                shape.fill(
                    LinearGradient(colors: [tint, tint.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            )
        } else {
            content
                .background {
                    if blurred {
                        shape.fill(.ultraThinMaterial)
                    } else {
                        shape.fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.6))
                    }
                }
                .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 1))
        }
    }
}

/// True when the system draws liquid glass, so views can skip their own decorations.
enum GlassSupport {
    static var isAvailable: Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }

    /// Liquid glass is in use: iOS 26 and the light mode is off.
    static var active: Bool { isAvailable && !MotionStore.shared.lightMode }
}

enum LiquidShape {
    case capsule
    case circle
    case rounded(CGFloat)
}

/// Buttons: the system liquid glass button styles on iOS 26 (they shimmer on touch and never
/// swallow taps); a hand-drawn background with a press effect elsewhere and in light mode.
private struct LiquidButton: ViewModifier {
    let prominent: Bool
    let tint: Color?
    let shape: LiquidShape
    let pressScale: CGFloat

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), GlassSupport.active {
            styled(content)
                .tint(tint ?? Theme.tint)
                .buttonBorderShape(borderShape)
        } else {
            content.buttonStyle(PressableStyle(scale: pressScale))
        }
        #else
        content.buttonStyle(PressableStyle(scale: pressScale))
        #endif
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    @ViewBuilder
    private func styled(_ content: Content) -> some View {
        if prominent {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.glass)
        }
    }
    #endif

    private var borderShape: ButtonBorderShape {
        switch shape {
        case .capsule: return .capsule
        case .circle: return .circle
        case .rounded(let radius): return .roundedRectangle(radius: radius)
        }
    }
}

extension View {
    func liquidButton(prominent: Bool = false, tint: Color? = nil, shape: LiquidShape = .capsule, pressScale: CGFloat = 0.96) -> some View {
        modifier(LiquidButton(prominent: prominent, tint: tint, shape: shape, pressScale: pressScale))
    }

    /// Coloured background of a main button's label; the glass button style draws it on iOS 26.
    @ViewBuilder
    func accentButtonLabel<S: Shape>(_ shape: S, tint: Color? = nil) -> some View {
        if GlassSupport.active {
            self
        } else if let tint {
            self.background(shape.fill(tint))
        } else {
            self.background(shape.fill(Theme.accent))
        }
    }

    /// Neutral background of a secondary button's label; the glass button style draws it on iOS 26.
    @ViewBuilder
    func plainButtonLabel<S: Shape>(_ shape: S) -> some View {
        if GlassSupport.active {
            self
        } else {
            self.glass(shape)
        }
    }
}

extension View {
    /// Glass panel with rounded corners: cards, list rows, the input bar.
    func glassCard(cornerRadius: CGFloat = 22, blurred: Bool = false, interactive: Bool = false) -> some View {
        modifier(GlassBackground(
            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            interactive: interactive,
            blurred: blurred
        ))
    }

    /// Glass in any shape, optionally tinted with a colour.
    func glass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false, blurred: Bool = false) -> some View {
        modifier(GlassBackground(shape: shape, tint: tint, interactive: interactive, blurred: blurred))
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

extension View {
    /// Turns off every animation below this view when "Без анимаций" is on.
    func respectsAnimationSetting() -> some View {
        transaction { transaction in
            if MotionStore.shared.animationsOff {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }
}

// MARK: - Background styles

enum BackgroundStyle: String, CaseIterable, Identifiable {
    case aurora
    case stars
    case waves
    case grid
    case gradient
    case bokeh

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aurora: return "Сияние"
        case .stars: return "Звёзды"
        case .waves: return "Волны"
        case .grid: return "Ретро"
        case .gradient: return "Градиент"
        case .bokeh: return "Боке"
        }
    }
}

/// Backgrounds drawn in one Canvas pass, without blur, so they stay cheap even when moving.
/// Colours come from the current theme; with motion off they are drawn as a still frame.
struct PatternBackground: View {
    let style: BackgroundStyle
    let dark: Bool
    let animated: Bool

    var body: some View {
        if animated {
            TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
                canvas(time: context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            canvas(time: 0)
        }
    }

    private func canvas(time: Double) -> some View {
        let colors = (Theme.primary, Theme.tint, Theme.tertiary)
        let dark = dark
        let style = style
        return Canvas { context, size in
            switch style {
            case .aurora:
                PatternBackground.glows(&context, size, colors, dark)
            case .stars:
                PatternBackground.stars(&context, size, colors, dark, time)
            case .waves:
                PatternBackground.waves(&context, size, colors, dark, time)
            case .grid:
                PatternBackground.grid(&context, size, colors, dark, time)
            case .gradient:
                PatternBackground.gradient(&context, size, colors, dark, time)
            case .bokeh:
                PatternBackground.bokeh(&context, size, colors, dark, time)
            }
        }
        .ignoresSafeArea()
    }

    private typealias Colors = (Color, Color, Color)

    /// Deterministic pseudo-random numbers, so stars and circles keep their places.
    private struct Seeded {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    private static func radial(_ context: inout GraphicsContext, _ color: Color, center: CGPoint, radius: CGFloat) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.fill(
            Path(ellipseIn: rect),
            with: .radialGradient(Gradient(colors: [color, color.opacity(0)]), center: center, startRadius: 0, endRadius: radius)
        )
    }

    fileprivate static func glows(_ context: inout GraphicsContext, _ size: CGSize, _ colors: Colors, _ dark: Bool) {
        radial(&context, colors.0.opacity(dark ? 0.42 : 0.26), center: CGPoint(x: size.width * 0.1, y: size.width * 0.15), radius: size.width * 0.95)
        radial(&context, colors.2.opacity(dark ? 0.26 : 0.2), center: CGPoint(x: size.width * 0.95, y: size.height * 0.45), radius: size.width * 0.9)
        radial(&context, colors.1.opacity(dark ? 0.3 : 0.18), center: CGPoint(x: size.width * 0.25, y: size.height * 0.92), radius: size.width)
    }

    fileprivate static func stars(_ context: inout GraphicsContext, _ size: CGSize, _ colors: Colors, _ dark: Bool, _ time: Double) {
        radial(&context, colors.0.opacity(dark ? 0.35 : 0.18), center: CGPoint(x: 0, y: 0), radius: size.width * 1.1)
        radial(&context, colors.2.opacity(dark ? 0.22 : 0.14), center: CGPoint(x: size.width, y: size.height), radius: size.width * 1.1)
        var random = Seeded(state: 42)
        let starColor = dark ? Color.white : colors.1
        for _ in 0..<140 {
            let x = random.next() * size.width
            let y = random.next() * size.height
            let radius = 0.5 + random.next() * 1.6
            let phase = random.next() * .pi * 2
            let speed = 0.6 + random.next() * 1.8
            let twinkle = 0.35 + 0.65 * (0.5 + 0.5 * sin(time * speed + phase))
            let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect), with: .color(starColor.opacity((dark ? 0.9 : 0.6) * twinkle)))
            if radius > 1.8 {
                radial(&context, colors.1.opacity(0.35 * twinkle), center: CGPoint(x: x, y: y), radius: radius * 6)
            }
        }
    }

    fileprivate static func waves(_ context: inout GraphicsContext, _ size: CGSize, _ colors: Colors, _ dark: Bool, _ time: Double) {
        radial(&context, colors.0.opacity(dark ? 0.3 : 0.16), center: CGPoint(x: size.width * 0.2, y: size.height * 0.1), radius: size.width)
        let layers: [(Color, Double, Double, Double)] = [
            (colors.0, 0.56, 0.9, 0.25),
            (colors.1, 0.66, 1.3, -0.35),
            (colors.2, 0.76, 1.7, 0.45)
        ]
        for (index, layer) in layers.enumerated() {
            var path = Path()
            let base = size.height * layer.1
            let amplitude = size.height * 0.035
            path.move(to: CGPoint(x: 0, y: size.height))
            var x: CGFloat = 0
            while x <= size.width + 8 {
                let angle = Double(x / size.width) * .pi * 2 * layer.2 + time * layer.3 + Double(index)
                path.addLine(to: CGPoint(x: x, y: base + amplitude * sin(angle)))
                x += 8
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            context.fill(path, with: .linearGradient(
                Gradient(colors: [layer.0.opacity(dark ? 0.32 : 0.2), layer.0.opacity(dark ? 0.08 : 0.04)]),
                startPoint: CGPoint(x: 0, y: base),
                endPoint: CGPoint(x: 0, y: size.height)
            ))
        }
    }

    fileprivate static func grid(_ context: inout GraphicsContext, _ size: CGSize, _ colors: Colors, _ dark: Bool, _ time: Double) {
        let horizon = size.height * 0.58
        context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: horizon)), with: .linearGradient(
            Gradient(colors: [colors.0.opacity(dark ? 0.05 : 0.02), colors.0.opacity(dark ? 0.35 : 0.18)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: horizon)
        ))
        radial(&context, colors.2.opacity(dark ? 0.55 : 0.35), center: CGPoint(x: size.width / 2, y: horizon), radius: size.width * 0.55)
        let lineColor = colors.1.opacity(dark ? 0.55 : 0.35)
        let vanishing = CGPoint(x: size.width / 2, y: horizon)
        for i in -10...10 {
            var path = Path()
            path.move(to: vanishing)
            path.addLine(to: CGPoint(x: size.width / 2 + CGFloat(i) * size.width * 0.18, y: size.height))
            context.stroke(path, with: .color(lineColor.opacity(0.7)), lineWidth: 1)
        }
        let rows = 12
        for k in 0..<rows {
            var t = (Double(k) / Double(rows) + time * 0.06).truncatingRemainder(dividingBy: 1)
            if t < 0 { t += 1 }
            let y = horizon + (size.height - horizon) * CGFloat(t * t)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(lineColor.opacity(0.25 + 0.75 * t)), lineWidth: 1)
        }
    }

    fileprivate static func gradient(_ context: inout GraphicsContext, _ size: CGSize, _ colors: Colors, _ dark: Bool, _ time: Double) {
        let angle = time * 0.05
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let reach = max(size.width, size.height) * 0.75
        let start = CGPoint(x: center.x - CGFloat(cos(angle)) * reach, y: center.y - CGFloat(sin(angle)) * reach)
        let end = CGPoint(x: center.x + CGFloat(cos(angle)) * reach, y: center.y + CGFloat(sin(angle)) * reach)
        let alpha = dark ? 0.38 : 0.22
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
            Gradient(colors: [colors.0.opacity(alpha), colors.1.opacity(alpha * 0.7), colors.2.opacity(alpha)]),
            startPoint: start, endPoint: end
        ))
    }

    fileprivate static func bokeh(_ context: inout GraphicsContext, _ size: CGSize, _ colors: Colors, _ dark: Bool, _ time: Double) {
        var random = Seeded(state: 7)
        let palette = [colors.0, colors.1, colors.2]
        for index in 0..<16 {
            let baseX = random.next()
            let baseY = random.next()
            let radius = size.width * (0.08 + random.next() * 0.16)
            let speed = 0.008 + random.next() * 0.018
            let phase = random.next() * .pi * 2
            var y = (baseY - time * speed).truncatingRemainder(dividingBy: 1.2)
            if y < -0.2 { y += 1.2 }
            let x = baseX + 0.04 * sin(time * 0.3 + phase)
            radial(
                &context,
                palette[index % 3].opacity(dark ? 0.32 : 0.2),
                center: CGPoint(x: x * size.width, y: y * size.height),
                radius: radius
            )
        }
    }
}
