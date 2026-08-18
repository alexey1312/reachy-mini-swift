import Foundation
@testable import ReachyKit
import ReachySimulator
import simd
import Testing

@Suite("URDF parser")
struct URDFParserTests {
    /// Mirrors the shapes the real robot description uses — two links joined by a
    /// revolute joint, a visual with an inline material, and a collision block
    /// that repeats the visual's mesh.
    private static let sample = """
    <?xml version="1.0" ?>
    <robot name="sample">
      <link name="base">
        <inertial>
          <origin xyz="0 0 1" rpy="0 0 0"/>
          <mass value="0.5"/>
        </inertial>
        <visual>
          <origin xyz="0.1 0.2 0.3" rpy="0 0 1.5708"/>
          <geometry><mesh filename="package://assets/base.stl"/></geometry>
          <material name="base_material"><color rgba="0.3 0.3 0.3 1"/></material>
        </visual>
        <collision>
          <origin xyz="9 9 9" rpy="0 0 0"/>
          <geometry><mesh filename="package://assets/base_collider.stl"/></geometry>
        </collision>
      </link>
      <link name="arm">
        <visual>
          <geometry><box size="0.01 0.02 0.03"/></geometry>
        </visual>
      </link>
      <joint name="shoulder" type="revolute">
        <origin xyz="0 0 0.04" rpy="0 0 0"/>
        <parent link="base"/>
        <child link="arm"/>
        <axis xyz="0 0 1"/>
        <limit effort="10" velocity="8" lower="-0.837758" upper="1.39626"/>
      </joint>
    </robot>
    """

    @Test("reads the link and joint tree")
    func tree() throws {
        let urdf = try URDFParser.parse(Self.sample)
        #expect(urdf.name == "sample")
        #expect(urdf.links.count == 2)
        #expect(urdf.joints.count == 1)
        #expect(urdf.rootLinkName == "base")
        #expect(urdf.childJoints(of: "base").map(\.name) == ["shoulder"])
        #expect(urdf.childJoints(of: "arm").isEmpty)
    }

    @Test("reads joint frame, axis and limits")
    func jointDetail() throws {
        let joint = try #require(URDFParser.parse(Self.sample).joint(named: "shoulder"))
        #expect(joint.kind == .revolute)
        #expect(joint.parent == "base")
        #expect(joint.child == "arm")
        #expect(joint.origin.xyz == SIMD3(0, 0, 0.04))
        #expect(joint.axis == SIMD3(0, 0, 1))
        #expect(joint.limit == -0.837758 ... 1.39626)
    }

    /// Collision geometry doubles the mesh count and none of it is ever drawn, so
    /// letting it through would double the download for nothing.
    @Test("collision geometry never reaches the mesh list")
    func collisionIgnored() throws {
        let urdf = try URDFParser.parse(Self.sample)
        #expect(urdf.visualMeshFilenames == ["base.stl"])
        #expect(urdf.link(named: "base")?.visuals.count == 1)
    }

    @Test("package:// prefix is stripped down to the daemon's filename")
    func meshNaming() throws {
        let urdf = try URDFParser.parse(Self.sample)
        let visual = try #require(urdf.link(named: "base")?.visuals.first)
        #expect(visual.geometry == .mesh(filename: "base.stl", scale: SIMD3(1, 1, 1)))
        #expect(visual.color == URDFColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1))
    }

    /// An inertial `<origin>` sits before the visual one and must not be mistaken
    /// for it — a plain "last origin wins" reader gets this wrong.
    @Test("inertial data does not leak into the visual frame")
    func inertialIgnored() throws {
        let visual = try #require(URDFParser.parse(Self.sample).link(named: "base")?.visuals.first)
        #expect(visual.origin.xyz == SIMD3(0.1, 0.2, 0.3))
        #expect(abs(visual.origin.rpy.z - 1.5708) < 1e-9)
    }

    @Test("a missing origin means identity")
    func defaultOrigin() throws {
        let visual = try #require(URDFParser.parse(Self.sample).link(named: "arm")?.visuals.first)
        #expect(visual.origin == .identity)
        #expect(visual.geometry == .box(size: SIMD3(0.01, 0.02, 0.03)))
    }

