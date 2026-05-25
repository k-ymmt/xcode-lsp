# Xcode scheme-support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `xcode.scheme` scope the `XcodeBuildServer` to a scheme's Build-action targets plus their dependency closure.

**Architecture:** Parse `.xcscheme` XML ourselves (SwiftBuild does not expose scheme discovery), match Build-action target names to `XcodeTarget.name`, expand via SwiftBuild's `computeDependencyClosure(includeImplicitDependencies: true)`, and filter at the single chokepoint `XcodeBuildServer.allTargets()`. Pure units (XML parse, file discovery, fallback decision) are TDD'd in all environments; real-SwiftBuild behavior is covered by macOS+Xcode integration tests.

**Tech Stack:** Swift, `Foundation.XMLParser` (+ `FoundationXML` on non-Darwin), SwiftBuild (`SWBBuildServiceSession.computeDependencyClosure`), XCTest.

**Spec:** `docs/superpowers/specs/2026-05-25-xcode-scheme-support-design.md`

**Conventions used throughout:**
- Build/test: `SWIFTCI_USE_LOCAL_DEPS=1 swift test --filter <...>`
- Lint: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift format lint --strict --recursive <files>`
- All new production code lives under `#if !NO_SWIFTPM_DEPENDENCY` to match `XcodeBuildServer.swift` / `SwiftBuildSession.swift`.
- `logger` is the module-global logger already used in `XcodeBuildServer.swift` (from `@_spi(SourceKitLSP) import SKLogging`).
- Commit message footer (per repo convention):
  ```
  Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
  ```

---

## Task 1: `XcodeScheme.buildActionTargetNames` — pure `.xcscheme` XML parsing

**Files:**
- Create: `Sources/BuildServerIntegration/XcodeScheme.swift`
- Test: `Tests/BuildServerIntegrationTests/XcodeSchemeTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/BuildServerIntegrationTests/XcodeSchemeTests.swift`:

```swift
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

final class XcodeSchemeTests: XCTestCase {
  #if !NO_SWIFTPM_DEPENDENCY
  private func scheme(buildEntries: String, extraActions: String = "") -> Data {
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <Scheme LastUpgradeVersion="1500" version="1.7">
         <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
            <BuildActionEntries>
      \(buildEntries)
            </BuildActionEntries>
         </BuildAction>
      \(extraActions)
      </Scheme>
      """
    return Data(xml.utf8)
  }

  private func entry(blueprintName: String) -> String {
    """
          <BuildActionEntry buildForRunning="YES">
             <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="\(blueprintName)" BuildableName="\(blueprintName)" BlueprintName="\(blueprintName)" ReferencedContainer="container:MyApp.xcodeproj"></BuildableReference>
          </BuildActionEntry>
    """
  }

  func testParsesMultipleBuildActionTargetNames() {
    let data = scheme(buildEntries: entry(blueprintName: "App") + "\n" + entry(blueprintName: "Framework"))
    XCTAssertEqual(XcodeScheme.buildActionTargetNames(xcschemeContents: data), ["App", "Framework"])
  }

  func testEmptyBuildActionReturnsEmpty() {
    let data = scheme(buildEntries: "")
    XCTAssertEqual(XcodeScheme.buildActionTargetNames(xcschemeContents: data), [])
  }

  func testDeduplicatesNames() {
    let data = scheme(buildEntries: entry(blueprintName: "App") + "\n" + entry(blueprintName: "App"))
    XCTAssertEqual(XcodeScheme.buildActionTargetNames(xcschemeContents: data), ["App"])
  }

  func testIgnoresBuildableReferencesOutsideBuildAction() {
    // A TestAction BuildableReference must NOT be picked up.
    let testAction = """
         <TestAction buildConfiguration="Debug">
            <Testables>
               <TestableReference skipped="NO">
                  <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="Tests" BuildableName="Tests" BlueprintName="Tests" ReferencedContainer="container:MyApp.xcodeproj"></BuildableReference>
               </TestableReference>
            </Testables>
         </TestAction>
      """
    let data = scheme(buildEntries: entry(blueprintName: "App"), extraActions: testAction)
    XCTAssertEqual(XcodeScheme.buildActionTargetNames(xcschemeContents: data), ["App"])
  }
  #endif
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `SWIFTCI_USE_LOCAL_DEPS=1 swift test --filter BuildServerIntegrationTests.XcodeSchemeTests`
Expected: FAIL to compile — `cannot find 'XcodeScheme' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/BuildServerIntegration/XcodeScheme.swift`:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `SWIFTCI_USE_LOCAL_DEPS=1 swift test --filter BuildServerIntegrationTests.XcodeSchemeTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/BuildServerIntegration/XcodeScheme.swift Tests/BuildServerIntegrationTests/XcodeSchemeTests.swift
git commit -m "feat(BuildServerIntegration): parse .xcscheme BuildAction target names

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 2: `XcodeScheme.targetNames` — locate the scheme file on disk

