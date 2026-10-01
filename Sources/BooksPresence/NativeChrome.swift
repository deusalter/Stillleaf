import SwiftUI
import AppKit

private struct NativePanelSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewBuilder func body(content: Content) -> some View {
        if opaque || contrast == .increased {
            content.background(ReadingPalette.canvas, in: RoundedRectangle(cornerRadius: 20))
        } else {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular, in: .rect(cornerRadius: 20))
            } else {
                content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            }
            #else
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            #endif
        }
    }
}

extension View {
    func nativePanelSurface() -> some View { modifier(NativePanelSurface()) }
}
