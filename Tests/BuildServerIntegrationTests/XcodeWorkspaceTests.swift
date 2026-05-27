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

final class XcodeWorkspaceTests: XCTestCase {
  #if !NO_SWIFTPM_DEPENDENCY

  // MARK: - resolveLocation

  func testResolveLocationGroupRelativeToCurrentBase() {
    let base = URL(fileURLWithPath: "/root/Modules", isDirectory: true)
    let ws = URL(fileURLWithPath: "/root", isDirectory: true)
    XCTAssertEqual(
      XcodeWorkspace.resolveLocation("group:App/App.xcodeproj", currentBase: base, workspaceDir: ws)?.path,
      "/root/Modules/App/App.xcodeproj"
    )
  }

  func testResolveLocationContainerRelativeToWorkspaceDir() {
    // container: ignores the current group base; it is always relative to the workspace directory.
    let base = URL(fileURLWithPath: "/root/Modules", isDirectory: true)
    let ws = URL(fileURLWithPath: "/root", isDirectory: true)
    XCTAssertEqual(
      XcodeWorkspace.resolveLocation("container:Top.xcodeproj", currentBase: base, workspaceDir: ws)?.path,
      "/root/Top.xcodeproj"
    )
  }

  func testResolveLocationAbsolute() {
    let ws = URL(fileURLWithPath: "/root", isDirectory: true)
    XCTAssertEqual(
      XcodeWorkspace.resolveLocation("absolute:/elsewhere/Lib.xcodeproj", currentBase: ws, workspaceDir: ws)?.path,
      "/elsewhere/Lib.xcodeproj"
    )
  }

  func testResolveLocationSelfReturnsCurrentBase() {
    let base = URL(fileURLWithPath: "/root/Modules", isDirectory: true)
    let ws = URL(fileURLWithPath: "/root", isDirectory: true)
    XCTAssertEqual(
      XcodeWorkspace.resolveLocation("self:", currentBase: base, workspaceDir: ws)?.path,
      "/root/Modules"
    )
  }

  func testResolveLocationResolvesDotDot() {
    let base = URL(fileURLWithPath: "/root/Modules", isDirectory: true)
    let ws = URL(fileURLWithPath: "/root", isDirectory: true)
    XCTAssertEqual(
      XcodeWorkspace.resolveLocation("group:../Shared/Lib.xcodeproj", currentBase: base, workspaceDir: ws)?.path,
      "/root/Shared/Lib.xcodeproj"
    )
  }

  func testResolveLocationEmptyPaths() {
    let base = URL(fileURLWithPath: "/root/Modules", isDirectory: true)
    let ws = URL(fileURLWithPath: "/root", isDirectory: true)
    // group:/container: with an empty path resolve to the base directory itself.
    XCTAssertEqual(XcodeWorkspace.resolveLocation("group:", currentBase: base, workspaceDir: ws)?.path, "/root/Modules")
    XCTAssertEqual(XcodeWorkspace.resolveLocation("container:", currentBase: base, workspaceDir: ws)?.path, "/root")
    // absolute: with an empty path is meaningless -> nil (consistent with group/container).
    XCTAssertNil(XcodeWorkspace.resolveLocation("absolute:", currentBase: base, workspaceDir: ws))
  }

  func testResolveLocationUnknownKindOrNoColonReturnsNil() {
    let ws = URL(fileURLWithPath: "/root", isDirectory: true)
    XCTAssertNil(XcodeWorkspace.resolveLocation("developer:usr/bin", currentBase: ws, workspaceDir: ws))
    XCTAssertNil(XcodeWorkspace.resolveLocation("noColonHere", currentBase: ws, workspaceDir: ws))
  }

  // MARK: - projectReferences

  private func data(_ xml: String) -> Data { Data(xml.utf8) }

  func testProjectReferencesFlatFileRefs() {
    let base = URL(fileURLWithPath: "/root", isDirectory: true)
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <Workspace version = "1.0">
         <FileRef location = "group:AppA/AppA.xcodeproj"></FileRef>
         <FileRef location = "group:AppB/AppB.xcodeproj"></FileRef>
      </Workspace>
      """
    XCTAssertEqual(
      XcodeWorkspace.projectReferences(xcworkspacedataContents: data(xml), baseDir: base).map(\.path),
      ["/root/AppA/AppA.xcodeproj", "/root/AppB/AppB.xcodeproj"]
    )
  }

  func testProjectReferencesNestedGroupAccumulatesPrefix() {
    let base = URL(fileURLWithPath: "/root", isDirectory: true)
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <Workspace version = "1.0">
         <Group location = "group:Modules">
            <FileRef location = "group:MyLib/MyLib.xcodeproj"></FileRef>
         </Group>
      </Workspace>
      """
    XCTAssertEqual(
      XcodeWorkspace.projectReferences(xcworkspacedataContents: data(xml), baseDir: base).map(\.path),
      ["/root/Modules/MyLib/MyLib.xcodeproj"]
    )
  }