**Files:**
- Modify: `Sources/BuildServerIntegration/XcodeScheme.swift`
- Test: `Tests/BuildServerIntegrationTests/XcodeSchemeTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `XcodeSchemeTests` (inside the `#if !NO_SWIFTPM_DEPENDENCY` block):

```swift
  private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcscheme-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }

  private func writeScheme(_ name: String, into schemesDir: URL, blueprintName: String) throws {
    try FileManager.default.createDirectory(at: schemesDir, withIntermediateDirectories: true)
    let data = scheme(buildEntries: entry(blueprintName: blueprintName))
    try data.write(to: schemesDir.appendingPathComponent("\(name).xcscheme", isDirectory: false))
  }

  func testTargetNamesFindsSharedScheme() throws {
    let root = try makeTempDir()
    let container = root.appendingPathComponent("MyApp.xcodeproj", isDirectory: true)
    try writeScheme(
      "MyApp",
      into: container.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true),
      blueprintName: "MyApp"
    )
    XCTAssertEqual(
      XcodeScheme.targetNames(scheme: "MyApp", containerPath: container, projectRoot: root),
      ["MyApp"]
    )
  }

  func testTargetNamesPrefersSharedOverUser() throws {
    let root = try makeTempDir()
    let container = root.appendingPathComponent("MyApp.xcodeproj", isDirectory: true)
    try writeScheme(
      "MyApp",
      into: container.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true),
      blueprintName: "SharedTarget"
    )
    try writeScheme(
      "MyApp",
      into: container.appendingPathComponent("xcuserdata/me.xcuserdatad/xcschemes", isDirectory: true),
      blueprintName: "UserTarget"
    )
    XCTAssertEqual(
      XcodeScheme.targetNames(scheme: "MyApp", containerPath: container, projectRoot: root),
      ["SharedTarget"]
    )
  }

  func testTargetNamesFindsUserSchemeWhenNoShared() throws {
    let root = try makeTempDir()
    let container = root.appendingPathComponent("MyApp.xcodeproj", isDirectory: true)
    try writeScheme(
      "MyApp",
      into: container.appendingPathComponent("xcuserdata/me.xcuserdatad/xcschemes", isDirectory: true),
      blueprintName: "UserTarget"
    )
    XCTAssertEqual(
      XcodeScheme.targetNames(scheme: "MyApp", containerPath: container, projectRoot: root),
      ["UserTarget"]
    )
  }

  func testTargetNamesReturnsNilWhenMissing() throws {
    let root = try makeTempDir()
    let container = root.appendingPathComponent("MyApp.xcodeproj", isDirectory: true)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    XCTAssertNil(XcodeScheme.targetNames(scheme: "Nope", containerPath: container, projectRoot: root))
  }

  func testTargetNamesSearchesWorkspaceMemberProjects() throws {
    let root = try makeTempDir()
    let workspace = root.appendingPathComponent("MyApp.xcworkspace", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    // Scheme lives in a member .xcodeproj, not the workspace itself.
    let memberProject = root.appendingPathComponent("Member.xcodeproj", isDirectory: true)
    try writeScheme(
      "MyApp",
      into: memberProject.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true),
      blueprintName: "MemberTarget"
    )
    XCTAssertEqual(
      XcodeScheme.targetNames(scheme: "MyApp", containerPath: workspace, projectRoot: root),
      ["MemberTarget"]
    )
  }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `SWIFTCI_USE_LOCAL_DEPS=1 swift test --filter BuildServerIntegrationTests.XcodeSchemeTests`
Expected: FAIL to compile — `type 'XcodeScheme' has no member 'targetNames'`.

- [ ] **Step 3: Write minimal implementation**

Add to `XcodeScheme` in `Sources/BuildServerIntegration/XcodeScheme.swift`:

```swift
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
      containers.append(contentsOf: entries.filter { $0.pathExtension == "xcodeproj" })
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
      for dir in userDirs {
        let candidate = dir.appendingPathComponent("xcschemes/\(scheme).xcscheme", isDirectory: false)
        if fm.fileExists(atPath: candidate.path) {
          return candidate
        }
      }
    }
    return nil
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `SWIFTCI_USE_LOCAL_DEPS=1 swift test --filter BuildServerIntegrationTests.XcodeSchemeTests`
Expected: PASS (9 tests total).

