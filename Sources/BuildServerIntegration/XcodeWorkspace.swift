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
}
#endif
