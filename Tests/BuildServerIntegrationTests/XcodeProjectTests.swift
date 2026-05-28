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

  // MARK: - projectReferences

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

  func testResolvesAbsoluteReference() {
    let data = pbxprojData(
      objects: [
        "PROJ": [
          "isa": "PBXProject", "mainGroup": "G_MAIN",
          "projectReferences": [["ProductGroup": "G_PROD", "ProjectRef": "FREF"]],
        ],
        "G_MAIN": ["isa": "PBXGroup", "children": ["FREF"], "sourceTree": "<group>"],
        "FREF": ["isa": "PBXFileReference", "path": "/elsewhere/Lib.xcodeproj", "sourceTree": "<absolute>"],
      ],
      rootObject: "PROJ"
    )
    let resolved = XcodeProject.projectReferences(
      pbxprojContents: data,
      projectDir: URL(fileURLWithPath: "/root", isDirectory: true)
    )
    XCTAssertEqual(resolved.map(\.path), ["/elsewhere/Lib.xcodeproj"])
  }

  func testAccumulatesNestedGroupPaths() {
    // FREF lives in G_SUB ("Sub"), itself a child of the main group → /root/Sub/Lib.xcodeproj.
    let data = pbxprojData(
      objects: [
        "PROJ": [
          "isa": "PBXProject", "mainGroup": "G_MAIN",
          "projectReferences": [["ProductGroup": "G_PROD", "ProjectRef": "FREF"]],
        ],
        "G_MAIN": ["isa": "PBXGroup", "children": ["G_SUB"], "sourceTree": "<group>"],
        "G_SUB": ["isa": "PBXGroup", "children": ["FREF"], "path": "Sub", "sourceTree": "<group>"],
        "FREF": ["isa": "PBXFileReference", "path": "Lib.xcodeproj", "sourceTree": "<group>"],
      ],
      rootObject: "PROJ"
    )
    let resolved = XcodeProject.projectReferences(
      pbxprojContents: data,
      projectDir: URL(fileURLWithPath: "/root", isDirectory: true)
    )
    XCTAssertEqual(resolved.map(\.path), ["/root/Sub/Lib.xcodeproj"])
  }

  func testReturnsMultipleReferencesDeduplicated() {
    let data = pbxprojData(
      objects: [
        "PROJ": [
          "isa": "PBXProject", "mainGroup": "G_MAIN",
          "projectReferences": [
            ["ProductGroup": "G1", "ProjectRef": "FREF_A"],
            ["ProductGroup": "G2", "ProjectRef": "FREF_B"],
            ["ProductGroup": "G3", "ProjectRef": "FREF_A_DUP"],
          ],
        ],
        "G_MAIN": ["isa": "PBXGroup", "children": ["FREF_A", "FREF_B", "FREF_A_DUP"], "sourceTree": "<group>"],
        "FREF_A": ["isa": "PBXFileReference", "path": "A/A.xcodeproj", "sourceTree": "<group>"],
        "FREF_B": ["isa": "PBXFileReference", "path": "B/B.xcodeproj", "sourceTree": "<group>"],
        "FREF_A_DUP": ["isa": "PBXFileReference", "path": "A/A.xcodeproj", "sourceTree": "<group>"],
      ],
      rootObject: "PROJ"
    )
    let resolved = XcodeProject.projectReferences(
      pbxprojContents: data,
      projectDir: URL(fileURLWithPath: "/root", isDirectory: true)
    )
    XCTAssertEqual(resolved.map(\.path), ["/root/A/A.xcodeproj", "/root/B/B.xcodeproj"])
  }

  func testSkipsNonXcodeprojReferences() {
    let data = pbxprojData(
      objects: [
        "PROJ": [
          "isa": "PBXProject", "mainGroup": "G_MAIN",
          "projectReferences": [["ProductGroup": "G", "ProjectRef": "FREF"]],
        ],
        "G_MAIN": ["isa": "PBXGroup", "children": ["FREF"], "sourceTree": "<group>"],
        "FREF": ["isa": "PBXFileReference", "path": "notes.txt", "sourceTree": "<group>"],
      ],
      rootObject: "PROJ"
    )
    XCTAssertEqual(
      XcodeProject.projectReferences(pbxprojContents: data, projectDir: URL(fileURLWithPath: "/root")),
      []
    )
  }

  func testSkipsNonDiskSourceTrees() {
    let data = pbxprojData(
      objects: [
        "PROJ": [
          "isa": "PBXProject", "mainGroup": "G_MAIN",
          "projectReferences": [["ProductGroup": "G", "ProjectRef": "FREF"]],
        ],
        "G_MAIN": ["isa": "PBXGroup", "children": ["FREF"], "sourceTree": "<group>"],
        "FREF": ["isa": "PBXFileReference", "path": "Built.xcodeproj", "sourceTree": "BUILT_PRODUCTS_DIR"],
      ],
      rootObject: "PROJ"
    )
    XCTAssertEqual(
      XcodeProject.projectReferences(pbxprojContents: data, projectDir: URL(fileURLWithPath: "/root")),
      []
    )
  }

  func testReturnsEmptyWhenNoProjectReferences() {
    let data = pbxprojData(
      objects: [
        "PROJ": ["isa": "PBXProject", "mainGroup": "G_MAIN"],
        "G_MAIN": ["isa": "PBXGroup", "children": [], "sourceTree": "<group>"],
      ],
      rootObject: "PROJ"
    )
    XCTAssertEqual(
      XcodeProject.projectReferences(pbxprojContents: data, projectDir: URL(fileURLWithPath: "/root")),
      []
    )
  }

  func testReturnsEmptyForMalformedData() {
    let data = Data("this is not a plist".utf8)
    XCTAssertEqual(
      XcodeProject.projectReferences(pbxprojContents: data, projectDir: URL(fileURLWithPath: "/root")),
      []
    )
  }

  // MARK: - referencedProjects

  func testReferencedProjectsReadsFromDisk() throws {
    let tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("XcodeProjectTests-\(UUID().uuidString)", isDirectory: true)
    let appXcodeproj = tmp.appendingPathComponent("MyApp.xcodeproj", isDirectory: true)
    try FileManager.default.createDirectory(at: appXcodeproj, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let data = pbxprojData(
      objects: [
        "PROJ": [
          "isa": "PBXProject", "mainGroup": "G_MAIN",
          "projectReferences": [["ProductGroup": "G", "ProjectRef": "FREF"]],
        ],
        "G_MAIN": ["isa": "PBXGroup", "children": ["FREF"], "sourceTree": "<group>"],
        "FREF": ["isa": "PBXFileReference", "path": "Framework/Framework.xcodeproj", "sourceTree": "<group>"],
      ],
      rootObject: "PROJ"
    )
    try data.write(to: appXcodeproj.appendingPathComponent("project.pbxproj", isDirectory: false))

    let resolved = XcodeProject.referencedProjects(ofProjectAt: appXcodeproj)
    XCTAssertEqual(
      resolved.map { $0.standardizedFileURL.path },
      [tmp.appendingPathComponent("Framework/Framework.xcodeproj").standardizedFileURL.path]
    )
  }

  func testReferencedProjectsReturnsEmptyWhenPbxprojAbsent() {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("does-not-exist-\(UUID().uuidString).xcodeproj", isDirectory: true)
    XCTAssertEqual(XcodeProject.referencedProjects(ofProjectAt: missing), [])
  }
  #endif
}