- [ ] **Step 5: Commit**

```bash
git add Sources/BuildServerIntegration/XcodeScheme.swift Tests/BuildServerIntegrationTests/XcodeSchemeTests.swift
git commit -m "feat(BuildServerIntegration): locate .xcscheme files (shared/user/workspace)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 3: `XcodeBuildServer.resolveScheme` — pure fallback decision

**Files:**
- Modify: `Sources/BuildServerIntegration/XcodeBuildServer.swift`
- Test: `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `XcodeBuildServerTests` (inside the existing `#if !NO_SWIFTPM_DEPENDENCY` block, near the `testPreferredPlatform*` unit tests):

```swift
  func testResolveSchemeMatchesNamedTargets() {
    let targets = [
      XcodeTarget(guid: "G_App", name: "App", platforms: ["macosx"]),
      XcodeTarget(guid: "G_Fw", name: "Framework", platforms: ["macosx"]),
      XcodeTarget(guid: "G_Other", name: "Other", platforms: ["macosx"]),
    ]
    let resolution = XcodeBuildServer.resolveScheme(
      named: "AppScheme",
      schemeTargetNames: ["App"],
      allTargets: targets
    )
    XCTAssertEqual(resolution, .seeds(["G_App"]))
  }

  func testResolveSchemeFallsBackToSameNamedTargetWhenNoFile() {
    let targets = [XcodeTarget(guid: "G_App", name: "App", platforms: ["macosx"])]
    let resolution = XcodeBuildServer.resolveScheme(
      named: "App",
      schemeTargetNames: nil,
      allTargets: targets
    )
    XCTAssertEqual(resolution, .seeds(["G_App"]))
  }

  func testResolveSchemeNotFoundWhenNoFileAndNoSameNamedTarget() {
    let targets = [XcodeTarget(guid: "G_App", name: "App", platforms: ["macosx"])]
    let resolution = XcodeBuildServer.resolveScheme(
      named: "Ghost",
      schemeTargetNames: nil,
      allTargets: targets
    )
    XCTAssertEqual(resolution, .fallbackNotFound)
  }

  func testResolveSchemeNoKnownTargetsWhenFileNamesDoNotMatch() {
    let targets = [XcodeTarget(guid: "G_App", name: "App", platforms: ["macosx"])]
    let resolution = XcodeBuildServer.resolveScheme(
      named: "AppScheme",
      schemeTargetNames: ["Vanished"],
      allTargets: targets
    )
    XCTAssertEqual(resolution, .fallbackNoKnownTargets)
  }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `SWIFTCI_USE_LOCAL_DEPS=1 swift test --filter BuildServerIntegrationTests.XcodeBuildServerTests/testResolveScheme`
Expected: FAIL to compile — `type 'XcodeBuildServer' has no member 'resolveScheme'`.

- [ ] **Step 3: Write minimal implementation**

Add a new extension at the end of `Sources/BuildServerIntegration/XcodeBuildServer.swift`, inside the `#if !NO_SWIFTPM_DEPENDENCY` block (before the closing `#endif`):

