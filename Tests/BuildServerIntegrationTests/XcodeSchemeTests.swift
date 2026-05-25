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

  private func entry(blueprintName: String) -> String {
    """
          <BuildActionEntry buildForRunning="YES">
             <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="\(blueprintName)" BuildableName="\(blueprintName)" BlueprintName="\(blueprintName)" ReferencedContainer="container:MyApp.xcodeproj"></BuildableReference>
          </BuildActionEntry>
    """
  }

  func testParsesMultipleBuildActionTargetNames() {
    let data = scheme(buildEntries: entry(blueprintName: "App") + "\n" + entry(blueprintName: "Framework"))
    XCTAssertEqual(XcodeScheme.buildActionTargetNames(xcschemeContents: data), ["App", "Framework"])
  }

  func testEmptyBuildActionReturnsEmpty() {
    let data = scheme(buildEntries: "")
    XCTAssertEqual(XcodeScheme.buildActionTargetNames(xcschemeContents: data), [])
  }

  func testDeduplicatesNames() {
    let data = scheme(buildEntries: entry(blueprintName: "App") + "\n" + entry(blueprintName: "App"))
    XCTAssertEqual(XcodeScheme.buildActionTargetNames(xcschemeContents: data), ["App"])
  }

  func testIgnoresBuildableReferencesOutsideBuildAction() {
    // A TestAction BuildableReference must NOT be picked up.
    let testAction = """
         <TestAction buildConfiguration="Debug">
            <Testables>
               <TestableReference skipped="NO">
                  <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="Tests" BuildableName="Tests" BlueprintName="Tests" ReferencedContainer="container:MyApp.xcodeproj"></BuildableReference>
               </TestableReference>
            </Testables>
         </TestAction>
      """
    let data = scheme(buildEntries: entry(blueprintName: "App"), extraActions: testAction)
    XCTAssertEqual(XcodeScheme.buildActionTargetNames(xcschemeContents: data), ["App"])
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

  func testTargetNamesFindsSharedScheme() throws {
    let root = try makeTempDir()
    let container = root.appendingPathComponent("MyApp.xcodeproj", isDirectory: true)
    try writeScheme(
      "MyApp",
      into: container.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true),
      blueprintName: "MyApp"
    )
    XCTAssertEqual(
      XcodeScheme.targetNames(scheme: "MyApp", containerPath: container, projectRoot: root),
      ["MyApp"]
    )
  }

  func testTargetNamesPrefersSharedOverUser() throws {
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
      XcodeScheme.targetNames(scheme: "MyApp", containerPath: container, projectRoot: root),
      ["SharedTarget"]
    )
  }

  func testTargetNamesFindsUserSchemeWhenNoShared() throws {
    let root = try makeTempDir()
    let container = root.appendingPathComponent("MyApp.xcodeproj", isDirectory: true)
    try writeScheme(
      "MyApp",
      into: container.appendingPathComponent("xcuserdata/me.xcuserdatad/xcschemes", isDirectory: true),
      blueprintName: "UserTarget"
    )
    XCTAssertEqual(
      XcodeScheme.targetNames(scheme: "MyApp", containerPath: container, projectRoot: root),
      ["UserTarget"]
    )
  }

  func testTargetNamesReturnsNilWhenMissing() throws {
    let root = try makeTempDir()
    let container = root.appendingPathComponent("MyApp.xcodeproj", isDirectory: true)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    XCTAssertNil(XcodeScheme.targetNames(scheme: "Nope", containerPath: container, projectRoot: root))
  }

  func testTargetNamesSearchesWorkspaceMemberProjects() throws {
    let root = try makeTempDir()
    let workspace = root.appendingPathComponent("MyApp.xcworkspace", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    // Scheme lives in a member .xcodeproj, not the workspace itself.
    let memberProject = root.appendingPathComponent("Member.xcodeproj", isDirectory: true)
    try writeScheme(
      "MyApp",
      into: memberProject.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true),
      blueprintName: "MemberTarget"
    )
    XCTAssertEqual(
      XcodeScheme.targetNames(scheme: "MyApp", containerPath: workspace, projectRoot: root),
      ["MemberTarget"]
    )
  }
  #endif
}
