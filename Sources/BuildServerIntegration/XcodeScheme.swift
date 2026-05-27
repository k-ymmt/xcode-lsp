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
  /// One `BuildableReference` parsed from a scheme's `BuildAction`, `TestAction`, or `LaunchAction`,
  /// before container path resolution.
  package struct SchemeBuildableReference: Hashable, Sendable {
    /// The `BlueprintName` attribute (the target name).
    package var blueprintName: String
    /// The raw `ReferencedContainer` attribute (e.g. `container:AppA/AppA.xcodeproj`), or `nil` if absent.
    package var referencedContainer: String?

    package init(blueprintName: String, referencedContainer: String?) {
      self.blueprintName = blueprintName
      self.referencedContainer = referencedContainer
    }
  }

  /// A scheme Build-action target with its `ReferencedContainer` resolved to an absolute `.xcodeproj` path.
  package struct SchemeBuildTarget: Equatable, Sendable {
    /// The target name (`BlueprintName`).
    package var blueprintName: String
    /// The owning `.xcodeproj` absolute path, or `nil` when no resolvable container was present.
    package var container: URL?

    package init(blueprintName: String, container: URL?) {
      self.blueprintName = blueprintName
      self.container = container
    }
  }

  /// Locate the `.xcscheme` named `scheme` and return its `BuildAction` targets, with each
  /// `ReferencedContainer` resolved to an absolute `.xcodeproj` path (relative to the directory of the
  /// container the scheme file was found in). Returns `nil` if no matching file exists (the caller
  /// then decides how to fall back).
  ///
  /// Search order: shared schemes (`xcshareddata/xcschemes`) before user schemes
  /// (`xcuserdata/*.xcuserdatad/xcschemes`). For a `.xcworkspace` container, member `.xcodeproj`s
  /// under `projectRoot` are searched too.
  package static func buildTargets(scheme: String, containerPath: URL, projectRoot: URL) -> [SchemeBuildTarget]? {
    guard let (url, container) = schemeFileURL(scheme: scheme, containerPath: containerPath, projectRoot: projectRoot),
      let data = try? Data(contentsOf: url)
    else {
      return nil
    }
    let baseDir = container.deletingLastPathComponent()
    return schemeSeedReferences(xcschemeContents: data).map { reference in
      SchemeBuildTarget(
        blueprintName: reference.blueprintName,
        container: resolveContainer(reference.referencedContainer, relativeTo: baseDir)
      )
    }
  }

  /// Containers to search for scheme files: the container itself, plus (for a workspace) the member
  /// `.xcodeproj`s declared in its `contents.xcworkspacedata` (falling back to a top-level scan of
  /// `projectRoot` if that file is absent or unreadable).
  private static func searchContainers(containerPath: URL, projectRoot: URL) -> [URL] {
    var containers = [containerPath]
    if containerPath.pathExtension == "xcworkspace" {
      let members =
        XcodeWorkspace.memberProjects(workspaceURL: containerPath)
        ?? ((try? FileManager.default.contentsOfDirectory(at: projectRoot, includingPropertiesForKeys: nil))?
          .filter { $0.pathExtension == "xcodeproj" } ?? [])
      containers.append(contentsOf: members.sorted { $0.path < $1.path })
    }
    return containers
  }

  private static func schemeFileURL(
    scheme: String,
    containerPath: URL,
    projectRoot: URL
  ) -> (url: URL, container: URL)? {
    let fm = FileManager.default
    let containers = searchContainers(containerPath: containerPath, projectRoot: projectRoot)

    // Shared schemes first, across all candidate containers.
    for container in containers {
      let shared = container.appendingPathComponent("xcshareddata/xcschemes/\(scheme).xcscheme", isDirectory: false)
      if fm.fileExists(atPath: shared.path) {
        return (shared, container)
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
          return (candidate, container)
        }
      }
    }
    return nil
  }

  /// Extract every `BuildableReference` (name + `ReferencedContainer`) the scheme uses as a build seed:
  /// those nested under the scheme's `BuildAction`, `TestAction`, or `LaunchAction`. De-duplicated by
  /// (name, container) pair, preserving order.
  package static func schemeSeedReferences(xcschemeContents: Data) -> [SchemeBuildableReference] {
    let parser = XMLParser(data: xcschemeContents)
    let delegate = SchemeReferenceDelegate()
    parser.delegate = delegate
    parser.parse()
    var seen = Set<SchemeBuildableReference>()
    return delegate.references.filter { seen.insert($0).inserted }
  }

  /// Resolve a scheme `BuildableReference`'s `ReferencedContainer` (e.g. `container:AppA/AppA.xcodeproj`)
  /// to an absolute `.xcodeproj` URL, relative to `baseDir` (the directory holding the container that owns
  /// the scheme file). Returns `nil` when the attribute is absent, not `container:`-prefixed, or empty —
  /// callers may fall back to matching by target name alone.
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

private final class SchemeReferenceDelegate: NSObject, XMLParserDelegate {
  var references: [XcodeScheme.SchemeBuildableReference] = []
  /// How many currently-open ancestor elements are a build/test/launch action. A `BuildableReference`
  /// counts as a build seed when this is > 0. The three actions are siblings (never nested) in a scheme,
  /// so this is always 0 or 1 in practice; a counter (rather than a Bool) keeps the logic robust and
  /// ignores any `BuildableReference` outside these actions.
  private var seedActionDepth = 0

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String]
  ) {
    switch elementName {
    case "BuildAction", "TestAction", "LaunchAction":
      seedActionDepth += 1
    case "BuildableReference":
      if seedActionDepth > 0, let name = attributeDict["BlueprintName"] {
        references.append(
          XcodeScheme.SchemeBuildableReference(
            blueprintName: name,
            referencedContainer: attributeDict["ReferencedContainer"]
          )
        )
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
    switch elementName {
    case "BuildAction", "TestAction", "LaunchAction":
      seedActionDepth -= 1
    default:
      break
    }
  }
}
#endif