```swift
extension XcodeBuildServer {
  /// Result of resolving an `xcode.scheme` setting against the workspace's targets.
  ///
  /// `package` so the pure decision can be unit-tested from `BuildServerIntegrationTests`.
  package enum SchemeResolution: Equatable {
    /// Seed target GUIDs to expand via the dependency closure.
    case seeds([String])
    /// No scheme file and no same-named target — index all targets.
    case fallbackNotFound
    /// A scheme file was found but none of its targets exist in the workspace — index all targets.
    case fallbackNoKnownTargets
  }

  /// Decide which targets a scheme scopes to, purely from already-loaded data.
  ///
  /// - `schemeTargetNames`: Build-action target names from the `.xcscheme` file, or `nil` if no file
  ///   was found. When `nil`, a target whose name equals the scheme name is used as the seed (this
  ///   rescues Xcode's autogenerated schemes, which have no file and build a single same-named target).
  ///
  /// `package` (not `private`) so it is unit-testable; it touches no `SwiftBuild` types.
  package static func resolveScheme(
    named scheme: String,
    schemeTargetNames: [String]?,
    allTargets: [XcodeTarget]
  ) -> SchemeResolution {
    if let names = schemeTargetNames {
      let nameSet = Set(names)
      let guids = allTargets.filter { nameSet.contains($0.name) }.map(\.guid)
      return guids.isEmpty ? .fallbackNoKnownTargets : .seeds(guids)
    }
    if let sameNamed = allTargets.first(where: { $0.name == scheme }) {
      return .seeds([sameNamed.guid])
    }
    return .fallbackNotFound
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `SWIFTCI_USE_LOCAL_DEPS=1 swift test --filter BuildServerIntegrationTests.XcodeBuildServerTests/testResolveScheme`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/BuildServerIntegration/XcodeBuildServer.swift Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift
git commit -m "feat(BuildServerIntegration): scheme resolution + fallback decision

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 4: `SwiftBuildSession.dependencyClosure`

**Files:**
- Modify: `Sources/BuildServerIntegration/SwiftBuildSession.swift`

This wraps a SwiftBuild call that requires a live session, so it has no pure unit test; it is exercised end-to-end by the integration tests in Task 8. Verification here is that the module compiles.

- [ ] **Step 1: Add the method**

Add to the `SwiftBuildSession` actor, in the `// MARK: Targets` region directly after `targets()` (around `Sources/BuildServerIntegration/SwiftBuildSession.swift:143`):

```swift
  /// Compute the dependency closure (including implicit dependencies) of the given target GUIDs.
  ///
  /// Returns the closure as target GUIDs. Used to expand an `xcode.scheme`'s Build-action targets to
  /// everything they depend on, so dependency frameworks are indexed too. The closure does not depend
  /// on the run destination, so build parameters set only the configuration.
  package func dependencyClosure(forTargetGUIDs guids: [String]) async throws -> [String] {
    guard !guids.isEmpty else {
      return []
    }
    var params = SWBBuildParameters()
    params.configurationName = configuration
    return try await session.computeDependencyClosure(
      targetGUIDs: guids,
      buildParameters: params,
      includeImplicitDependencies: true
    )
  }
```

- [ ] **Step 2: Verify it compiles**

Run: `SWIFTCI_USE_LOCAL_DEPS=1 swift build --target BuildServerIntegration`
Expected: build succeeds with no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/BuildServerIntegration/SwiftBuildSession.swift
git commit -m "feat(BuildServerIntegration): SwiftBuildSession.dependencyClosure

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 5: Wire scheme scoping into `XcodeBuildServer.allTargets()`

**Files:**
- Modify: `Sources/BuildServerIntegration/XcodeBuildServer.swift`

This connects Tasks 1–4. Behavioral verification is the integration tests (Tasks 7–8); here we verify the module compiles and existing tests do not regress.

- [ ] **Step 1: Store the scheme on the actor**

In `XcodeBuildServer` add a stored property alongside the others near `Sources/BuildServerIntegration/XcodeBuildServer.swift:25-29`:

```swift
  private let scheme: String?
```

And set it in `init` (after `self.options = options`, before constructing the session, near line 60):

```swift
    self.scheme = options.xcodeOrDefault.scheme
```

- [ ] **Step 2: Replace `allTargets()` with the scheme-filtered version**

Replace the existing `allTargets()` (currently at `Sources/BuildServerIntegration/XcodeBuildServer.swift:75-82`) with:

