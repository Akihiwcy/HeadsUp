import SwiftUI
import HeadsUpCore

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

/// Colors from the "paper relief" mockup, light and dark.
struct Palette {
    let ground: Color
    let ink: Color
    let sub: Color
    let ring: Color
    let ringLabelHalo: Color
    let accent: Color
    let accentRim: Color
    let card: Color
    let cardBorder: Color
    let chipOnBG: Color
    let chipOnFG: Color
    let chipOnSub: Color
    let shadow: Color
    let paperTint: Color
    let paperTintOpacity: Double
    let danger: Color

    static let light = Palette(
        ground: Color(hex: 0xEFEBE2), ink: Color(hex: 0x26211D), sub: Color(hex: 0x6B5B4D),
        ring: Color(hex: 0x3A2A1E, alpha: 0.5), ringLabelHalo: Color(hex: 0xFBFAF6),
        accent: Color(hex: 0xD93F26), accentRim: .white,
        card: .white, cardBorder: Color(hex: 0x26211D, alpha: 0.06),
        chipOnBG: Color(hex: 0x26211D), chipOnFG: Color(hex: 0xFBFAF6), chipOnSub: Color(hex: 0xD9D0C4),
        shadow: Color(hex: 0x3A2A18), paperTint: Color(hex: 0xEFE6D6), paperTintOpacity: 0.42,
        danger: Color(hex: 0xB3361F))

    static let dark = Palette(
        ground: Color(hex: 0x0D1319), ink: Color(hex: 0xEEF1F5), sub: Color(hex: 0xA9B4C2),
        ring: Color(hex: 0xE8DCC8, alpha: 0.5), ringLabelHalo: Color(hex: 0x1E2631),
        accent: Color(hex: 0xEE5135), accentRim: Color(hex: 0xEEF1F5),
        card: Color(hex: 0x1E2631), cardBorder: Color(hex: 0xE8DCC8, alpha: 0.16),
        chipOnBG: Color(hex: 0xEEF1F5), chipOnFG: Color(hex: 0x1A222C), chipOnSub: Color(hex: 0x4A5566),
        shadow: .black, paperTint: Color(hex: 0x0D1319), paperTintOpacity: 0.38,
        danger: Color(hex: 0xFF8A70))

    static func of(_ scheme: ColorScheme) -> Palette { scheme == .dark ? .dark : .light }
}

/// The aircraft silhouette from the mockup, drawn in a 24×24 box, nose up.
struct PlaneShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        var p = Path()
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        p.move(to: pt(12, 1.5))
        p.addCurve(to: pt(13.5, 4.3), control1: pt(12.9, 1.5), control2: pt(13.5, 2.7))
        p.addLine(to: pt(13.5, 9))
        p.addLine(to: pt(22, 14))
        p.addLine(to: pt(22, 16))
        p.addLine(to: pt(13.5, 13.4))
        p.addLine(to: pt(13.5, 18.5))
        p.addLine(to: pt(16, 20.4))
        p.addLine(to: pt(16, 22))
        p.addLine(to: pt(12, 21))
        p.addLine(to: pt(8, 22))
        p.addLine(to: pt(8, 20.4))
        p.addLine(to: pt(10.5, 18.5))
        p.addLine(to: pt(10.5, 13.4))
        p.addLine(to: pt(2, 16))
        p.addLine(to: pt(2, 14))
        p.addLine(to: pt(10.5, 9))
        p.addLine(to: pt(10.5, 4.3))
        p.addCurve(to: pt(12, 1.5), control1: pt(10.5, 2.7), control2: pt(11.1, 1.5))
        p.closeSubpath()
        return p
    }
}

enum Format {
    static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    static func int(_ v: Int) -> String { grouped.string(from: NSNumber(value: v)) ?? "\(v)" }

    static func km(_ v: Double) -> String {
        v.rounded() == v ? "\(Int(v))" : String(format: "%.1f", v)
    }

    static func trendArrow(_ t: Aircraft.Trend) -> String {
        switch t { case .climbing: return " ↗"; case .descending: return " ↘"; case .level: return "" }
    }
}
