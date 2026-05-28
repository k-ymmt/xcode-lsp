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

#if !NO_SWIFTPM_DEPENDENCY
package import Foundation

/// Parses an Xcode `.xcodeproj`'s `project.pbxproj` to enumerate the other `.xcodeproj`s it references
/// via `PBXProject.projectReferences`. SwiftBuild does not expose which projects are project-referenced
/// (vs. SwiftPM packages), so the build server reads it from disk itself. This type has no
/// `import SwiftBuild` dependency.
package enum XcodeProject {
  /// The other `.xcodeproj`s referenced by `projectURL`'s `PBXProject.projectReferences`, fully resolved.
  /// Reads `<projectURL>/project.pbxproj`; returns `[]` if it is absent or unreadable.
  package static func referencedProjects(ofProjectAt projectURL: URL) -> [URL] {
    let pbxprojURL = projectURL.appendingPathComponent("project.pbxproj", isDirectory: false)
    guard let data = try? Data(contentsOf: pbxprojURL) else {
      return []
    }
    return projectReferences(pbxprojContents: data, projectDir: projectURL.deletingLastPathComponent())
  }

  /// Parse a `project.pbxproj` and return the `.xcodeproj`s referenced via `PBXProject.projectReferences`,
  /// each resolved to an absolute URL relative to `projectDir` (the directory containing the `.xcodeproj`).
  /// De-duplicated by resolved path, preserving order. Returns `[]` for malformed data or no references.
  ///
  /// `PropertyListSerialization` reads OpenStep, XML, and binary plists by auto-detecting the format, so
  /// real (OpenStep) `project.pbxproj` files parse here on platforms whose Foundation supports it (macOS).
  package static func projectReferences(pbxprojContents: Data, projectDir: URL) -> [URL] {
    guard
      let plist = try? PropertyListSerialization.propertyList(from: pbxprojContents, options: [], format: nil),
      let root = plist as? [String: Any],
      let objects = root["objects"] as? [String: Any],
      let rootObjectID = root["rootObject"] as? String,
      let project = objects[rootObjectID] as? [String: Any],
      let references = project["projectReferences"] as? [[String: Any]]
    else {
      return []
    }
    var resolved: [URL] = []
    var seen = Set<String>()
    for reference in references {
      guard
        let projectRefID = reference["ProjectRef"] as? String,
        let url = resolvePath(objectID: projectRefID, objects: objects, projectDir: projectDir),
        url.pathExtension == "xcodeproj",
        seen.insert(url.path).inserted
      else {
        continue
      }
      resolved.append(url)
    }
    return resolved
  }

  /// Resolve a PBXFileReference/PBXGroup object's on-disk URL by combining its `path` with the base
  /// directory implied by its `sourceTree` and enclosing groups. Returns `nil` for source trees that do
  /// not denote an on-disk source location (`BUILT_PRODUCTS_DIR`, `DEVELOPER_DIR`, `SDKROOT`, etc.).
  /// `visited` guards against pathological group cycles in malformed input.
  private static func resolvePath(
    objectID: String,
    objects: [String: Any],
    projectDir: URL,
    visited: Set<String> = []
  ) -> URL? {
    guard !visited.contains(objectID), let object = objects[objectID] as? [String: Any] else {
      return nil
    }
    let path = object["path"] as? String
    let base: URL
    switch object["sourceTree"] as? String {
    case "<absolute>":
      guard let path, !path.isEmpty else { return nil }
      return URL(fileURLWithPath: path).standardizedFileURL
    case "SOURCE_ROOT":
      base = projectDir
    case "<group>":
      base = parentGroupBase(
        ofObjectID: objectID,
        objects: objects,
        projectDir: projectDir,
        visited: visited.union([objectID])
      )
    default:
      // BUILT_PRODUCTS_DIR / DEVELOPER_DIR / SDKROOT / unknown: not an on-disk source project reference.
      return nil
    }
    guard let path, !path.isEmpty else {
      return base.standardizedFileURL
    }
    return URL(fileURLWithPath: (base.path as NSString).appendingPathComponent(path)).standardizedFileURL
  }

  /// The resolved base directory for a `<group>`-relative object: the resolved path of the PBXGroup that
  /// lists it as a child, or `projectDir` if no group does (e.g. it sits in the main group, which itself
  /// resolves to `projectDir`).
  private static func parentGroupBase(
    ofObjectID objectID: String,
    objects: [String: Any],
    projectDir: URL,
    visited: Set<String>
  ) -> URL {
    for (groupID, value) in objects {
      guard
        let group = value as? [String: Any],
        let isa = group["isa"] as? String,
        isa == "PBXGroup" || isa == "PBXVariantGroup",
        let children = group["children"] as? [String],
        children.contains(objectID)
      else {
        continue
      }
      return resolvePath(objectID: groupID, objects: objects, projectDir: projectDir, visited: visited)
        ?? projectDir
    }
    return projectDir
  }
}
#endif