```swift
  /// All in-scope targets, cached after first load. When `xcode.scheme` is set, this is the scheme's
  /// Build-action targets plus their dependency closure; otherwise it is every workspace target.
  private func allTargets() async throws -> [XcodeTarget] {
    if let cachedTargets {
      return cachedTargets
    }
    let all = try await session.targets()
    let scoped = try await applySchemeScope(to: all)
    self.cachedTargets = scoped
    return scoped
  }

  /// Narrow `all` to the configured scheme's target closure, or return `all` unchanged when no scheme
  /// is configured or the scheme cannot be resolved.
  private func applySchemeScope(to all: [XcodeTarget]) async throws -> [XcodeTarget] {
    guard let scheme else {
      return all
    }
    let schemeTargetNames = XcodeScheme.targetNames(
      scheme: scheme,
      containerPath: containerPath,
      projectRoot: projectRoot
    )
    switch Self.resolveScheme(named: scheme, schemeTargetNames: schemeTargetNames, allTargets: all) {
    case .seeds(let seedGUIDs):
      let closure = Set(try await session.dependencyClosure(forTargetGUIDs: seedGUIDs))
      let scoped = all.filter { closure.contains($0.guid) }
      // Defensive: if the closure unexpectedly excludes everything, prefer indexing all targets over none.
      return scoped.isEmpty ? all : scoped
    case .fallbackNotFound:
      logger.log("Xcode scheme '\(scheme, privacy: .public)' not found; indexing all targets")
      return all
    case .fallbackNoKnownTargets:
      logger.log(
        "Xcode scheme '\(scheme, privacy: .public)' resolved to no known targets; indexing all targets"
      )
      return all
    }
  }
```

- [ ] **Step 3: Verify it compiles**

Run: `SWIFTCI_USE_LOCAL_DEPS=1 swift build --target BuildServerIntegration`
Expected: build succeeds.

- [ ] **Step 4: Run the existing module tests (non-regression)**

Run: `SWIFTCI_USE_LOCAL_DEPS=1 swift test --filter BuildServerIntegrationTests`
Expected: all existing tests PASS (scheme is `nil` in every existing test, so behavior is unchanged).

- [ ] **Step 5: Commit**

```bash
git add Sources/BuildServerIntegration/XcodeBuildServer.swift
git commit -m "feat(BuildServerIntegration): scope XcodeBuildServer to xcode.scheme

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 6: Update `scheme` documentation and regenerate the config schema

**Files:**
- Modify: `Sources/SKOptions/SourceKitLSPOptions.swift:152-153`
- Regenerated: `config.schema.json`, `Documentation/Configuration File.md` (do not hand-edit — generated)

- [ ] **Step 1: Update the doc comment**

Replace the `scheme` declaration in `Sources/SKOptions/SourceKitLSPOptions.swift` (currently lines 152-153):

```swift
    /// The scheme to use. Optional; informational for now.
    public var scheme: String?
```

with:

```swift
    /// The Xcode scheme whose Build-action targets (plus their dependency closure) the build server is
    /// scoped to. If `nil`, all targets in the project/workspace are used. If the named scheme has no
    /// `.xcscheme` file but a same-named target exists, that target is used; otherwise all targets are used.
    public var scheme: String?
```

- [ ] **Step 2: Regenerate the schema and docs**

Run: `./sourcekit-lsp-dev-utils generate-config-schema`
Expected: prints `Writing ... config.schema.json` and `... Configuration File.md`. The `xcode.scheme` description in both reflects the new comment.

- [ ] **Step 3: Verify the generated files are up to date**

Run: `git status --short config.schema.json "Documentation/Configuration File.md"`
Expected: both files show as modified (or no change only if already current). Confirm the new wording appears:

Run: `grep -n "Build-action targets" "Documentation/Configuration File.md" config.schema.json`
Expected: at least one match in each file.

- [ ] **Step 4: Commit**

```bash
git add "Sources/SKOptions/SourceKitLSPOptions.swift" config.schema.json "Documentation/Configuration File.md"
git commit -m "docs(SKOptions): document xcode.scheme scoping behavior

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 7: Integration test — scheme scoping on the existing single-target fixture

**Files:**
- Modify: `Sources/SKTestSupport/XcodeTestProject.swift`
- Test: `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift`

This proves the full path (scheme-file discovery → parse → resolve → dependency closure → filter) against a real SwiftBuild session, and the not-found fallback. It reuses the existing macOS command-line-tool fixture (target `MyApp`), so no new `project.pbxproj` is needed.

- [ ] **Step 1: Add a scheme-writing helper to `XcodeTestProject`**

