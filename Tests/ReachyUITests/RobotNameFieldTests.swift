@testable import ReachyUI
import Testing

/// The name field is greyed out rather than hidden on a daemon that cannot rename:
/// hiding it would read as "this robot has no name", and the footer is the only place
/// left to say what would make it editable.
@Suite("Robot name field")
struct RobotNameFieldTests {
    @Test("a daemon that can rename leaves the field editable")
    func editableWhenSupported() {
        let field = RobotNameField(supportsRename: true, daemonVersion: "1.9.0")

        #expect(field.isEditable)
        #expect(field.footer == "The name identifies this robot on the network. The hardware ID never changes.")
    }

    @Test("software that cannot rename names the version standing in the way")
    func explainsWhichDaemonCannotRename() {
        let field = RobotNameField(supportsRename: false, daemonVersion: "1.9.0")

        #expect(!field.isEditable)
        #expect(field.footer.contains("version 1.9.0"))
        #expect(!field.footer.contains("daemon"))
        #expect(field.footer.contains("The hardware ID never changes."))
    }

    /// The handshake reports no version for a daemon that omits it; the sentence still
    /// has to make sense without one.
    @Test("an unknown version still explains why the field is greyed out")
    func explainsWithoutAVersion() {
        let field = RobotNameField(supportsRename: false, daemonVersion: nil)

        #expect(!field.isEditable)
        #expect(!field.footer.contains("daemon "))
        #expect(field.footer.contains("newer robot software"))
    }
}
