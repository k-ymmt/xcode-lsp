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

#if canImport(FoundationXML)
import FoundationXML
#endif

/// Parses an Xcode `.xcworkspace`'s `contents.xcworkspacedata` to enumerate its member `.xcodeproj`s.
/// SwiftBuild does not expose workspace membership, so the build server reads it from disk itself.
/// This type has no `import SwiftBuild` dependency.
package enum XcodeWorkspace {
  /// Resolve a workspace `location="<kind>:<path>"` attribute to an absolute URL.
  ///
  /// - `group:` … relative to `currentBase` (the nearest enclosing `<Group>`'s resolved directory, or the
  ///   workspace directory at the top level).
  /// - `container:` … relative to `workspaceDir`, regardless of group nesting.
  /// - `absolute:` … an absolute path.
  /// - `self:` … the `currentBase` itself (the workspace/group's own directory).
  /// - any other kind, or a string without a `:` … `nil`.
  ///
  /// Paths are joined as filesystem paths and `standardizedFileURL`-normalized (resolves `.`/`..`, not
  /// symlinks); symlink canonicalization happens later in `XcodeBuildServer.normalizedPath`.
  package static func resolveLocation(_ raw: String, currentBase: URL, workspaceDir: URL) -> URL? {
    guard let colon = raw.firstIndex(of: ":") else {
      return nil
    }
    let kind = String(raw[..<colon])
    let path = String(raw[raw.index(after: colon)...])
    let baseDir: String
    switch kind {
    case "group": baseDir = currentBase.path
    case "container": baseDir = workspaceDir.path
    case "absolute": return path.isEmpty ? nil : URL(fileURLWithPath: path).standardizedFileURL
    case "self": return currentBase.standardizedFileURL
    default: return nil
    }
    guard !path.isEmpty else {
      return URL(fileURLWithPath: baseDir).standardizedFileURL
    }
    return URL(fileURLWithPath: (baseDir as NSString).appendingPathComponent(path)).standardizedFileURL
  }

  /// Member `.xcodeproj`s declared in `workspaceURL`'s `contents.xcworkspacedata`, fully resolved. Returns
  /// `nil` when the file is absent or unreadable, so callers can fall back to a top-level directory scan.
  package static func memberProjects(workspaceURL: URL) -> [URL]? {
    let dataURL = workspaceURL.appendingPathComponent("contents.xcworkspacedata", isDirectory: false)
    guard let data = try? Data(contentsOf: dataURL) else {
      return nil
    }
    return projectReferences(xcworkspacedataContents: data, baseDir: workspaceURL.deletingLastPathComponent())
  }

  /// Parse `contents.xcworkspacedata` XML and return every member `.xcodeproj`, fully resolved relative to
  /// `baseDir` (the directory containing the `.xcworkspace`). Recurses into nested `<Group>`s, accumulating
  /// their location prefixes. De-duplicated by resolved path, preserving document order.
  package static func projectReferences(xcworkspacedataContents: Data, baseDir: URL) -> [URL] {
    let parser = XMLParser(data: xcworkspacedataContents)
    let delegate = WorkspaceDataDelegate(workspaceDir: baseDir)
    parser.delegate = delegate
    parser.parse()
    var seen = Set<String>()
    return delegate.projects.filter { seen.insert($0.path).inserted }
  }
}

private final class WorkspaceDataDelegate: NSObject, XMLParserDelegate {
  private let workspaceDir: URL
  /// Stack of resolved base directories: the workspace dir, then one entry per open `<Group>`.
  private var baseStack: [URL]
  var projects: [URL] = []

  init(workspaceDir: URL) {
    self.workspaceDir = workspaceDir
    self.baseStack = [workspaceDir]
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String]
  ) {
    let current = baseStack.last ?? workspaceDir
    switch elementName {
    case "Group":
      let resolved = attributeDict["location"].flatMap {
        XcodeWorkspace.resolveLocation($0, currentBase: current, workspaceDir: workspaceDir)
      }
      // A location-less or unresolvable Group does not change the base.
      baseStack.append(resolved ?? current)
    case "FileRef":
      if let location = attributeDict["location"],
        let resolved = XcodeWorkspace.resolveLocation(location, currentBase: current, workspaceDir: workspaceDir),
        resolved.pathExtension == "xcodeproj"
      {
        projects.append(resolved)
      }
    default:
      break
    }
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    if elementName == "Group", baseStack.count > 1 {
      baseStack.removeLast()
    }
  }
}
#endif
