//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import BuildServerIntegration
import Foundation
import XCTest

final class XcodeSchemeTests: XCTestCase {
  #if !NO_SWIFTPM_DEPENDENCY
  private func scheme(buildEntries: String, extraActions: String = "") -> Data {
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <Scheme LastUpgradeVersion="1500" version="1.7">
         <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
            <BuildActionEntries>
      \(buildEntries)
            </BuildActionEntries>
         </BuildAction>
      \(extraActions)
      </Scheme>
      """
    return Data(xml.utf8)
  }

  private func entry(blueprintName: String, container: String = "MyApp.xcodeproj") -> String {
    """
          <BuildActionEntry buildForRunning="YES">
             <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="\(blueprintName)" BuildableName="\(blueprintName)" BlueprintName="\(blueprintName)" ReferencedContainer="container:\(container)"></BuildableReference>
          </BuildActionEntry>
    """
  }

  func testParsesBuildActionReferencesWithContainer() {
    let data = scheme(buildEntries: entry(blueprintName: "App") + "\n" + entry(blueprintName: "Framework"))
    XCTAssertEqual(
      XcodeScheme.schemeSeedReferences(xcschemeContents: data),
      [
        XcodeScheme.SchemeBuildableReference(blueprintName: "App", referencedContainer: "container:MyApp.xcodeproj"),
        XcodeScheme.SchemeBuildableReference(
          blueprintName: "Framework",
          referencedContainer: "container:MyApp.xcodeproj"
        ),
      ]
    )
  }

  func testEmptyBuildActionReturnsEmpty() {
    let data = scheme(buildEntries: "")
    XCTAssertEqual(XcodeScheme.schemeSeedReferences(xcschemeContents: data), [])
  }

  func testDeduplicatesByNameAndContainer() {
    // Same name + same container collapses to one; same name + different container stays distinct.
    let data = scheme(
      buildEntries: entry(blueprintName: "App") + "\n" + entry(blueprintName: "App") + "\n"
        + entry(blueprintName: "App", container: "Other.xcodeproj")
    )
    XCTAssertEqual(
      XcodeScheme.schemeSeedReferences(xcschemeContents: data),
      [
        XcodeScheme.SchemeBuildableReference(blueprintName: "App", referencedContainer: "container:MyApp.xcodeproj"),
        XcodeScheme.SchemeBuildableReference(blueprintName: "App", referencedContainer: "container:Other.xcodeproj"),
      ]
    )
  }

  func testCollectsBuildTestAndLaunchActionReferences() {
    // Build action: App. Test action: AppTests (skipped=NO) and AppUITests (skipped=YES). Launch action:
    // App (duplicate of the build-action App -> deduped). Skipped testables are still collected because
    // scope is about indexing, not running.
    let extraActions = """
           <TestAction buildConfiguration="Debug">
              <Testables>
                 <TestableReference skipped="NO">
                    <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="AppTests" BuildableName="AppTests.xctest" BlueprintName="AppTests" ReferencedContainer="container:MyApp.xcodeproj"></BuildableReference>
                 </TestableReference>
                 <TestableReference skipped="YES">
                    <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="AppUITests" BuildableName="AppUITests.xctest" BlueprintName="AppUITests" ReferencedContainer="container:MyApp.xcodeproj"></BuildableReference>
                 </TestableReference>
              </Testables>
           </TestAction>
           <LaunchAction buildConfiguration="Debug">
              <BuildableProductRunnable runnableDebuggingMode="0">
                 <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="App" BuildableName="App.app" BlueprintName="App" ReferencedContainer="container:MyApp.xcodeproj"></BuildableReference>
              </BuildableProductRunnable>
           </LaunchAction>
      """
    let data = scheme(buildEntries: entry(blueprintName: "App"), extraActions: extraActions)
    XCTAssertEqual(
      XcodeScheme.schemeSeedReferences(xcschemeContents: data),
      [
        XcodeScheme.SchemeBuildableReference(blueprintName: "App", referencedContainer: "container:MyApp.xcodeproj"),
        XcodeScheme.SchemeBuildableReference(
          blueprintName: "AppTests",
          referencedContainer: "container:MyApp.xcodeproj"
        ),
        XcodeScheme.SchemeBuildableReference(
          blueprintName: "AppUITests",
          referencedContainer: "container:MyApp.xcodeproj"
        ),
      ]
    )
  }

  private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcscheme-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }

  private func writeScheme(_ name: String, into schemesDir: URL, blueprintName: String) throws {
    try FileManager.default.createDirectory(at: schemesDir, withIntermediateDirectories: true)
    let data = scheme(buildEntries: entry(blueprintName: blueprintName))
    try data.write(to: schemesDir.appendingPathComponent("\(name).xcscheme", isDirectory: false))
  }

  private func writeSchemeWithContainer(
    _ name: String,
    into schemesDir: URL,
    blueprintName: String,
    container: String
  ) throws {
    try FileManager.default.createDirectory(at: schemesDir, withIntermediateDirectories: true)
    let data = scheme(buildEntries: entry(blueprintName: blueprintName, container: container))
    try data.write(to: schemesDir.appendingPathComponent("\(name).xcscheme", isDirectory: false))
  }

  func testBuildTargetsFindsSharedSchemeAndResolvesContainer() throws {
    let root = try makeTempDir()
    let container = root.appendingPathComponent("MyApp.xcodeproj", isDirectory: true)
    try writeScheme(
      "MyApp",
      into: container.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true),
      blueprintName: "MyApp"
    )
    let result = try XCTUnwrap(XcodeScheme.buildTargets(scheme: "MyApp", containerPath: container, projectRoot: root))
    XCTAssertEqual(result.map(\.blueprintName), ["MyApp"])
    XCTAssertEqual(
      result.first?.container?.standardizedFileURL.path,
      root.appendingPathComponent("MyApp.xcodeproj").standardizedFileURL.path
    )
  }

  func testBuildTargetsPrefersSharedOverUser() throws {
    let root = try makeTempDir()
    let container = root.appendingPathComponent("MyApp.xcodeproj", isDirectory: true)
    try writeScheme(
      "MyApp",
      into: container.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true),
      blueprintName: "SharedTarget"
    )
    try writeScheme(
      "MyApp",
      into: container.appendingPathComponent("xcuserdata/me.xcuserdatad/xcschemes", isDirectory: true),
      blueprintName: "UserTarget"
    )
    XCTAssertEqual(
      XcodeScheme.buildTargets(scheme: "MyApp", containerPath: container, projectRoot: root)?.map(\.blueprintName),
      ["SharedTarget"]
    )
  }

  func testBuildTargetsFindsUserSchemeWhenNoShared() throws {
    let root = try makeTempDir()
    let container = root.appendingPathComponent("MyApp.xcodeproj", isDirectory: true)
    try writeScheme(
      "MyApp",
      into: container.appendingPathComponent("xcuserdata/me.xcuserdatad/xcschemes", isDirectory: true),
      blueprintName: "UserTarget"
    )
    XCTAssertEqual(
      XcodeScheme.buildTargets(scheme: "MyApp", containerPath: container, projectRoot: root)?.map(\.blueprintName),
      ["UserTarget"]
    )
  }

  func testBuildTargetsReturnsNilWhenMissing() throws {
    let root = try makeTempDir()
    let container = root.appendingPathComponent("MyApp.xcodeproj", isDirectory: true)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    XCTAssertNil(XcodeScheme.buildTargets(scheme: "Nope", containerPath: container, projectRoot: root))
  }

  func testBuildTargetsResolvesContainerRelativeToMatchedContainerDir() throws {
    // Workspace shared scheme: container references resolve relative to the workspace's parent dir.
    let root = try makeTempDir()
    let workspace = root.appendingPathComponent("MyWorkspace.xcworkspace", isDirectory: true)
    try writeSchemeWithContainer(
      "App",
      into: workspace.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true),
      blueprintName: "App",
      container: "AppA/AppA.xcodeproj"
    )
    let result = try XCTUnwrap(XcodeScheme.buildTargets(scheme: "App", containerPath: workspace, projectRoot: root))
    XCTAssertEqual(result.first?.blueprintName, "App")
    XCTAssertEqual(
      result.first?.container?.standardizedFileURL.path,
      root.appendingPathComponent("AppA/AppA.xcodeproj").standardizedFileURL.path
    )
  }

  func testBuildTargetsFindsSchemeInWorkspaceMemberProject() throws {
    // Scheme lives in a member .xcodeproj under the workspace, not in the workspace itself.
    let root = try makeTempDir()
    let workspace = root.appendingPathComponent("MyApp.xcworkspace", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let member = root.appendingPathComponent("Member.xcodeproj", isDirectory: true)
    try writeSchemeWithContainer(
      "MyApp",
      into: member.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true),
      blueprintName: "MemberTarget",
      container: "Member.xcodeproj"
    )
    let result = try XCTUnwrap(
      XcodeScheme.buildTargets(scheme: "MyApp", containerPath: workspace, projectRoot: root)
    )
    XCTAssertEqual(result.first?.blueprintName, "MemberTarget")
    XCTAssertEqual(
      result.first?.container?.standardizedFileURL.path,
      root.appendingPathComponent("Member.xcodeproj").standardizedFileURL.path
    )
  }

  func testBuildTargetsFindsSchemeInSubdirectoryMemberViaNestedGroup() throws {
    // The workspace references a member .xcodeproj nested in a subdirectory via <Group>. The scheme lives in
    // that subdir project; discovery must follow contents.xcworkspacedata, not a top-level glob.
    let root = try makeTempDir()
    let workspace = root.appendingPathComponent("MyWorkspace.xcworkspace", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let workspacedata = """
      <?xml version="1.0" encoding="UTF-8"?>
      <Workspace version = "1.0">
         <Group location = "group:Modules">
            <FileRef location = "group:MyLib/MyLib.xcodeproj"></FileRef>
         </Group>
      </Workspace>
      """
    try (workspacedata + "\n").write(
      to: workspace.appendingPathComponent("contents.xcworkspacedata", isDirectory: false),
      atomically: true,
      encoding: .utf8
    )
    let member = root.appendingPathComponent("Modules/MyLib/MyLib.xcodeproj", isDirectory: true)
    try writeSchemeWithContainer(
      "MyLib",
      into: member.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true),
      blueprintName: "MyLib",
      container: "MyLib.xcodeproj"
    )
    let result = try XCTUnwrap(
      XcodeScheme.buildTargets(scheme: "MyLib", containerPath: workspace, projectRoot: root)
    )
    XCTAssertEqual(result.first?.blueprintName, "MyLib")
    // The scheme's `container:MyLib.xcodeproj` resolves relative to the subdirectory member project's
    // own directory (where the scheme file was found), proving subdir-based container resolution works.
    XCTAssertEqual(
      result.first?.container?.standardizedFileURL.path,
      root.appendingPathComponent("Modules/MyLib/MyLib.xcodeproj").standardizedFileURL.path
    )
  }

  // MARK: - resolveContainer

  func testResolveContainerResolvesRelativeToBaseDir() {
    let base = URL(fileURLWithPath: "/ws", isDirectory: true)
    XCTAssertEqual(
      XcodeScheme.resolveContainer("container:AppA/AppA.xcodeproj", relativeTo: base)?.path,
      "/ws/AppA/AppA.xcodeproj"
    )
  }

  func testResolveContainerReturnsNilForNilOrNonContainerPrefix() {
    let base = URL(fileURLWithPath: "/ws", isDirectory: true)
    XCTAssertNil(XcodeScheme.resolveContainer(nil, relativeTo: base))
    XCTAssertNil(XcodeScheme.resolveContainer("AppA.xcodeproj", relativeTo: base))
    XCTAssertNil(XcodeScheme.resolveContainer("container:", relativeTo: base))
  }
  #endif
}
