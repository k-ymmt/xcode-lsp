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
  #endif
}
