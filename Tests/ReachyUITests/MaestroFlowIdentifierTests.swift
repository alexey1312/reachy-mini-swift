import Foundation
@testable import ReachyUI
import Testing

/// The flows in `Apps/Maestro` select controls by `AccessibilityID`, and YAML is a
/// second spelling of the same list that no compiler reads. A renamed identifier
/// fails a flow only when somebody runs it — and the daemon flow runs nowhere but
/// a laptop — so this suite reads the files the way `CallProjectLockstepTests`
/// reads `Project.swift`.
@Suite("Maestro flow identifiers")
struct MaestroFlowIdentifierTests {
    @Test("every identifier a flow selects is one the app declares")
    func flowsNameDeclaredIdentifiers() throws {
        let declared = Set(AccessibilityID.allCases.map(\.rawValue))
        let selected = try selectedIdentifiers()

        #expect(!selected.isEmpty, "no flow selects by id — the parsing below has stopped matching")
        for (flow, id) in selected {
            #expect(declared.contains(id), "\(flow) selects \"\(id)\", which AccessibilityID does not declare")
        }
    }

    /// An identifier nothing selects is a promise nobody checks: it can be moved to
    /// the wrong element — `connect.developer` did land on every disclosed row once —
    /// and no flow would say so.
    @Test("every identifier the app declares is selected by some flow")
    func declaredIdentifiersAreSelected() throws {
        let selected = try Set(selectedIdentifiers().map(\.id))
        for id in AccessibilityID.allCases {
            #expect(selected.contains(id.rawValue), "no flow in Apps/Maestro selects \"\(id.rawValue)\"")
        }
    }
}

private let maestroDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // ReachyUITests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // repo root
    .appendingPathComponent("Apps/Maestro")

/// Every `id:` line in every flow, with the flow's file name. `config.yaml` has
/// none, so it needs no exclusion.
private func selectedIdentifiers() throws -> [(flow: String, id: String)] {
    let flows = try FileManager.default
        .contentsOfDirectory(at: maestroDirectory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "yaml" }
    let line = /^\s*id:\s*"?([^"\s]+)"?\s*$/
    return try flows.flatMap { flow in
        try String(contentsOf: flow, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { try line.wholeMatch(in: $0).map { (flow.lastPathComponent, String($0.1)) } }
    }
}
