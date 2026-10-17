#if os(iOS) || os(visionOS)
    import UIKit
#else
    import AppKit
#endif

enum Clipboard {
    static func copy(_ text: String) {
        #if os(iOS) || os(visionOS)
            UIPasteboard.general.string = text
        #else
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