Add this method to `XcodeTestProject` (e.g. after `keepAlive()` near `Sources/SKTestSupport/XcodeTestProject.swift:485`). It writes a minimal shared `.xcscheme`. The scheme is only consumed by our own parser (which reads `BlueprintName`); it is not handed to SwiftBuild, so it does not need to be Xcode-complete:

```swift
  /// Write a minimal shared `.xcscheme` named `name` into `MyApp.xcodeproj/xcshareddata/xcschemes`,
  /// whose Build action references `buildTargetNames`. Returns the written scheme file URL.
  ///
  /// Only the `BlueprintName` attribute is meaningful to SourceKit-LSP's scheme parser; the other
  /// attributes are filled with the target name as a stand-in.
  @discardableResult
  package func writeSharedScheme(named name: String, buildTargetNames: [String]) throws -> URL {
    let schemesDir = xcodeprojURL.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true)
    try fileManager.createDirectory(at: schemesDir, withIntermediateDirectories: true)
    let container = xcodeprojURL.lastPathComponent
    let entries = buildTargetNames.map { target in
      """
            <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
               <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="\(target)" BuildableName="\(target)" BlueprintName="\(target)" ReferencedContainer="container:\(container)"></BuildableReference>
            </BuildActionEntry>
      """
    }.joined(separator: "\n")
    let contents = """
      <?xml version="1.0" encoding="UTF-8"?>
      <Scheme LastUpgradeVersion="1500" version="1.7">
         <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
            <BuildActionEntries>
      \(entries)
            </BuildActionEntries>
         </BuildAction>
      </Scheme>
      """
    let url = schemesDir.appendingPathComponent("\(name).xcscheme", isDirectory: false)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
  }
```

- [ ] **Step 2: Write the integration tests**

Add to `XcodeBuildServerTests` (inside `#if !NO_SWIFTPM_DEPENDENCY`, in the integration-test region after `testTargetsSourcesAndSourceKitOptions`):

```swift
  /// A scheme that builds the `MyApp` target scopes the build server to that target.
  func testSchemeScopesToBuildActionTargets() async throws {
    try skipUnlessXcodeAvailable()

    let project = try XcodeTestProject(sourceContents: "print(\"hi\")\n")
    defer { project.keepAlive() }
    try project.writeSharedScheme(named: "MyAppScheme", buildTargetNames: ["MyApp"])

    let buildServer = try await XcodeBuildServer(
      projectRoot: project.projectRoot,
      containerPath: project.xcodeprojURL,
      toolchainRegistry: .forTesting,
      options: SourceKitLSPOptions(xcode: SourceKitLSPOptions.XcodeOptions(scheme: "MyAppScheme")),
      connectionToSourceKitLSP: LocalConnection(receiverName: "Dummy SourceKit-LSP")
    )
    addTeardownBlock { await buildServer.close() }

    let targetsResponse = try await buildServer.buildTargets(request: WorkspaceBuildTargetsRequest())
    XCTAssertEqual(
      targetsResponse.targets.map(\.displayName),
      ["MyApp"],
      "scheme building only MyApp should scope the build server to MyApp"
    )
  }

  /// An unknown scheme name (no file, no same-named target) falls back to indexing all targets.
  func testUnknownSchemeFallsBackToAllTargets() async throws {
    try skipUnlessXcodeAvailable()

    let project = try XcodeTestProject(sourceContents: "print(\"hi\")\n")
    defer { project.keepAlive() }

    let buildServer = try await XcodeBuildServer(
      projectRoot: project.projectRoot,
      containerPath: project.xcodeprojURL,
      toolchainRegistry: .forTesting,
      options: SourceKitLSPOptions(xcode: SourceKitLSPOptions.XcodeOptions(scheme: "DoesNotExist")),
      connectionToSourceKitLSP: LocalConnection(receiverName: "Dummy SourceKit-LSP")
    )
    addTeardownBlock { await buildServer.close() }

    let targetsResponse = try await buildServer.buildTargets(request: WorkspaceBuildTargetsRequest())
    XCTAssertTrue(
      targetsResponse.targets.contains { $0.displayName == "MyApp" },
      "unknown scheme should fall back to all targets (including MyApp)"
    )
  }
```

- [ ] **Step 3: Run the new integration tests**

