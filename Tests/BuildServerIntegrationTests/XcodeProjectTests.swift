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

final class XcodeProjectTests: XCTestCase {
  #if !NO_SWIFTPM_DEPENDENCY

  /// Serialize a pbxproj-shaped object graph as an XML plist. `PropertyListSerialization` parses by
  /// format auto-detection, so this exercises the same code path as a real OpenStep `project.pbxproj`
  /// while staying portable across platforms (OpenStep read support is not guaranteed off macOS).
  private func pbxprojData(objects: [String: Any], rootObject: String) -> Data {
    let plist: [String: Any] = [
      "archiveVersion": "1",
      "objectVersion": "56",
      "objects": objects,
      "rootObject": rootObject,
    ]
    return try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
  }

  func testResolvesGroupRelativeReferenceInMainGroup() {
    let data = pbxprojData(
      objects: [
        "PROJ": [
          "isa": "PBXProject",
          "mainGroup": "G_MAIN",
          "projectReferences": [["ProductGroup": "G_PROD", "ProjectRef": "FREF"]],
        ],
        "G_MAIN": ["isa": "PBXGroup", "children": ["FREF"], "sourceTree": "<group>"],
        "FREF": [
          "isa": "PBXFileReference",
          "path": "Framework/Framework.xcodeproj",
          "sourceTree": "<group>",
        ],
      ],
      rootObject: "PROJ"
    )
    let resolved = XcodeProject.projectReferences(
      pbxprojContents: data,
      projectDir: URL(fileURLWithPath: "/root", isDirectory: true)
    )
    XCTAssertEqual(resolved.map(\.path), ["/root/Framework/Framework.xcodeproj"])
  }

  func testResolvesSourceRootReference() {
    let data = pbxprojData(
      objects: [
        "PROJ": [
          "isa": "PBXProject",
          "mainGroup": "G_MAIN",
          "projectReferences": [["ProductGroup": "G_PROD", "ProjectRef": "FREF"]],
        ],
        "G_MAIN": ["isa": "PBXGroup", "children": ["FREF"], "sourceTree": "<group>"],
        "FREF": [
          "isa": "PBXFileReference",
          "path": "Framework/Framework.xcodeproj",
          "sourceTree": "SOURCE_ROOT",
        ],
      ],
      rootObject: "PROJ"
    )
    let resolved = XcodeProject.projectReferences(
      pbxprojContents: data,
      projectDir: URL(fileURLWithPath: "/root", isDirectory: true)
    )
    XCTAssertEqual(resolved.map(\.path), ["/root/Framework/Framework.xcodeproj"])
  }
  #endif
}
