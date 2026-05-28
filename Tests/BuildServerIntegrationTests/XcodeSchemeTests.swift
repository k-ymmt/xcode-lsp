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
    let result = try XCTUnwrap(XcodeScheme.buildTargets(scheme: "MyApp", searchContainers: [container]))
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
      XcodeScheme.buildTargets(scheme: "MyApp", searchContainers: [container])?.map(\.blueprintName),
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
      XcodeScheme.buildTargets(scheme: "MyApp", searchContainers: [container])?.map(\.blueprintName),
      ["UserTarget"]
    )
  }

  func testBuildTargetsReturnsNilWhenMissing() throws {
    let root = try makeTempDir()
    let container = root.appendingPathComponent("MyApp.xcodeproj", isDirectory: true)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    XCTAssertNil(XcodeScheme.buildTargets(scheme: "Nope", searchContainers: [container]))
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
    let result = try XCTUnwrap(XcodeScheme.buildTargets(scheme: "App", searchContainers: [workspace]))
    XCTAssertEqual(result.first?.blueprintName, "App")
    XCTAssertEqual(
      result.first?.container?.standardizedFileURL.path,
      root.appendingPathComponent("AppA/AppA.xcodeproj").standardizedFileURL.path
    )
  }

  func testBuildTargetsSearchesAllGivenContainers() throws {
    // buildTargets searches every container it is handed (the caller now decides the set), finding a scheme
    // that lives only in a non-first container and resolving its container relative to where it was found.
    let root = try makeTempDir()
    let opened = root.appendingPathComponent("MyApp.xcodeproj", isDirectory: true)
    try FileManager.default.createDirectory(at: opened, withIntermediateDirectories: true)
    let member = root.appendingPathComponent("Member.xcodeproj", isDirectory: true)
    try writeSchemeWithContainer(
      "MyApp",
      into: member.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true),
      blueprintName: "MemberTarget",
      container: "Member.xcodeproj"
    )
    let result = try XCTUnwrap(
      XcodeScheme.buildTargets(scheme: "MyApp", searchContainers: [opened, member])
    )
    XCTAssertEqual(result.first?.blueprintName, "MemberTarget")
    XCTAssertEqual(
      result.first?.container?.standardizedFileURL.path,
      root.appendingPathComponent("Member.xcodeproj").standardizedFileURL.path
    )
  }

  func testBuildTargetsResolvesCrossProjectContainerFromProjectScheme() throws {
    // A scheme that lives in the opened MyApp.xcodeproj references a target in a project-referenced
    // Framework/Framework.xcodeproj. The container resolves relative to the scheme-owning project's dir.
    let root = try makeTempDir()
    let opened = root.appendingPathComponent("MyApp.xcodeproj", isDirectory: true)
    try writeSchemeWithContainer(
      "Cross",
      into: opened.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true),
      blueprintName: "Framework",
      container: "Framework/Framework.xcodeproj"
    )
    let result = try XCTUnwrap(XcodeScheme.buildTargets(scheme: "Cross", searchContainers: [opened]))
    XCTAssertEqual(result.first?.blueprintName, "Framework")
    XCTAssertEqual(
      result.first?.container?.standardizedFileURL.path,
      root.appendingPathComponent("Framework/Framework.xcodeproj").standardizedFileURL.path
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
