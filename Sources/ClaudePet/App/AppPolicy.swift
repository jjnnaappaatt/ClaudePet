import AppKit

/// Shared activation-policy handling for the two real windows (Settings and the dashboard).
///
/// The app ships as `LSUIElement` and runs `.accessory` so it has no Dock icon or menu bar. Both
/// windows flip it to `.regular` while open, because an `.accessory` app's windows can't reliably
/// become key (text fields wouldn't type) and get no menu bar (⌃⌘F wouldn't work).
enum AppPolicy {

    /// Drop back to the dockless `.accessory` policy — but only if no OTHER real window is still
    /// open. Each controller reverting unconditionally meant closing one window yanked the Dock icon
    /// and menu bar out from under the other one that was still on screen.
    ///
    /// The widget panel is deliberately not counted: it omits `.titled` (that's what makes it
    /// frameless), and it works fine under `.accessory` — that's its normal state.
    @MainActor
    static func revertToAccessory(unless keep: NSWindow?) {
        let otherRealWindowOpen = NSApp.windows.contains { w in
            w !== keep && w.isVisible && w.styleMask.contains(.titled)
        }
        if !otherRealWindowOpen {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Give the (SwiftUI-provided) View menu the standard full-screen item.
    ///
    /// Verified by spike: flipping to `.regular` DOES produce a main menu — ClaudePet | Edit | View |
    /// Window | Help — but its View submenu is **completely empty**, because SwiftUI only populates
    /// it for a scene it owns and this app's only scene is `Settings`. Without this item the green
    /// button still works while ⌃⌘F is dead, which is a trap once the window is full screen and the
    /// title bar is hidden. Returns the item so its title can track the state.
    ///
    /// `target` stays nil so it routes through the responder chain to the key window, which is how
    /// AppKit's own item behaves.
    @MainActor
    static func installFullScreenMenuItem() -> NSMenuItem? {
        guard let view = NSApp.mainMenu?.items.first(where: { $0.title == "View" })?.submenu
        else { return nil }

        let selector = #selector(NSWindow.toggleFullScreen(_:))
        if let existing = view.items.first(where: { $0.action == selector } ) { return existing }

        let item = NSMenuItem(title: "Enter Full Screen", action: selector, keyEquivalent: "f")
        item.keyEquivalentModifierMask = [.control, .command]
        view.addItem(item)
        return item
    }
}