Run: `SWIFTCI_USE_LOCAL_DEPS=1 swift test --filter "BuildServerIntegrationTests.XcodeBuildServerTests/testSchemeScopesToBuildActionTargets|BuildServerIntegrationTests.XcodeBuildServerTests/testUnknownSchemeFallsBackToAllTargets"`
Expected (macOS + Xcode): PASS. On non-macOS or without Xcode: SKIPPED.

- [ ] **Step 4: Commit**

```bash
git add Sources/SKTestSupport/XcodeTestProject.swift Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift
git commit -m "test(BuildServerIntegration): scheme scoping + unknown-scheme fallback

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 8: Integration test — dependency closure across a two-target project

**Files:**
- Modify: `Sources/SKTestSupport/XcodeTestProject.swift`
- Test: `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift`

This proves that a scheme building `App` (which depends on `Framework`) scopes to **both** targets via the dependency closure. It needs a real two-target `project.pbxproj` with a target dependency.

> **Important — fixture must be a validated capture, not hand-written.** Like the existing
> `pbxprojTemplate` / `iOSAppPbxprojTemplate`, the new template must be **byte-identical to a
> `project.pbxproj` produced by Xcode and validated**. Do not fabricate the pbxproj by hand: SwiftBuild
> runs `xcodebuild -dumpPIF` on it and a malformed file fails target enumeration.

- [ ] **Step 1: Generate and validate a two-target project**

In Xcode 26.4, create a macOS project named `MyApp` containing:
- a macOS **framework** target named `Framework` with one Swift source, and
- a macOS **command-line tool** (or app) target named `App` that has a **target dependency** on `Framework` (Build Phases → Dependencies, or via "Link Binary").

Then validate the generated `MyApp.xcodeproj/project.pbxproj`:

```bash
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer xcodebuild -list -project /path/to/MyApp.xcodeproj
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer xcodebuild -dumpPIF -project /path/to/MyApp.xcodeproj >/dev/null && echo "dumpPIF OK"
plutil -lint /path/to/MyApp.xcodeproj/project.pbxproj
```
Expected: `-list` shows targets `App` and `Framework`; `dumpPIF OK`; `plutil` reports `OK`.

- [ ] **Step 2: Add the captured template + a new `Kind` to `XcodeTestProject`**

In `Sources/SKTestSupport/XcodeTestProject.swift`:

1. Add a case to `Kind` (near `Sources/SKTestSupport/XcodeTestProject.swift:38-44`):

```swift
    /// A macOS project with an `App` target that depends on a `Framework` target.
    case appWithFrameworkDependency
```

2. Add the validated template as a new `static let` next to `pbxprojTemplate` / `iOSAppPbxprojTemplate`, carrying the same `// swift-format-ignore` and tab-indentation notes. Paste the **exact** bytes captured in Step 1:

```swift
  /// The validated `project.pbxproj` for a macOS project with targets `App` (depends on `Framework`)
  /// and `Framework`, each with one Swift source. Byte-identical to a project verified with
  /// `xcodebuild -list`, `xcodebuild -dumpPIF`, and `plutil -lint` using Xcode 26.4.
  // swift-format-ignore
  package static let appWithFrameworkPbxprojTemplate: String = """
  <PASTE THE VALIDATED project.pbxproj CONTENTS FROM STEP 1 HERE>
  """
```

3. Select the template for the new kind in `init` (the `switch` near `Sources/SKTestSupport/XcodeTestProject.swift:464-466`):

```swift
    case .appWithFrameworkDependency: template = Self.appWithFrameworkPbxprojTemplate
```

> If the captured project places target sources at fixed relative paths (e.g. `App/main.swift`,
> `Framework/Framework.swift`), also write those source files in `init` for this kind so the targets
> have buildable sources. Mirror how the existing kinds create `sourceFileURL`; reuse `sourceContents`
> for the primary source. Keep this minimal — the test below only inspects target membership, not sources.

- [ ] **Step 3: Write the dependency-closure test**

Add to `XcodeBuildServerTests` (inside `#if !NO_SWIFTPM_DEPENDENCY`, integration region):

