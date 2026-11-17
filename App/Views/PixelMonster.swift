import SwiftUI

/// The app's mascot: a little pixel monster in retro arcade style.
/// It is painted in the colours of the current theme, steps from foot to foot,
/// looks around and blinks. With motion turned off it stands still.
struct PixelMonster: View {
    var size: CGFloat = 84

    var body: some View {
        if Motion.isRunning {
            TimelineView(.periodic(from: .now, by: 0.12)) { context in
                sprite(time: context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            sprite(time: nil)
        }
    }

    private func sprite(time: Double?) -> some View {
        let pose = Pose(time: time)
        return Canvas { context, canvasSize in
            let rows = Self.rows(for: pose)
            let columns = rows.first?.count ?? 1
            let pixel = floor(min(canvasSize.width / CGFloat(columns), canvasSize.height / CGFloat(rows.count)))
            let originX = (canvasSize.width - pixel * CGFloat(columns)) / 2
            let originY = (canvasSize.height - pixel * CGFloat(rows.count)) / 2
            for (y, row) in rows.enumerated() {
                for (x, symbol) in row.enumerated() {
                    guard let color = Self.color(for: symbol) else { continue }
                    let rect = CGRect(
                        x: originX + CGFloat(x) * pixel,
                        y: originY + CGFloat(y) * pixel,
                        width: pixel + 0.5,
                        height: pixel + 0.5
                    )
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
        .frame(width: size, height: size)
        .offset(y: pose.bob)
        .shadow(color: Theme.tint.opacity(0.45), radius: size * 0.16, y: size * 0.06)
        .accessibilityHidden(true)
    }

    // MARK: Pose

    /// Where the monster looks, whether it blinks and which foot is up, derived from the time.
    private struct Pose {
        enum Look { case left, center, right }

        var look: Look = .center
        var blinking = false
        var stepFrame = 0
        var bob: CGFloat = 0

        init(time: Double?) {
            guard let time else { return }
            stepFrame = Int(time / 0.36) % 2
            bob = stepFrame == 0 ? 0 : -2
            // Looks around in a slow loop: centre, left, centre, right.
            switch Int(time / 1.6) % 4 {
            case 1: look = .left
            case 3: look = .right
            default: look = .center
            }
            // A short blink roughly every four seconds.
            blinking = time.truncatingRemainder(dividingBy: 4.2) < 0.15
        }
    }

    // MARK: Sprite

    /// 14 × 14 pixels.
    /// B body · S shade · H highlight · W eye white · P pupil · M mouth · F foot · . empty
    private static func rows(for pose: Pose) -> [[Character]] {
        let eyesTop: String
        let eyesBottom: String
        if pose.blinking {
            eyesTop = ".BHBBBBBBBBBB."
            eyesBottom = ".BBBMMBBMMBBB."
        } else {
            switch pose.look {
            case .left:
                eyesTop = ".BHBWWBBWWBBB."
                eyesBottom = ".BBBPWBBPWBBB."
            case .right:
                eyesTop = ".BHBWWBBWWBBB."
                eyesBottom = ".BBBWPBBWPBBB."
            case .center:
                eyesTop = ".BHBWWBBWWBBB."
                eyesBottom = ".BBBPPBBPPBBB."
            }
        }
        let feet = pose.stepFrame == 0 ? "..FF......FF.." : "...FF....FF..."
        return [
            "..S........S..",
            "...S......S...",
            "...BBBBBBBB...",
            "..BBBBBBBBBB..",
            ".BBHHBBBBBBBB.",
            eyesTop,
            eyesBottom,
            "BBBBBBBBBBBBBB",
            "BBBBBBBBBBBBBB",
            "BBBBBMMMMBBBBB",
            "BBBBBBMMBBBBBB",
            "SBBBBBBBBBBBBS",
            ".SSBBSSSSBBSS.",
            feet
        ].map(Array.init)
    }

    private static func color(for symbol: Character) -> Color? {
        switch symbol {
        case "B": return Theme.tint
        case "S", "F": return Theme.primary
        case "H": return Color.white.opacity(0.55)
        case "W": return .white
        case "P": return Color(red: 0.08, green: 0.08, blue: 0.14)
        case "M": return Color.black.opacity(0.55)
        default: return nil
        }
    }
}
