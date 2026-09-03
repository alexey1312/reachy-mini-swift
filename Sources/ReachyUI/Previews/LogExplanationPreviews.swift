@testable import ReachyUI
import SwiftUI

// The entry point when Apple Intelligence is there. Paired with the nine existing
// `Log console —` references, which all draw the *absence*: a reference for the
// offered state alone cannot tell a conditional toolbar item from a permanent one.
#Preview("Log console — explain offered") {
    PreviewScene.logConsole(explain: .preview(.idle))
}

// The one preview here carrying an indeterminate spinner, and therefore the one to
// diff first if a run reports references moving that nothing touched.
#Preview("Log explanation — reading") {
    PreviewScene.logExplanation(.explaining)
}

// A summary written by hand rather than generated: a preview must be final on its
// first frame, and this is also the only way a reference can show real wrapping over
// the paragraph-and-bullets shape the instructions ask the model for.
#Preview("Log explanation — explained") {
    PreviewScene.logExplanation(.explained(LogExplanationModel.previewExplanation))
}

// A Foundation Models failure is not a daemon failure, so it carries the framework's
// own sentence rather than anything `RobotSession.message(for:)` would have produced.
#Preview("Log explanation — failed") {
    PreviewScene.logExplanation(.failed("The model was unable to respond to this prompt."))
}
