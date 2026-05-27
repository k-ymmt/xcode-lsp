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

/// Locates and parses Xcode `.xcscheme` files. SwiftBuild does not expose scheme discovery, so the
/// build server reads schemes from disk itself. This type has no `import SwiftBuild` dependency.
package enum XcodeScheme {
  /// Locate the `.xcscheme` named `scheme` and return its `BuildAction` target names.
  ///
  /// Search order: shared schemes (`xcshareddata/xcschemes`) before user schemes
  /// (`xcuserdata/*.xcuserdatad/xcschemes`). For a `.xcworkspace` container, member `.xcodeproj`s
  /// under `projectRoot` are searched too. Returns `nil` if no matching file exists (the caller
  /// then decides how to fall back).
  package static func targetNames(scheme: String, containerPath: URL, projectRoot: URL) -> [String]? {
    guard let url = schemeFileURL(scheme: scheme, containerPath: containerPath, projectRoot: projectRoot),
      let data = try? Data(contentsOf: url)
    else {
      return nil
    }
    return buildActionTargetNames(xcschemeContents: data)
  }

  /// Containers to search for scheme files: the container itself, plus (for a workspace) member
  /// `.xcodeproj`s directly under `projectRoot`.
  private static func searchContainers(containerPath: URL, projectRoot: URL) -> [URL] {
    var containers = [containerPath]
    if containerPath.pathExtension == "xcworkspace",
      let entries = try? FileManager.default.contentsOfDirectory(at: projectRoot, includingPropertiesForKeys: nil)
    {
      containers.append(contentsOf: entries.filter { $0.pathExtension == "xcodeproj" }.sorted { $0.path < $1.path })
    }
    return containers
  }

  private static func schemeFileURL(scheme: String, containerPath: URL, projectRoot: URL) -> URL? {
    let fm = FileManager.default
    let containers = searchContainers(containerPath: containerPath, projectRoot: projectRoot)

    // Shared schemes first, across all candidate containers.
    for container in containers {
      let shared = container.appendingPathComponent("xcshareddata/xcschemes/\(scheme).xcscheme", isDirectory: false)
      if fm.fileExists(atPath: shared.path) {
        return shared
      }
    }
    // Then user schemes: xcuserdata/<anything>.xcuserdatad/xcschemes/<name>.xcscheme
    for container in containers {
      let userdata = container.appendingPathComponent("xcuserdata", isDirectory: true)
      guard let userDirs = try? fm.contentsOfDirectory(at: userdata, includingPropertiesForKeys: nil) else {
        continue
      }
      for dir in userDirs where dir.pathExtension == "xcuserdatad" {
        let candidate = dir.appendingPathComponent("xcschemes/\(scheme).xcscheme", isDirectory: false)
        if fm.fileExists(atPath: candidate.path) {
          return candidate
        }
      }
    }
    return nil
  }

  /// Extract the target names (`BlueprintName`) referenced by a scheme's `BuildAction`.
  ///
  /// Only `BuildableReference`s nested inside `<BuildAction>` are considered; references in
  /// `TestAction`/`LaunchAction`/etc. are ignored. Returned names are de-duplicated, preserving order.
  package static func buildActionTargetNames(xcschemeContents: Data) -> [String] {
    let parser = XMLParser(data: xcschemeContents)
    let delegate = BuildActionDelegate()
    parser.delegate = delegate
    parser.parse()
    var seen = Set<String>()
    return delegate.names.filter { seen.insert($0).inserted }
  }

  /// Resolve a scheme `BuildableReference`'s `ReferencedContainer` (e.g. `container:AppA/AppA.xcodeproj`)
  /// to an absolute `.xcodeproj` URL, relative to `baseDir` (the directory holding the container that owns
  /// the scheme file). Returns `nil` when the attribute is absent, not `container:`-prefixed, or empty —
  /// callers then fall back to matching by target name alone.
  ///
  /// Uses `standardizedFileURL` (resolves `.`/`..` but not symlinks) so the result stays comparable to the
  /// caller-supplied `baseDir`; symlink canonicalization happens later in `XcodeBuildServer.resolveScheme`.
  package static func resolveContainer(_ referencedContainer: String?, relativeTo baseDir: URL) -> URL? {
    guard let raw = referencedContainer, raw.hasPrefix("container:") else {
      return nil
    }
    let relativePath = String(raw.dropFirst("container:".count))
    guard !relativePath.isEmpty else {
      return nil
    }
    return URL(fileURLWithPath: relativePath, relativeTo: baseDir).standardizedFileURL
  }
}

private final class BuildActionDelegate: NSObject, XMLParserDelegate {
  var names: [String] = []
  private var inBuildAction = false

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String]
  ) {
    switch elementName {
    case "BuildAction":
      inBuildAction = true
    case "BuildableReference":
      if inBuildAction, let name = attributeDict["BlueprintName"] {
        names.append(name)
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
    if elementName == "BuildAction" {
      inBuildAction = false
    }
  }
}
#endif