```swift
  /// A scheme building `App` (which depends on `Framework`) scopes to both targets via the
  /// dependency closure.
  func testSchemeIncludesDependencyClosure() async throws {
    try skipUnlessXcodeAvailable()

    let project = try XcodeTestProject(kind: .appWithFrameworkDependency, sourceContents: "let x = 1\n")
    defer { project.keepAlive() }
    try project.writeSharedScheme(named: "AppScheme", buildTargetNames: ["App"])

    let buildServer = try await XcodeBuildServer(
      projectRoot: project.projectRoot,
      containerPath: project.xcodeprojURL,
      toolchainRegistry: .forTesting,
      options: SourceKitLSPOptions(xcode: SourceKitLSPOptions.XcodeOptions(scheme: "AppScheme")),
      connectionToSourceKitLSP: LocalConnection(receiverName: "Dummy SourceKit-LSP")
    )
    addTeardownBlock { await buildServer.close() }

    let targetsResponse = try await buildServer.buildTargets(request: WorkspaceBuildTargetsRequest())
    let names = Set(targetsResponse.targets.map(\.displayName))
    XCTAssertTrue(names.contains("App"), "expected App in scope, got: \(names)")
    XCTAssertTrue(
      names.contains("Framework"),
      "expected Framework (App's dependency) in scope via the dependency closure, got: \(names)"
    )
  }
```

- [ ] **Step 4: Run the test**

Run: `SWIFTCI_USE_LOCAL_DEPS=1 swift test --filter BuildServerIntegrationTests.XcodeBuildServerTests/testSchemeIncludesDependencyClosure`
Expected (macOS + Xcode): PASS. Otherwise: SKIPPED.

- [ ] **Step 5: Commit**

```bash
git add Sources/SKTestSupport/XcodeTestProject.swift Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift
git commit -m "test(BuildServerIntegration): scheme dependency-closure scoping

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 9: Lint, full non-regression, and final verification

**Files:** none (verification only).

- [ ] **Step 1: Lint all touched files**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer \
  swift format lint --strict --recursive \
  Sources/BuildServerIntegration/XcodeScheme.swift \
  Sources/BuildServerIntegration/XcodeBuildServer.swift \
  Sources/BuildServerIntegration/SwiftBuildSession.swift \
  Sources/SKOptions/SourceKitLSPOptions.swift \
  Sources/SKTestSupport/XcodeTestProject.swift \
  Tests/BuildServerIntegrationTests/XcodeSchemeTests.swift \
  Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift
```
Expected: no diagnostics. (`appWithFrameworkPbxprojTemplate` must carry `// swift-format-ignore`, like the existing templates.) Fix any issues and amend the relevant commit.

- [ ] **Step 2: Verify generated config files are current**

Run: `./sourcekit-lsp-dev-utils verify-config-schema 2>/dev/null || ./sourcekit-lsp-dev-utils generate-config-schema`
Expected: schema/doc are up to date (no further changes). If `generate-config-schema` produced changes, commit them.

- [ ] **Step 3: Run the full module test suite**

Run: `SWIFTCI_USE_LOCAL_DEPS=1 swift test --filter BuildServerIntegrationTests`
Expected: all tests PASS (Xcode-gated integration tests SKIP when Xcode is unavailable); no regressions.

- [ ] **Step 4: Final commit (only if lint/schema fixes were needed)**

```bash
git add -A
git commit -m "style(BuildServerIntegration): satisfy swift-format lint

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Definition of Done

- With `xcode.scheme` set, `buildTargets` / `buildTargetSources` / `prepare` / `sourceKitOptions` are scoped to the scheme's Build-action targets plus their dependency closure (Tasks 5, 7, 8).
- A scheme with no `.xcscheme` file but a same-named target scopes to that target + closure (Task 3 logic; autogenerated-scheme rescue).
- An unresolvable scheme logs a warning and falls back to all targets (Tasks 3, 5, 7).
- `scheme == nil` behavior is unchanged (Task 5 Step 4 non-regression).
- Unit tests for XML parsing, file discovery, and fallback decision pass in all environments (Tasks 1–3).
- macOS + Xcode integration tests for scheme scoping and dependency-closure scoping pass (Tasks 7, 8).
- The full `BuildServerIntegrationTests` suite passes with no regressions (Task 9).
- `scheme` doc comment and generated `config.schema.json` / `Documentation/Configuration File.md` reflect the behavior (Task 6).
- swift-format lint is clean (Task 9).
