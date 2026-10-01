import SwiftUI
import AppKit

private struct NativePreviewOpaque: EnvironmentKey { static let defaultValue: Bool? = nil }
extension EnvironmentValues {
    var nativePreviewOpaque: Bool? { get { self[NativePreviewOpaque.self] } set { self[NativePreviewOpaque.self] = newValue } }
}

private struct NativePanelSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.nativePreviewOpaque) private var previewOpaque
    @ViewBuilder func body(content: Content) -> some View {
        if (previewOpaque ?? opaque) || contrast == .increased {
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
