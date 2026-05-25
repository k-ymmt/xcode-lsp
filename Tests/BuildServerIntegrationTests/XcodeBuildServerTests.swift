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
@_spi(SourceKitLSP) import BuildServerProtocol
import Foundation
@_spi(SourceKitLSP) import LanguageServerProtocol
import SKOptions
import XCTest

final class XcodeBuildServerTests: XCTestCase {
  func testXcodeTargetIdentifierRoundTrip() throws {
    let id = try BuildTargetIdentifier.createXcode(targetGUID: "T1::TARGET@v1")
    XCTAssertEqual(try id.xcodeTargetGUID, "T1::TARGET@v1")
  }

  #if !NO_SWIFTPM_DEPENDENCY
  func testDetectsXcodeproj() throws {
    let dir = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: dir.appendingPathComponent("MyApp.xcodeproj"),
      withIntermediateDirectories: true
    )
    let spec = XcodeBuildServer.searchForConfig(in: dir, options: SourceKitLSPOptions())
    XCTAssertEqual(spec?.configPath.lastPathComponent, "MyApp.xcodeproj")
  }

  func testPrefersXcworkspaceOverXcodeproj() throws {
    let dir = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: dir.appendingPathComponent("MyApp.xcodeproj"),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: dir.appendingPathComponent("MyApp.xcworkspace"),
      withIntermediateDirectories: true
    )
    let spec = XcodeBuildServer.searchForConfig(in: dir, options: SourceKitLSPOptions())
    XCTAssertEqual(spec?.configPath.pathExtension, "xcworkspace")
  }

  func testNoXcodeContainerReturnsNil() throws {
    let dir = try temporaryDirectory()
    XCTAssertNil(XcodeBuildServer.searchForConfig(in: dir, options: SourceKitLSPOptions()))
  }

  private func temporaryDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcode-bs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }
  #endif
}
