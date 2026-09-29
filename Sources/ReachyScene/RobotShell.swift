import Foundation

/// The robot's printed white shell — the parts a theme paints.
///
/// Matched by mesh file rather than by colour: "white" is a property of this one
/// description, and a revision that shipped a grey shell, or a white part that is
/// not shell, would repaint the wrong thing with no error. A description that
/// names none of these files is simply left in its own colours.
public enum RobotShell {
    /// Body and head. Deliberately not `antenna_body_3dprint.stl` — the antenna
    /// housings are the same white plastic, and leaving them white was a product
    /// decision (2026-09-29), not an oversight. `neck_reference_3dprint.stl` is not
    /// shell either: it is 0.9 grey and sits inside the head.
    public static let meshFilenames: Set<String> = [
        "body_down_3dprint.stl",
        "body_top_3dprint.stl",
        "head_front_3dprint.stl",
        "head_back_3dprint.stl",
        "head_mic_3dprint.stl",
    ]

    /// Compares the last path component, so a filename arriving with or without
    /// its `assets/` directory matches the same.
    static func contains(meshFilename filename: String) -> Bool {
        meshFilenames.contains((filename as NSString).lastPathComponent)
    }
}