    @Test("non-mesh primitives are kept")
    func primitives() throws {
        let urdf = try URDFParser.parse("""
        <robot name="p">
          <link name="a">
            <visual><geometry><cylinder radius="0.5" length="2"/></geometry></visual>
            <visual><geometry><sphere radius="0.25"/></geometry></visual>
          </link>
        </robot>
        """)
        #expect(urdf.link(named: "a")?.visuals.map(\.geometry) == [
            .cylinder(radius: 0.5, length: 2),
            .sphere(radius: 0.25),
        ])
    }

    @Test("movable joints exclude fixed ones")
    func movableJoints() throws {
        let urdf = try URDFParser.parse("""
        <robot name="m">
          <link name="a"/><link name="b"/><link name="c"/>
          <joint name="weld" type="fixed"><parent link="a"/><child link="b"/></joint>
          <joint name="spin" type="continuous"><parent link="b"/><child link="c"/></joint>
        </robot>
        """)
        #expect(urdf.movableJoints.map(\.name) == ["spin"])
        #expect(urdf.joint(named: "spin")?.limit == nil)
    }

    @Test("an unnormalised axis is normalised")
    func axisNormalisation() throws {
        let urdf = try URDFParser.parse("""
        <robot name="n">
          <link name="a"/><link name="b"/>
          <joint name="j" type="revolute">
            <parent link="a"/><child link="b"/><axis xyz="0 0 5"/>
          </joint>
        </robot>
        """)
        #expect(urdf.joint(named: "j")?.axis == SIMD3(0, 0, 1))
    }

    @Test("a joint pointing at an undeclared link is rejected")
    func unknownLink() {
        #expect(throws: URDFParseError.unknownLink("ghost", referencedBy: "j")) {
            try URDFParser.parse("""
            <robot name="x">
              <link name="a"/>
              <joint name="j" type="fixed"><parent link="a"/><child link="ghost"/></joint>
            </robot>
            """)
        }
    }

    @Test("a forest is rejected — the scene needs one root")
    func multipleRoots() {
        #expect(throws: URDFParseError.notASingleRootedTree(rootCount: 2)) {
            try URDFParser.parse(#"<robot name="x"><link name="a"/><link name="b"/></robot>"#)
        }
    }

    @Test("an unsupported joint type is reported by name")
    func unknownJointType() {
        #expect(throws: URDFParseError.unknownJointType("screw")) {
            try URDFParser.parse("""
            <robot name="x">
              <link name="a"/><link name="b"/>
              <joint name="j" type="screw"><parent link="a"/><child link="b"/></joint>
            </robot>
            """)
        }
    }

    @Test("broken XML fails as a parse error, not a crash")
    func malformedXML() {
        #expect(throws: URDFParseError.self) {
            try URDFParser.parse("<robot name=\"x\"><link name=\"a\">")
        }
    }
}

/// Validates the parser against a real robot description.
///
/// **These ran nowhere until `ReachySimulator` landed.** The suite was gated on
/// `REACHY_URDF_FIXTURE` because this client shipped no robot geometry — every
/// assertion below was written against a file someone had pulled off a daemon by
/// hand, and then skipped on every machine that had not. The simulator carries
/// upstream's description precisely so a session with no robot can draw one, and
/// the same file answers this suite.
///
/// The environment variable still wins where it is set: pointed at
/// `GET /api/kinematics/urdf` from a live daemon, it is what would catch upstream
/// changing the shape the viewer assumes before the bundled copy is refreshed.
@Suite("URDF parser against a real description")
struct RealURDFTests {
    private func loadDocument() throws -> URDFDocument {
        if let path = ProcessInfo.processInfo.environment["REACHY_URDF_FIXTURE"] {
            return try URDFParser.parse(Data(contentsOf: URL(fileURLWithPath: path)))
        }
        return try URDFParser.parse(BundledRobotGeometry().urdf())
    }

    @Test("the Reachy Mini tree has the shape the viewer assumes")
    func shape() throws {
        let urdf = try loadDocument()
        #expect(urdf.links.count == 45)
        #expect(urdf.joints.count == 44)
        #expect(urdf.joints.filter { $0.kind == .revolute }.count == 30)
        #expect(urdf.joints.filter { $0.kind == .fixed }.count == 14)
        #expect(urdf.rootLinkName == "body_foot_3dprint")
    }

    @Test("the nine actuators are present with the axes the solver expects")
    func actuators() throws {
        let urdf = try loadDocument()
        let names = ["yaw_body", "left_antenna", "right_antenna"]
            + (1 ... 6).map { "stewart_\($0)" }
        for name in names {
            let joint = try #require(urdf.joint(named: name), "missing \(name)")
            #expect(joint.axis == SIMD3(0, 0, 1), "\(name) axis")
        }
        #expect(urdf.joint(named: "yaw_body")?.limit == -2.79253 ... 2.79253)
    }

    /// Seven spherical joints, each split into an x-y-z chain because URDF has no
    /// spherical type. Legs 1-5 are cut open and closed by fixed frames; only leg
    /// 6 runs through to the head, which is why there is a seventh.
    @Test("all 21 passive joints are declared as an orthogonal chain")
    func passiveJoints() throws {
        let urdf = try loadDocument()
        let axes: [String: SIMD3<Double>] = [
            "x": SIMD3(1, 0, 0), "y": SIMD3(0, 1, 0), "z": SIMD3(0, 0, 1),
        ]
        for index in 1 ... 7 {
            for (suffix, axis) in axes {
                let joint = try #require(urdf.joint(named: "passive_\(index)_\(suffix)"))
                #expect(joint.kind == .revolute)
                #expect(joint.axis == axis)
            }
        }
    }

    /// The head hangs off leg 6 through both passive wrists, so zeroing the passive
    /// joints moves the head itself — not just the rods.
    @Test("the head link descends from leg 6 through both passive wrists")
    func headChain() throws {
        let urdf = try loadDocument()
        var chain: [String] = []
        var link = "xl_330"
        while let joint = urdf.joints.first(where: { $0.child == link }) {
            chain.append(joint.name)
            link = joint.parent
        }
        #expect(chain.prefix(3) == ["passive_7_z", "passive_7_y", "passive_7_x"])
        #expect(chain.contains("stewart_6"))
        #expect(link == urdf.rootLinkName)
    }

    @Test("visual meshes are far fewer than the asset directory")
    func meshes() throws {
        let urdf = try loadDocument()
        #expect(urdf.visualMeshFilenames.count == 41)
        #expect(urdf.visualMeshFilenames.allSatisfy { $0.hasSuffix(".stl") })
        #expect(urdf.visualMeshFilenames.allSatisfy { !$0.contains("://") })
    }
}
