import AppKit
import SwiftUI

/// An `NSHostingView` that says when its content's size changes, so the panel can follow it.
///
/// `sizingOptions = .intrinsicContentSize` makes the hosting view *report* a new size whenever the
/// SwiftUI content's changes, but nothing resizes the window to it — `WindowController.fitToContent`
/// has to be called, and it used to be called only at launch, on a settings change, and during a
/// resize drag. The launch fit runs before `metrics.start()`, i.e. against near-empty content.
/// Measured on a fresh launch: fitted to 427pt, the scan then grew the content to 611pt at t=8s, and
/// the panel stayed at 427 — header and footer (with its buttons) clipped until the next settings
/// change or resize happened to refit it. Every launch had this; something usually masked it.
///
/// Hooking the invalidation catches every cause at once — the first scan, a Codex row appearing, a
/// model family showing up mid-day, a day rolling over — instead of enumerating them and missing
/// the next one.
final class FittingHostingView<Content: View>: NSHostingView<Content> {
    var onIntrinsicSizeChange: (() -> Void)?
    private var refitPending = false

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        // Coalesced and deferred: this fires several times within one layout pass, and resizing the
        // window from inside that pass would re-enter it.
        guard !refitPending, onIntrinsicSizeChange != nil else { return }
        refitPending = true
        DispatchQueue.main.async { [weak self] in
            self?.refitPending = false
            self?.onIntrinsicSizeChange?()
        }
    }
}
