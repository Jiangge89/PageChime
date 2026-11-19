import SwiftUI

/// Night-time palette: the app is used at bedtime, often in a dim room.
enum Theme {
    static let night = Color(hex: 0x0F1430)
    static let deepNight = Color(hex: 0x06080F)
    static let surface = Color(hex: 0x1A2148)
    static let surfaceLow = Color(hex: 0x161D40)
    static let line = Color(hex: 0x2C3566)
    static let numberFill = Color(hex: 0x2A3470)

    static let text = Color(hex: 0xF4EFE4)
    static let muted = Color(hex: 0xA7AEC8)
    static let faint = Color(hex: 0x8E96B5)

    static let gold = Color(hex: 0xF2B45A)
    static let onGold = Color(hex: 0x1A1405)
    static let success = Color(hex: 0x7FD1A6)

    static let paper = Color(hex: 0xF6EEDC)
    static let ink = Color(hex: 0x2A2418)
    static let highlight = Color(hex: 0xF7D79A)

    /// Storybook serif (New York) for headings.
    static func serif(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// Picks the English or Chinese string for the reading language.
struct Copy {
    let chinese: Bool
    func callAsFunction(_ english: String, _ chineseText: String) -> String {
        chinese ? chineseText : english
    }
}

enum SoundName {
    /// "wolf_howl" → "Wolf howl".
    static func display(_ soundID: String) -> String {
        let words = soundID.split(separator: "_").joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// "forest_ambience" → "Forest".
    static func scene(_ soundID: String) -> String {
        var id = soundID
        for suffix in ["_ambience", "_ambient", "_loop", "_bed"] where id.hasSuffix(suffix) {
            id = String(id.dropLast(suffix.count))
        }
        return display(id)
    }

    static func symbol(for type: StoryEventType) -> String {
        switch type {
        case .animal: return "pawprint"
        case .weather: return "cloud.bolt"
        case .vehicle: return "car"
        case .action: return "figure.walk"
        case .environment: return "leaf"
        case .object: return "cube"
        }
    }
}

// MARK: - Shared controls

struct GoldButtonStyle: ButtonStyle {
    var height: CGFloat = 60

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .semibold))
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(Theme.gold.opacity(configuration.isPressed ? 0.8 : 1))
            .foregroundStyle(Theme.onGold)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .foregroundStyle(Theme.text)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Theme.line, lineWidth: 1)
                    .background(configuration.isPressed ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 16))
            )
    }
}

/// Round 44pt button used in the top bars.
struct CircleIconButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: 44, height: 44)
                .background(Theme.surface, in: Circle())
        }
        .accessibilityLabel(label)
    }
}