  func testProjectReferencesContainerIgnoresGroupPrefix() {
    let base = URL(fileURLWithPath: "/root", isDirectory: true)
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <Workspace version = "1.0">
         <Group location = "group:Modules">
            <FileRef location = "container:Top.xcodeproj"></FileRef>
         </Group>
      </Workspace>
      """
    XCTAssertEqual(
      XcodeWorkspace.projectReferences(xcworkspacedataContents: data(xml), baseDir: base).map(\.path),
      ["/root/Top.xcodeproj"]
    )
  }

  func testProjectReferencesIgnoresNonXcodeprojAndSelf() {
    let base = URL(fileURLWithPath: "/root", isDirectory: true)
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <Workspace version = "1.0">
         <FileRef location = "self:"></FileRef>
         <FileRef location = "group:Package.swift"></FileRef>
         <FileRef location = "group:App/App.xcodeproj"></FileRef>
      </Workspace>
      """
    XCTAssertEqual(
      XcodeWorkspace.projectReferences(xcworkspacedataContents: data(xml), baseDir: base).map(\.path),
      ["/root/App/App.xcodeproj"]
    )
  }

  func testProjectReferencesDeduplicates() {
    let base = URL(fileURLWithPath: "/root", isDirectory: true)
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <Workspace version = "1.0">
         <FileRef location = "group:App/App.xcodeproj"></FileRef>
         <FileRef location = "group:App/App.xcodeproj"></FileRef>
      </Workspace>
      """
    XCTAssertEqual(
      XcodeWorkspace.projectReferences(xcworkspacedataContents: data(xml), baseDir: base).map(\.path),
      ["/root/App/App.xcodeproj"]
    )
  }

  func testProjectReferencesEmptyForGarbage() {
    let base = URL(fileURLWithPath: "/root", isDirectory: true)
    XCTAssertEqual(XcodeWorkspace.projectReferences(xcworkspacedataContents: data("not xml <<<"), baseDir: base), [])
    XCTAssertEqual(XcodeWorkspace.projectReferences(xcworkspacedataContents: Data(), baseDir: base), [])
  }

  // MARK: - memberProjects

  private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcworkspace-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }

  func testMemberProjectsReadsWorkspacedata() throws {
    let dir = try makeTempDir()
    let workspace = dir.appendingPathComponent("MyWorkspace.xcworkspace", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <Workspace version = "1.0">
         <Group location = "group:Modules">
            <FileRef location = "group:MyLib/MyLib.xcodeproj"></FileRef>
         </Group>
         <FileRef location = "group:MyApp.xcodeproj"></FileRef>
      </Workspace>
      """
    try (xml + "\n").write(
      to: workspace.appendingPathComponent("contents.xcworkspacedata", isDirectory: false),
      atomically: true,
      encoding: .utf8
    )
    let members = try XCTUnwrap(XcodeWorkspace.memberProjects(workspaceURL: workspace)).map(\.path)
    XCTAssertEqual(
      Set(members),
      Set([
        dir.appendingPathComponent("Modules/MyLib/MyLib.xcodeproj").standardizedFileURL.path,
        dir.appendingPathComponent("MyApp.xcodeproj").standardizedFileURL.path,
      ])
    )
  }

  func testMemberProjectsNilWhenFileMissing() throws {
    let dir = try makeTempDir()
    let workspace = dir.appendingPathComponent("Empty.xcworkspace", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    XCTAssertNil(XcodeWorkspace.memberProjects(workspaceURL: workspace))
  }

  func testMemberProjectsEmptyArrayWhenFileExistsButGarbage() throws {
    // A present-but-unparseable contents.xcworkspacedata yields [] (not nil): the file exists, so callers
    // should not fall back to a top-level scan.
    let dir = try makeTempDir()
    let workspace = dir.appendingPathComponent("Garbage.xcworkspace", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try "not xml <<<".write(
      to: workspace.appendingPathComponent("contents.xcworkspacedata", isDirectory: false),
      atomically: true,
      encoding: .utf8
    )
    XCTAssertEqual(XcodeWorkspace.memberProjects(workspaceURL: workspace), [])
  }
  #endif
}
