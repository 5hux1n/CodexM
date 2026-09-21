import SwiftUI

extension View {
    /// Uses the native macOS help tag so timing, material and accessibility
    /// follow the current system appearance automatically.
    func hoverTooltip(_ text: String) -> some View {
        help(text)
    }
}
