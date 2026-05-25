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
