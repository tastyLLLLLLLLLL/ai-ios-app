import SwiftUI

enum Theme {
    static let violet = Color(red: 0.49, green: 0.36, blue: 1.0)
    static let blue = Color(red: 0.31, green: 0.55, blue: 1.0)
    static let cyan = Color(red: 0.21, green: 0.82, blue: 0.90)

    static let accent = LinearGradient(
        colors: [violet, blue, cyan],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let bubble = LinearGradient(
        colors: [violet, blue],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// Soft coloured glow behind every screen. Static on purpose: the GPU is busy running the model.
struct AuroraBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        ZStack {
            (dark ? Color(red: 0.035, green: 0.035, blue: 0.07) : Color(red: 0.965, green: 0.96, blue: 0.985))

            GeometryReader { proxy in
                let size = proxy.size
                Circle()
                    .fill(Theme.violet.opacity(dark ? 0.38 : 0.22))
                    .frame(width: size.width * 0.9)
                    .blur(radius: 110)
                    .offset(x: -size.width * 0.35, y: -size.width * 0.3)
                Circle()
                    .fill(Theme.cyan.opacity(dark ? 0.22 : 0.18))
                    .frame(width: size.width * 0.8)
                    .blur(radius: 120)
                    .offset(x: size.width * 0.5, y: size.height * 0.25)
                Circle()
                    .fill(Theme.blue.opacity(dark ? 0.26 : 0.16))
                    .frame(width: size.width * 0.9)
                    .blur(radius: 130)
                    .offset(x: -size.width * 0.2, y: size.height * 0.72)
            }
        }
        .ignoresSafeArea()
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

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.accent)
                .blur(radius: size * 0.28)
                .opacity(pulse ? 0.75 : 0.45)
                .scaleEffect(pulse ? 1.12 : 0.96)
            Circle()
                .fill(Theme.accent)
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
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                pulse = true
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
