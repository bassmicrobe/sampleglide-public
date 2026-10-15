import SwiftUI
import AppKit

enum StudioTheme {
    static let background = Color(hex: 0x101116)
    static let sidebar = Color(hex: 0x15171F)
    static let surface = Color(hex: 0x1B1D27)
    static let raised = Color(hex: 0x252836)
    static let border = Color(hex: 0x303341)
    static let text = Color(hex: 0xF4F3FA)
    static let secondary = Color(hex: 0xA5A8BC)
    static let accent = Color(hex: 0xAD9AFF)
    static let accentStrong = Color(hex: 0x8C76F1)
    static let cyan = Color(hex: 0x6EDBD5)
    static let success = Color(hex: 0x79D7B0)
    static let warning = Color(hex: 0xF3BE7B)
    static let accentNS = NSColor(calibratedRed: 173/255, green: 154/255, blue: 1, alpha: 1)
    static let cyanNS = NSColor(calibratedRed: 110/255, green: 219/255, blue: 213/255, alpha: 1)
}

extension Color {
    fileprivate init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 255)/255, green: Double((hex >> 8) & 255)/255, blue: Double(hex & 255)/255)
    }
}

struct StudioButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .foregroundStyle(prominent ? StudioTheme.background : StudioTheme.text)
            .background(prominent ? StudioTheme.accent : StudioTheme.raised, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(prominent ? Color.clear : StudioTheme.border, lineWidth: 1))
            .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.38)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct StudioField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 15))
            .textFieldStyle(.plain)
            .padding(.horizontal, 13)
            .frame(height: 44)
            .background(StudioTheme.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StudioTheme.border, lineWidth: 1))
    }
}

extension View {
    func studioField() -> some View { modifier(StudioField()) }
}
