# XcodeBuildServer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `XcodeBuildServer` to SourceKit-LSP so non-Xcode editors can develop `.xcodeproj`/`.xcworkspace`-based apps (no `Package.swift` required), sourcing per-file compiler arguments and the index store from swift-build (SwiftBuild engine).

**Architecture:** A new `BuiltInBuildServer` implementation (`XcodeBuildServer`) sits in the same layer as `SwiftPMBuildServer`. All `import SwiftBuild` specifics are isolated behind a thin `SwiftBuildSession` wrapper that loads the workspace via `SWBBuildServiceSession.loadWorkspace(containerPath:)` (which accepts `.xcodeproj`/`.xcworkspace` directly and shells out to `xcrun xcodebuild -dumpPIF` internally), enumerates targets via `workspaceInfo()`, and gets per-file args via `generateIndexingFileSettings(...)`. Detection prioritizes `.xcodeproj` over `Package.swift` while keeping all existing build servers.

**Tech Stack:** Swift 6, SwiftPM, swiftlang/swift-build (`SwiftBuild`, `SWBBuildService` products), the existing SourceKit-LSP `BuildServerIntegration` module.

**Key references (read before starting):**
- Spec: `docs/superpowers/specs/2026-05-25-xcode-build-server-design.md`
- Protocol: `Sources/BuildServerIntegration/BuiltInBuildServer.swift`
- Minimal example impl: `Sources/BuildServerIntegration/JSONCompilationDatabaseBuildServer.swift`
- SwiftBuild client API (local checkout): `/Users/kazukiyamamoto/ghq/github.com/swiftlang/swift-build/Sources/SwiftBuild/SWBBuildServiceSession.swift`, `.../SWBIndexingSupport.swift`, `.../SWBBuildParameters.swift`
- SwiftBuild indexing test (usage example): `/Users/kazukiyamamoto/ghq/github.com/swiftlang/swift-build/Tests/SwiftBuildTests/IndexingInfoTests.swift`

**Important constraint:** Requires Xcode installed (`xcrun xcodebuild` is invoked by SwiftBuild to translate `.xcodeproj` → PIF). All Xcode-specific code is compiled everywhere but only activates on macOS where `xcodebuild` is found.

**Build/test commands:**
- Build module: `swift build --target BuildServerIntegration`
- Run a single test: `swift test --filter BuildServerIntegrationTests.XcodeBuildServerTests/<name>`
- The repo uses local sibling checkouts when `SWIFTCI_USE_LOCAL_DEPS` is set; `../swift-build` already exists.

---

## File Structure

**New files:**
- `Sources/BuildServerIntegration/SwiftBuildSession.swift` — isolates `import SwiftBuild`; loads workspace, lists targets, returns per-file indexing info, runs builds. Exposes only plain Swift value types (`XcodeTarget`, `XcodeIndexingFile`).
- `Sources/BuildServerIntegration/XcodeBuildServer.swift` — `BuiltInBuildServer` conformance; maps `SwiftBuildSession` output onto BSP types; detection (`searchForConfig`); caching.
- `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift` — unit tests (detection, target-id round-trip) + macOS/Xcode-gated integration tests.
- `Sources/SKTestSupport/XcodeTestProject.swift` — generates a minimal `.xcodeproj` fixture on disk for tests.

**Modified files:**
- `Package.swift` — declare the `swift-build` package dependency and add `SwiftBuild`/`SWBBuildService` products to the `BuildServerIntegration` target (gated by the existing `swiftPMDependency` mechanism).
- `Sources/SKOptions/WorkspaceType.swift` — add `case xcode`.
- `Sources/SKOptions/SourceKitLSPOptions.swift` — add `XcodeOptions`, `xcodeOrDefault`, and merging.
- `config.schema.json` — document the `xcode` options.
- `Sources/BuildServerIntegration/BuildTargetIdentifierExtensions.swift` — add `createXcode`/`xcodeTargetProperties`.
- `Sources/BuildServerIntegration/BuiltInBuildServerAdapter.swift` — add `case xcode` to `BuildServerSpec.Kind`.
- `Sources/BuildServerIntegration/DetermineBuildServer.swift` — wire `.xcode` into the preference list before `.swiftPM`.
- `Sources/BuildServerIntegration/BuildServerManager.swift` — add `.xcode` case to `createBuildServerAdapter`.

---

## Task 1: Add swift-build dependency to the build graph

**Files:**
- Modify: `Package.swift` (dependencies block ~lines 786-820; `BuildServerIntegration` target ~lines 45-66)

- [ ] **Step 1: Add the `swift-build` package dependency (local-deps branch)**

In `Package.swift`, in the `useLocalDependencies` branch of `var dependencies`, extend the `swiftPMDependency([...])` array (currently just the `swift-package-manager` local package) so swift-build is pulled alongside SwiftPM:

```swift
    ] + swiftPMDependency([
      .package(name: "swift-package-manager", path: "../swiftpm"),
      .package(name: "swift-build", path: "../swift-build"),
    ])
```

- [ ] **Step 2: Add the `swift-build` package dependency (remote branch)**

In the `else` branch, extend the trailing `swiftPMDependency([...])`:

```swift
      + swiftPMDependency([
        .package(url: "https://github.com/swiftlang/swift-package-manager.git", branch: relatedDependenciesBranch),
        .package(url: "https://github.com/swiftlang/swift-build.git", branch: relatedDependenciesBranch),
      ])
```

- [ ] **Step 3: Add SwiftBuild products to the `BuildServerIntegration` target**

In the `BuildServerIntegration` target's `swiftPMDependency([...])` block (currently `SwiftPM-auto`, `SwiftPMDataModel-auto`), add:

```swift
      + swiftPMDependency([
        .product(name: "SwiftPM-auto", package: "swift-package-manager"),
        .product(name: "SwiftPMDataModel-auto", package: "swift-package-manager"),
        .product(name: "SwiftBuild", package: "swift-build"),
        .product(name: "SWBBuildService", package: "swift-build"),
      ]),
```

Note: `SWBBuildService` is included so the build service runs in-process (mirrors how swiftpm links it). The existing `NO_SWIFTPM_DEPENDENCY` define will guard the Xcode code paths, so no new flag is needed.

- [ ] **Step 4: Verify the package resolves and `import SwiftBuild` compiles**

Add a temporary file `Sources/BuildServerIntegration/_SwiftBuildImportCheck.swift`:

```swift
#if !NO_SWIFTPM_DEPENDENCY
import SwiftBuild
#endif
```

Run: `SWIFTCI_USE_LOCAL_DEPS=1 swift build --target BuildServerIntegration`
Expected: builds successfully (resolves `../swift-build`).

- [ ] **Step 5: Remove the temporary check file**

```bash
rm Sources/BuildServerIntegration/_SwiftBuildImportCheck.swift
```

- [ ] **Step 6: Commit**

```bash
git add Package.swift
git commit -m "build: add swift-build dependency to BuildServerIntegration

Task context: add XcodeBuildServer (.xcodeproj + swift-build) to SourceKit-LSP.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Add `.xcode` to `WorkspaceType`

**Files:**
- Modify: `Sources/SKOptions/WorkspaceType.swift`

- [ ] **Step 1: Add the enum case**

```swift
public enum WorkspaceType: String, Codable, Sendable {
  case buildServer
  case compilationDatabase
  case swiftPM
  case xcode
}
```

- [ ] **Step 2: Build to verify exhaustive switches still compile**

Run: `SWIFTCI_USE_LOCAL_DEPS=1 swift build --target BuildServerIntegration`
Expected: compiles. (`DetermineBuildServer` switches over `WorkspaceType`; it will get the `.xcode` case in Task 7. Until then, the switch needs a case — if the build fails with "must be exhaustive", add `case .xcode: break` temporarily and remove it in Task 7. Prefer to do Task 7's `DetermineBuildServer` edit before committing if the build breaks.)

- [ ] **Step 3: Commit**

```bash
git add Sources/SKOptions/WorkspaceType.swift
git commit -m "feat(SKOptions): add xcode WorkspaceType

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Add `XcodeOptions` to `SourceKitLSPOptions`

**Files:**
- Modify: `Sources/SKOptions/SourceKitLSPOptions.swift`
- Modify: `config.schema.json`

Read `Sources/SKOptions/SourceKitLSPOptions.swift` lines 24-160 first to copy the exact style of `SwiftPMOptions` (it defines a nested struct, a stored `public var swiftPM: SwiftPMOptions?`, a `swiftPMOrDefault` computed property, a `merging` static func, and participates in the top-level `merging`).

- [ ] **Step 1: Add the nested `XcodeOptions` struct**

Place this next to `SwiftPMOptions` inside `struct SourceKitLSPOptions`:

```swift
  public struct XcodeOptions: Sendable, Codable, Equatable {
    /// The `.xcodeproj` or `.xcworkspace` to load, relative to the project root. Auto-detected if `nil`.
    public var container: String?
    /// The scheme to use. Optional; informational for now.
    public var scheme: String?
    /// The build configuration to use. Defaults to `Debug`.
    public var configuration: String?
    /// An xcodebuild `-destination` specifier (e.g. `platform=iOS Simulator,name=iPhone 15`).
    /// If `nil`, a destination is inferred from each target's supported platform.
    public var destination: String?

    public init(
      container: String? = nil,
      scheme: String? = nil,
      configuration: String? = nil,
      destination: String? = nil
    ) {
      self.container = container
      self.scheme = scheme
      self.configuration = configuration
      self.destination = destination
    }

    static func merging(base: XcodeOptions, override: XcodeOptions?) -> XcodeOptions {
      return XcodeOptions(
        container: override?.container ?? base.container,
        scheme: override?.scheme ?? base.scheme,
        configuration: override?.configuration ?? base.configuration,
        destination: override?.destination ?? base.destination
      )
    }
  }
```

- [ ] **Step 2: Add the stored property and `xcodeOrDefault`**

Next to `public var swiftPM: SwiftPMOptions?`:

```swift
  public var xcode: XcodeOptions?
```

Next to `public var swiftPMOrDefault`:

```swift
  public var xcodeOrDefault: XcodeOptions {
    return xcode ?? XcodeOptions()
  }
```

- [ ] **Step 3: Thread `xcode` through the top-level `init` and `merging`**

Add `xcode: XcodeOptions? = nil` to the designated initializer parameter list, assign `self.xcode = xcode`, and add to the top-level `merging` (next to the `swiftPM:` line ~552):

```swift
      xcode: XcodeOptions.merging(base: base.xcodeOrDefault, override: override?.xcode),
```

(Match the exact initializer parameter order used by the file. If `SourceKitLSPOptions` implements `LSPAnyCodable` manually, add `xcode` to the encode/decode there too, mirroring `swiftPM`.)

- [ ] **Step 4: Build to verify**

Run: `SWIFTCI_USE_LOCAL_DEPS=1 swift build --target SKOptions`
Expected: compiles.

- [ ] **Step 5: Document in `config.schema.json`**

Add an `xcode` object property mirroring the `swiftPM` entry's structure (description + sub-properties `container`, `scheme`, `configuration`, `destination`, all strings). Keep formatting consistent with neighbours.

- [ ] **Step 6: Commit**

```bash
git add Sources/SKOptions/SourceKitLSPOptions.swift config.schema.json
git commit -m "feat(SKOptions): add xcode build server options

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: BuildTargetIdentifier helpers for Xcode

**Files:**
- Modify: `Sources/BuildServerIntegration/BuildTargetIdentifierExtensions.swift`
- Test: `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift`

Model after the existing `createCompileCommands`/`compileCommandsCompiler` pair (lines 101-147). A target id encodes the SwiftBuild target GUID so we can recover it in `sourceKitOptions`/`buildTargetSources`.

- [ ] **Step 1: Write the failing test**

Create `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift`:

```swift
import BuildServerProtocol
@_spi(SourceKitLSP) import BuildServerIntegration
import LanguageServerProtocol
import XCTest

final class XcodeBuildServerTests: XCTestCase {
  func testXcodeTargetIdentifierRoundTrip() throws {
    let id = try BuildTargetIdentifier.createXcode(targetGUID: "T1::TARGET@v1")
    XCTAssertEqual(try id.xcodeTargetGUID, "T1::TARGET@v1")
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `SWIFTCI_USE_LOCAL_DEPS=1 swift test --filter BuildServerIntegrationTests.XcodeBuildServerTests/testXcodeTargetIdentifierRoundTrip`
Expected: FAIL — `createXcode` / `xcodeTargetGUID` are undefined.

- [ ] **Step 3: Implement the helpers**

Append to `BuildTargetIdentifierExtensions.swift`:

```swift
// MARK: BuildTargetIdentifier for Xcode

extension BuildTargetIdentifier {
  package static func createXcode(targetGUID: String) throws -> BuildTargetIdentifier {
    var components = URLComponents()
    components.scheme = "xcode"
    components.host = "target"
    components.queryItems = [URLQueryItem(name: "guid", value: targetGUID)]

    struct FailedToConvertXcodeTargetToUrlError: Swift.Error, CustomStringConvertible {
      var guid: String
      var description: String { "Failed to generate URL for Xcode target GUID: \(guid)" }
    }

    guard let url = components.url else {
      throw FailedToConvertXcodeTargetToUrlError(guid: targetGUID)
    }
    return BuildTargetIdentifier(uri: URI(url))
  }

  var xcodeTargetGUID: String {
    get throws {
      struct InvalidTargetIdentifierError: Swift.Error, CustomStringConvertible {
        var target: BuildTargetIdentifier
        var description: String { "Invalid Xcode target identifier \(target)" }
      }
      guard let components = URLComponents(url: self.uri.arbitrarySchemeURL, resolvingAgainstBaseURL: false),
        components.scheme == "xcode", components.host == "target",
        let guid = components.queryItems?.last(where: { $0.name == "guid" })?.value
      else {
        throw InvalidTargetIdentifierError(target: self)
      }
      return guid
    }
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `SWIFTCI_USE_LOCAL_DEPS=1 swift test --filter BuildServerIntegrationTests.XcodeBuildServerTests/testXcodeTargetIdentifierRoundTrip`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/BuildServerIntegration/BuildTargetIdentifierExtensions.swift Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift
git commit -m "feat(BuildServerIntegration): Xcode build target identifier

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: `SwiftBuildSession` wrapper (isolates `import SwiftBuild`)

**Files:**
- Create: `Sources/BuildServerIntegration/SwiftBuildSession.swift`

**Verify-against-API note:** The SwiftBuild calls below are from research of the local checkout but were not compiled. Before/while implementing, open `/Users/kazukiyamamoto/ghq/github.com/swiftlang/swift-build/Sources/SwiftBuild/SWBBuildServiceSession.swift` and `.../SWBIndexingSupport.swift`, and `Tests/SwiftBuildTests/IndexingInfoTests.swift`, and adjust exact type/field names (`SWBWorkspaceInfo` target fields, `SWBRunDestinationInfo` constructors, `SWBArenaInfo` member names, the `sourceFileBuildInfos` keys) to match. The public, value-typed surface this file exposes (`XcodeTarget`, `XcodeIndexingFile`) must not change, so downstream tasks stay valid.

- [ ] **Step 1: Define the plain value types and the session actor skeleton**

Create `Sources/BuildServerIntegration/SwiftBuildSession.swift`:

```swift
//===----------------------------------------------------------------------===//
// This source file is part of the Swift.org open source project
// Copyright (c) 2014 - 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
// See https://swift.org/LICENSE.txt for license information
//===----------------------------------------------------------------------===//

#if !NO_SWIFTPM_DEPENDENCY
package import Foundation
@_spi(SourceKitLSP) import SKLogging
@preconcurrency import SwiftBuild

/// A target in a loaded Xcode workspace, in plain value form.
package struct XcodeTarget: Sendable, Equatable {
  package var guid: String
  package var name: String
  /// Supported platform names (e.g. "macosx", "iphonesimulator"). Empty if unknown.
  package var platforms: [String]
}

/// Per-file build/indexing info, in plain value form.
package struct XcodeIndexingFile: Sendable, Equatable {
  package var sourceFilePath: URL
  package var outputFilePath: URL?
  package var language: Language
  package var compilerArguments: [String]
}

/// Thin wrapper around a `SWBBuildServiceSession`. All `import SwiftBuild` lives here.
package actor SwiftBuildSession {
  private let service: SWBBuildService
  private let session: SWBBuildServiceSession
  private let containerPath: URL
  let configuration: String
  let indexStorePath: URL
  let indexDatabasePath: URL
  let derivedDataPath: URL
  private let destinationOverride: String?

  package init(
    containerPath: URL,
    configuration: String,
    destinationOverride: String?,
    derivedDataPath: URL
  ) async throws {
    self.containerPath = containerPath
    self.configuration = configuration
    self.destinationOverride = destinationOverride
    self.derivedDataPath = derivedDataPath
    self.indexStorePath = derivedDataPath.appending(component: "Index.noindex").appending(component: "DataStore")
    self.indexDatabasePath = derivedDataPath.appending(component: "IndexDatabase")
    self.service = try await SWBBuildService()
    let (sessionResult, _) = await service.createSession(name: containerPath.path, cachePath: nil)
    self.session = try sessionResult.get()
    try await session.loadWorkspace(containerPath: containerPath.path)
  }
}
#endif
```

- [ ] **Step 2: Add a shared build-parameters builder**

Add inside the actor. `SWBArenaInfo`/`SWBBuildParameters` member names must be verified against `SWBBuildParameters.swift`.

```swift
  private func makeBuildRequest(for target: XcodeTarget) -> SWBBuildRequest {
    var params = SWBBuildParameters()
    params.action = "build"
    params.configurationName = configuration
    params.activeRunDestination = runDestination(for: target)
    params.arenaInfo = SWBArenaInfo(
      derivedDataPath: derivedDataPath.path,
      buildProductsPath: derivedDataPath.appending(component: "Build/Products").path,
      buildIntermediatesPath: derivedDataPath.appending(component: "Build/Intermediates.noindex").path,
      pchPath: derivedDataPath.appending(component: "Build/Intermediates.noindex/PrecompiledHeaders").path,
      indexRegularBuildProductsPath: nil,
      indexRegularBuildIntermediatesPath: nil,
      indexPCHPath: derivedDataPath.appending(component: "Index.noindex/PrecompiledHeaders").path,
      indexDataStoreFolderPath: indexStorePath.path,
      indexEnableDataStore: true
    )
    var request = SWBBuildRequest()
    request.parameters = params
    request.add(target: SWBConfiguredTarget(guid: target.guid))
    return request
  }

  /// Maps a target's platform to a run destination, honoring the configured override.
  private func runDestination(for target: XcodeTarget) -> SWBRunDestinationInfo {
    if let destinationOverride, let parsed = SwiftBuildSession.parseDestination(destinationOverride) {
      return parsed
    }
    // Default inference. Verify available SWBRunDestinationInfo factories against the API.
    switch target.platforms.first {
    case "iphonesimulator", "iphoneos": return .iOSSimulator
    case "appletvsimulator", "appletvos": return .tvOSSimulator
    case "watchsimulator", "watchos": return .watchOSSimulator
    default: return .macOS
    }
  }

  /// Parses an xcodebuild `-destination`-style string into a run destination. Returns nil if unparseable.
  static func parseDestination(_ string: String) -> SWBRunDestinationInfo? {
    // Implement using the SWBRunDestinationInfo initializer surface available in the API.
    // At minimum support `platform=macOS` and `platform=iOS Simulator`.
    let pairs = string.split(separator: ",").reduce(into: [String: String]()) { dict, part in
      let kv = part.split(separator: "=", maxSplits: 1)
      if kv.count == 2 { dict[kv[0].trimmingCharacters(in: .whitespaces)] = kv[1].trimmingCharacters(in: .whitespaces) }
    }
    switch pairs["platform"]?.lowercased() {
    case "macos", "os x": return .macOS
    case "ios simulator": return .iOSSimulator
    default: return nil
    }
  }
```

Note: If `SWBRunDestinationInfo` exposes only `.macOS` plus a memberwise initializer (not `.iOSSimulator` etc.), construct the others explicitly from `(platform, sdk, sdkVariant, targetArchitecture, supportedArchitectures, disableOnlyActiveArch)`. Verify in the API and adjust this single function — nothing else depends on its internals.

- [ ] **Step 3: Implement `targets()`**

```swift
  /// All targets in the loaded workspace.
  package func targets() async throws -> [XcodeTarget] {
    let info = try await session.workspaceInfo()
    // Verify SWBWorkspaceInfo's member shape: it exposes target GUIDs and names.
    // Adjust the mapping below to the actual property names.
    return info.targetInfos.map { target in
      XcodeTarget(guid: target.guid, name: target.targetName, platforms: [])
    }
  }
```

If `SWBWorkspaceInfo` does not carry platform info, leave `platforms: []` (destination falls back to macOS or the configured override); platform inference can be enriched later via `describeSchemes`/build settings without changing this type.

- [ ] **Step 4: Implement `indexingFiles(for:)`**

```swift
  /// Per-file indexing info for a target (source list + compiler args + output paths).
  package func indexingFiles(for target: XcodeTarget) async throws -> [XcodeIndexingFile] {
    let request = makeBuildRequest(for: target)
    let settings = try await session.generateIndexingFileSettings(
      for: request,
      targetID: target.guid,
      filePath: nil,
      outputPathOnly: false,
      delegate: EmptyIndexingDelegate()
    )
    return settings.sourceFileBuildInfos.compactMap { info -> XcodeIndexingFile? in
      guard let sourcePath = info["sourceFilePath"]?.stringValue else { return nil }
      let dialect = info["LanguageDialect"]?.stringValue
      let language = SwiftBuildSession.language(forDialect: dialect)
      let args: [String]
      switch language {
      case .swift: args = info["swiftASTCommandArguments"]?.stringArrayValue ?? []
      default: args = info["clangASTCommandArguments"]?.stringArrayValue ?? []
      }
      guard !args.isEmpty else { return nil }
      return XcodeIndexingFile(
        sourceFilePath: URL(fileURLWithPath: sourcePath),
        outputFilePath: info["outputFilePath"]?.stringValue.map { URL(fileURLWithPath: $0) },
        language: language,
        compilerArguments: args
      )
    }
  }

  private static func language(forDialect dialect: String?) -> Language {
    switch dialect {
    case "swift": return .swift
    case "objective-c": return .objective_c
    case "objective-c++": return .objective_cpp
    case "c++": return .cpp
    default: return .c
    }
  }
```

Add a minimal indexing delegate (verify the `SWBIndexingDelegate`/`SWBPlanningOperationDelegate` requirements; `EmptyBuildOperationDelegate` may already exist in `SWBTestSupport` but is test-only, so implement our own):

```swift
  private struct EmptyIndexingDelegate: SWBIndexingDelegate {
    // Implement the required SWBPlanningOperationDelegate methods as no-ops / sensible defaults.
    // Fill in exactly per the protocol in SwiftBuild (e.g. provisioningTaskInputs, executeExternalTool).
  }
```

- [ ] **Step 5: Implement `build(targets:)` (for prepare) and `reload()`**

```swift
  /// Builds the given targets to populate the index store. Used by `prepare`.
  package func build(targets: [XcodeTarget]) async throws {
    for target in targets {
      let request = makeBuildRequest(for: target)
      let operation = try await session.createBuildOperation(
        request: request,
        delegate: EmptyIndexingDelegate()
      )
      try await operation.start()
      await operation.waitForCompletion()
    }
  }

  /// Reload the workspace after the project files changed on disk.
  package func reload() async throws {
    try await session.loadWorkspace(containerPath: containerPath.path)
  }
```

Verify the build-operation API names against `SWBBuildOperation.swift` and adjust (the create/start/wait surface). Output of the build matters only insofar as the index store gets populated.

- [ ] **Step 6: Compile-check the wrapper**

Run: `SWIFTCI_USE_LOCAL_DEPS=1 swift build --target BuildServerIntegration`
Expected: compiles. Fix any API-shape mismatches surfaced by the compiler against the real SwiftBuild types (this is the expected place to reconcile the research signatures with reality).

- [ ] **Step 7: Commit**

```bash
git add Sources/BuildServerIntegration/SwiftBuildSession.swift
git commit -m "feat(BuildServerIntegration): SwiftBuild session wrapper

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: `XcodeBuildServer` conforming to `BuiltInBuildServer`

**Files:**
- Create: `Sources/BuildServerIntegration/XcodeBuildServer.swift`

Read `JSONCompilationDatabaseBuildServer.swift` again for the exact conformance shape (it is the minimal reference). `XcodeBuildServer` caches per-target `[XcodeIndexingFile]` and builds a `URL → (targetGUID, XcodeIndexingFile)` index.

- [ ] **Step 1: Implement the actor skeleton + properties**

Create `Sources/BuildServerIntegration/XcodeBuildServer.swift`:

```swift
//===----------------------------------------------------------------------===//
// This source file is part of the Swift.org open source project
// Copyright (c) 2014 - 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
// See https://swift.org/LICENSE.txt for license information
//===----------------------------------------------------------------------===//

#if !NO_SWIFTPM_DEPENDENCY
@_spi(SourceKitLSP) package import BuildServerProtocol
package import Foundation
@_spi(SourceKitLSP) package import LanguageServerProtocol
@_spi(SourceKitLSP) import SKLogging
package import SKOptions
import ToolchainRegistry

package actor XcodeBuildServer: BuiltInBuildServer {
  private let projectRoot: URL
  private let containerPath: URL
  private let options: SourceKitLSPOptions
  private let connectionToSourceKitLSP: any Connection
  private let session: SwiftBuildSession

  /// Cache: target GUID → its indexing files. Lazily filled, invalidated on watched-file change.
  private var indexingFilesByTarget: [String: [XcodeIndexingFile]] = [:]
  private var cachedTargets: [XcodeTarget]?

  package let fileWatchers: [FileSystemWatcher] = [
    FileSystemWatcher(globPattern: "**/*.xcodeproj/project.pbxproj", kind: [.create, .change, .delete]),
    FileSystemWatcher(globPattern: "**/*.xcworkspace/contents.xcworkspacedata", kind: [.create, .change, .delete]),
    FileSystemWatcher(globPattern: "**/*.xcscheme", kind: [.create, .change, .delete]),
    FileSystemWatcher(globPattern: "**/*.xcconfig", kind: [.create, .change, .delete]),
  ]

  // `session.indexStorePath`/`indexDatabasePath` are immutable Sendable `let`s on the actor, so they
  // are nonisolated and accessed synchronously (do NOT add `await` — under `-Werror` an unnecessary
  // `await` fails to compile with "no 'async' operations occur within 'await' expression").
  package var indexStorePath: URL? { get async { session.indexStorePath } }
  package var indexDatabasePath: URL? { get async { session.indexDatabasePath } }
  package nonisolated var supportsPreparationAndOutputPaths: Bool { true }

  package init(
    projectRoot: URL,
    containerPath: URL,
    toolchainRegistry: ToolchainRegistry,
    options: SourceKitLSPOptions,
    connectionToSourceKitLSP: any Connection
  ) async throws {
    self.projectRoot = projectRoot
    self.containerPath = containerPath
    self.options = options
    self.connectionToSourceKitLSP = connectionToSourceKitLSP
    let configuration = options.xcodeOrDefault.configuration ?? "Debug"
    let derivedData = projectRoot.appending(component: ".build").appending(component: "sourcekit-lsp-xcode")
    self.session = try await SwiftBuildSession(
      containerPath: containerPath,
      configuration: configuration,
      destinationOverride: options.xcodeOrDefault.destination,
      derivedDataPath: derivedData
    )
  }
}
#endif
```

- [ ] **Step 2: Implement target enumeration + caching helpers**

```swift
extension XcodeBuildServer {
  private func allTargets() async throws -> [XcodeTarget] {
    if let cachedTargets { return cachedTargets }
    let targets = try await session.targets()
    cachedTargets = targets
    return targets
  }

  private func indexingFiles(forTargetGUID guid: String) async throws -> [XcodeIndexingFile] {
    if let cached = indexingFilesByTarget[guid] { return cached }
    guard let target = try await allTargets().first(where: { $0.guid == guid }) else { return [] }
    let files = try await session.indexingFiles(for: target)
    indexingFilesByTarget[guid] = files
    return files
  }

  private func invalidateCaches() {
    cachedTargets = nil
    indexingFilesByTarget = [:]
  }
}
```

- [ ] **Step 3: Implement `buildTargets` and `buildTargetSources`**

```swift
extension XcodeBuildServer {
  package func buildTargets(request: WorkspaceBuildTargetsRequest) async throws -> WorkspaceBuildTargetsResponse {
    let targets = try await allTargets().map { target in
      // Initializer shape mirrors JSONCompilationDatabaseBuildServer.buildTargets (verified).
      // If `BuildTarget` exposes an optional `displayName:`, pass `target.name` for nicer UX.
      BuildTarget(
        id: try BuildTargetIdentifier.createXcode(targetGUID: target.guid),
        tags: [],
        capabilities: BuildTargetCapabilities(),
        languageIds: [.c, .cpp, .objective_c, .objective_cpp, .swift],
        dependencies: [],
        dataKind: .sourceKit,
        data: SourceKitBuildTarget(toolchain: nil).encodeToLSPAny()
      )
    }
    return WorkspaceBuildTargetsResponse(targets: targets)
  }

  package func buildTargetSources(request: BuildTargetSourcesRequest) async throws -> BuildTargetSourcesResponse {
    let items = try await request.targets.asyncMap { (targetID) -> SourcesItem in
      let guid = try targetID.xcodeTargetGUID
      let files = try await indexingFiles(forTargetGUID: guid)
      let sources = files.map { file in
        SourceItem(
          uri: DocumentURI(file.sourceFilePath),
          kind: .file,
          generated: false,
          dataKind: .sourceKit,
          data: SourceKitSourceItemData(
            outputPath: file.outputFilePath?.path
          ).encodeToLSPAny()
        )
      }
      return SourcesItem(target: targetID, sources: sources)
    }
    return BuildTargetSourcesResponse(items: items)
  }
}
```

Note: Verify the exact initializer parameters of `BuildTarget`, `SourceItem`, and `SourceKitSourceItemData` against `BuildServerProtocol`/the SwiftPM build server's usage (open `SwiftPMBuildServer.swift` `buildTargetSources` to copy the `outputPath`/`SourceKitSourceItemData` field names precisely). `asyncMap` is already used elsewhere in this module.

- [ ] **Step 4: Implement `sourceKitOptions`**

```swift
extension XcodeBuildServer {
  package func sourceKitOptions(
    request: TextDocumentSourceKitOptionsRequest
  ) async throws -> TextDocumentSourceKitOptionsResponse? {
    let guid = try request.target.xcodeTargetGUID
    guard let fileURL = request.textDocument.uri.fileURL else { return nil }
    let files = try await indexingFiles(forTargetGUID: guid)
    guard let match = files.first(where: { $0.sourceFilePath.resolvingSymlinksInPath() == fileURL.resolvingSymlinksInPath() })
    else {
      return nil
    }
    return TextDocumentSourceKitOptionsResponse(
      compilerArguments: match.compilerArguments,
      workingDirectory: try? projectRoot.filePath
    )
  }
}
```

- [ ] **Step 5: Implement `prepare`, `didChangeWatchedFiles`, `waitForBuildSystemUpdates`**

```swift
extension XcodeBuildServer {
  package func prepare(request: BuildTargetPrepareRequest) async throws -> BuildTargetPrepareResponse {
    let guids = try request.targets.map { try $0.xcodeTargetGUID }
    let targets = try await allTargets().filter { guids.contains($0.guid) }
    try await session.build(targets: targets)
    return BuildTargetPrepareResponse()
  }

  package func didChangeWatchedFiles(notification: OnWatchedFilesDidChangeNotification) async {
    await orLog("Reloading Xcode workspace") {
      try await session.reload()
    }
    invalidateCaches()
    connectionToSourceKitLSP.send(OnBuildTargetDidChangeNotification(changes: nil))
  }

  package func waitForBuildSystemUpdates(request: WorkspaceWaitForBuildSystemUpdatesRequest) async -> VoidResponse {
    return VoidResponse()
  }
}
```

- [ ] **Step 6: Compile-check**

Run: `SWIFTCI_USE_LOCAL_DEPS=1 swift build --target BuildServerIntegration`
Expected: compiles. Reconcile any BSP type initializer mismatches by copying exact shapes from `SwiftPMBuildServer.swift`.

- [ ] **Step 7: Commit**

```bash
git add Sources/BuildServerIntegration/XcodeBuildServer.swift
git commit -m "feat(BuildServerIntegration): XcodeBuildServer BuiltInBuildServer

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Detection + wiring (Kind, searchForConfig, DetermineBuildServer, adapter)

**Files:**
- Modify: `Sources/BuildServerIntegration/XcodeBuildServer.swift` (add `searchForConfig`)
- Modify: `Sources/BuildServerIntegration/BuiltInBuildServerAdapter.swift` (Kind)
- Modify: `Sources/BuildServerIntegration/DetermineBuildServer.swift`
- Modify: `Sources/BuildServerIntegration/BuildServerManager.swift`
- Test: `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift`

- [ ] **Step 1: Write failing detection tests**

Add to `XcodeBuildServerTests.swift`:

```swift
func testDetectsXcodeproj() throws {
  let dir = try temporaryDirectory()
  try FileManager.default.createDirectory(at: dir.appending(component: "MyApp.xcodeproj"), withIntermediateDirectories: true)
  let spec = XcodeBuildServer.searchForConfig(in: dir, options: SourceKitLSPOptions())
  XCTAssertEqual(spec?.configPath.lastPathComponent, "MyApp.xcodeproj")
}

func testPrefersXcworkspaceOverXcodeproj() throws {
  let dir = try temporaryDirectory()
  try FileManager.default.createDirectory(at: dir.appending(component: "MyApp.xcodeproj"), withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: dir.appending(component: "MyApp.xcworkspace"), withIntermediateDirectories: true)
  let spec = XcodeBuildServer.searchForConfig(in: dir, options: SourceKitLSPOptions())
  XCTAssertEqual(spec?.configPath.pathExtension, "xcworkspace")
}

func testNoXcodeContainerReturnsNil() throws {
  let dir = try temporaryDirectory()
  XCTAssertNil(XcodeBuildServer.searchForConfig(in: dir, options: SourceKitLSPOptions()))
}
```

Add a `temporaryDirectory()` helper at the bottom of the test class:

```swift
private func temporaryDirectory() throws -> URL {
  let dir = FileManager.default.temporaryDirectory.appending(component: "xcode-bs-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
  return dir
}
```

(Import `SKOptions` in the test file.)

- [ ] **Step 2: Run to verify failure**

Run: `SWIFTCI_USE_LOCAL_DEPS=1 swift test --filter BuildServerIntegrationTests.XcodeBuildServerTests/testDetectsXcodeproj`
Expected: FAIL — `searchForConfig` undefined.

- [ ] **Step 3: Implement `searchForConfig`**

Add to `XcodeBuildServer.swift` (inside the `#if !NO_SWIFTPM_DEPENDENCY` block):

```swift
extension XcodeBuildServer {
  /// Look for an Xcode workspace/project in `path`. Prefers `.xcworkspace`, honors `options.xcode.container`.
  static package func searchForConfig(in path: URL, options: SourceKitLSPOptions) -> BuildServerSpec? {
    let fm = FileManager.default

    // Explicit container from configuration wins.
    if let container = options.xcodeOrDefault.container {
      let url = path.appending(component: container)
      if fm.fileExists(atPath: url.path) {
        return BuildServerSpec(kind: .xcode, projectRoot: path, configPath: url)
      }
    }

    guard let entries = try? fm.contentsOfDirectory(at: path, includingPropertiesForKeys: nil) else {
      return nil
    }
    func pick(_ ext: String) -> URL? {
      let matches = entries.filter { $0.pathExtension == ext }.sorted { $0.lastPathComponent < $1.lastPathComponent }
      return matches.first(where: { $0.deletingPathExtension().lastPathComponent == path.lastPathComponent }) ?? matches.first
    }
    guard let container = pick("xcworkspace") ?? pick("xcodeproj") else {
      return nil
    }
    // Xcode is required to translate .xcodeproj → PIF. If it isn't available, decline so SwiftPM/others run.
    guard xcodebuildIsAvailable() else {
      logger.log("Found \(container.lastPathComponent) but xcodebuild is unavailable; skipping Xcode build server")
      return nil
    }
    return BuildServerSpec(kind: .xcode, projectRoot: path, configPath: container)
  }

  private static func xcodebuildIsAvailable() -> Bool {
    #if os(macOS)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["--find", "xcodebuild"]
    process.standardOutput = nil
    process.standardError = nil
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus == 0
    } catch {
      return false
    }
    #else
    return false
    #endif
  }
}
```

- [ ] **Step 4: Add `.xcode` to `BuildServerSpec.Kind`**

In `BuiltInBuildServerAdapter.swift`:

```swift
  package enum Kind {
    case externalBuildServer
    case jsonCompilationDatabase
    case fixedCompilationDatabase
    case swiftPM(inferredBuildSystem: SwiftPMBuildSystem?)
    case xcode
    case injected(
      @Sendable (_ projectRoot: URL, _ connectionToSourceKitLSP: any Connection) async -> any Connection
    )
  }
```

- [ ] **Step 5: Wire `.xcode` into `DetermineBuildServer`**

In `DetermineBuildServer.swift`, update the preference list and the switch (Xcode before SwiftPM, explicit `.bsp/` stays first):

```swift
  var buildServerPreference: [WorkspaceType] = [
    .buildServer, .xcode, .swiftPM, .compilationDatabase,
  ]
```

Add the switch case:

```swift
    case .xcode:
      #if !NO_SWIFTPM_DEPENDENCY
      spec = XcodeBuildServer.searchForConfig(in: workspaceFolderUrl, options: options)
      #endif
```

- [ ] **Step 6: Add `.xcode` to `createBuildServerAdapter`**

In `BuildServerManager.swift`, add a case (next to `.swiftPM`) using the existing `createBuiltInBuildServerAdapter` helper:

```swift
    case .xcode:
      #if !NO_SWIFTPM_DEPENDENCY
      return await createBuiltInBuildServerAdapter(
        messagesToSourceKitLSPHandler: messagesToSourceKitLSPHandler,
        buildServerHooks: buildServerHooks
      ) { connectionToSourceKitLSP in
        try await XcodeBuildServer(
          projectRoot: projectRoot,
          containerPath: configPath,
          toolchainRegistry: toolchainRegistry,
          options: options,
          connectionToSourceKitLSP: connectionToSourceKitLSP
        )
      }
      #else
      return nil
      #endif
```

- [ ] **Step 7: Run detection tests + build**

Run: `SWIFTCI_USE_LOCAL_DEPS=1 swift test --filter BuildServerIntegrationTests.XcodeBuildServerTests`
Expected: detection tests PASS, build succeeds.

- [ ] **Step 8: Commit**

```bash
git add Sources/BuildServerIntegration Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift
git commit -m "feat(BuildServerIntegration): detect and wire XcodeBuildServer

Detection prefers .xcworkspace/.xcodeproj over Package.swift; explicit
buildServer.json still wins. Requires xcodebuild; declines otherwise.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: `XcodeTestProject` fixture helper

**Files:**
- Create: `Sources/SKTestSupport/XcodeTestProject.swift`
- Modify: `Package.swift` (add `BuildServerIntegrationTests` dep on nothing new; `SKTestSupport` already a dep)

Read `Sources/SKTestSupport/SwiftPMTestProject.swift` and `MultiFileTestProject.swift` first to match the existing fixture conventions (temp dir creation, teardown, `markedSources`).

- [ ] **Step 1: Implement a minimal `.xcodeproj` generator**

Create `Sources/SKTestSupport/XcodeTestProject.swift`. It writes a minimal macOS command-line-tool `.xcodeproj` (one target, one Swift file) to a temp dir. Because `project.pbxproj` is verbose, generate it from a parameterized template string with a single Swift source. Keep the target a plain macOS tool so no code signing/SDK simulator is needed.

```swift
#if !NO_SWIFTPM_DEPENDENCY
package import Foundation

/// Creates a minimal single-target macOS `.xcodeproj` on disk for tests.
package final class XcodeTestProject {
  package let projectRoot: URL
  package let xcodeprojURL: URL
  package let sourceFileURL: URL

  package init(sourceContents: String, fileManager: FileManager = .default) throws {
    self.projectRoot = fileManager.temporaryDirectory.appending(component: "xcode-test-\(UUID().uuidString)")
    try fileManager.createDirectory(at: projectRoot, withIntermediateDirectories: true)
    self.sourceFileURL = projectRoot.appending(component: "main.swift")
    try sourceContents.write(to: sourceFileURL, atomically: true, encoding: .utf8)

    self.xcodeprojURL = projectRoot.appending(component: "MyApp.xcodeproj")
    try fileManager.createDirectory(at: xcodeprojURL, withIntermediateDirectories: true)
    let pbxproj = XcodeTestProject.pbxprojTemplate
    try pbxproj.write(to: xcodeprojURL.appending(component: "project.pbxproj"), atomically: true, encoding: .utf8)
  }

  deinit { try? FileManager.default.removeItem(at: projectRoot) }

  /// A minimal pbxproj with one macOS command-line tool target named "MyApp" and one Swift file `main.swift`.
  /// Fill this in with a valid, minimal project.pbxproj (object graph: PBXProject, one PBXNativeTarget of
  /// productType "com.apple.product-type.tool", PBXSourcesBuildPhase referencing main.swift, XCConfigurationList
  /// with a Debug XCBuildConfiguration setting SDKROOT=macosx, PRODUCT_NAME, SWIFT_VERSION=5.0).
  static let pbxprojTemplate = """
  // !$*UTF8*$!
  { /* ... minimal object graph, see note above ... */ }
  """
}
#endif
```

Note: Producing a guaranteed-valid `project.pbxproj` by hand is the fiddly part. Recommended approach: on a machine with Xcode, create a new "Command Line Tool" project named `MyApp`, copy its `project.pbxproj` verbatim into `pbxprojTemplate`, then trim to one Swift file. Commit the known-good template. (Alternative: shell out to a generator, but a static known-good template is simplest and deterministic.)

- [ ] **Step 2: Verify it builds**

Run: `SWIFTCI_USE_LOCAL_DEPS=1 swift build --target SKTestSupport`
Expected: compiles.

- [ ] **Step 3: Commit**

```bash
git add Sources/SKTestSupport/XcodeTestProject.swift
git commit -m "test(SKTestSupport): minimal Xcode project fixture

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Integration tests (macOS + Xcode gated)

**Files:**
- Modify: `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift`

These exercise the real SwiftBuild → `.xcodeproj` path, so they must be skipped when Xcode is unavailable.

- [ ] **Step 1: Add a skip guard helper**

```swift
private func skipUnlessXcodeAvailable() throws {
  #if os(macOS)
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
  p.arguments = ["--find", "xcodebuild"]
  p.standardOutput = nil; p.standardError = nil
  try? p.run(); p.waitUntilExit()
  if p.terminationStatus != 0 { throw XCTSkip("xcodebuild not available") }
  #else
  throw XCTSkip("Xcode build server requires macOS")
  #endif
}
```

- [ ] **Step 2: Write the integration test**

```swift
func testLoadsTargetsAndProvidesSwiftArgs() async throws {
  try skipUnlessXcodeAvailable()
  let project = try XcodeTestProject(sourceContents: "print(\"hello\")\n")
  let connection = LocalConnection(receiverName: "test", handler: VoidMessageHandler())
  let server = try await XcodeBuildServer(
    projectRoot: project.projectRoot,
    containerPath: project.xcodeprojURL,
    toolchainRegistry: .forTesting,
    options: SourceKitLSPOptions(),
    connectionToSourceKitLSP: connection
  )

  let targets = try await server.buildTargets(request: WorkspaceBuildTargetsRequest()).targets
  XCTAssertFalse(targets.isEmpty, "expected at least one target")

  let sources = try await server.buildTargetSources(
    request: BuildTargetSourcesRequest(targets: targets.map(\.id))
  ).items.flatMap(\.sources)
  XCTAssertTrue(
    sources.contains { $0.uri.fileURL?.lastPathComponent == "main.swift" },
    "expected main.swift in sources"
  )

  let options = try await server.sourceKitOptions(
    request: TextDocumentSourceKitOptionsRequest(
      textDocument: TextDocumentIdentifier(DocumentURI(project.sourceFileURL)),
      target: targets[0].id,
      language: .swift
    )
  )
  let args = try XCTUnwrap(options).compilerArguments
  XCTAssertTrue(args.contains("-sdk"), "expected an -sdk flag in compiler arguments: \(args)")
}
```

Note: `VoidMessageHandler`, `.forTesting`, and exact request initializers — match what other tests in `BuildServerIntegrationTests` use (grep the test target for `LocalConnection(` and `ToolchainRegistry` test helpers; reuse them rather than inventing names).

- [ ] **Step 3: Run the integration test**

Run: `SWIFTCI_USE_LOCAL_DEPS=1 swift test --filter BuildServerIntegrationTests.XcodeBuildServerTests/testLoadsTargetsAndProvidesSwiftArgs`
Expected: PASS on a macOS machine with Xcode; SKIPPED otherwise. If it fails because of SwiftBuild API shape, this is the integration checkpoint to fix `SwiftBuildSession` (Task 5) against reality.

- [ ] **Step 4: Add a prepare/index-store test**

```swift
func testPreparePopulatesIndexStore() async throws {
  try skipUnlessXcodeAvailable()
  let project = try XcodeTestProject(sourceContents: "let x = 1\n")
  let connection = LocalConnection(receiverName: "test", handler: VoidMessageHandler())
  let server = try await XcodeBuildServer(
    projectRoot: project.projectRoot,
    containerPath: project.xcodeprojURL,
    toolchainRegistry: .forTesting,
    options: SourceKitLSPOptions(),
    connectionToSourceKitLSP: connection
  )
  let targets = try await server.buildTargets(request: WorkspaceBuildTargetsRequest()).targets
  _ = try await server.prepare(request: BuildTargetPrepareRequest(targets: targets.map(\.id)))
  let storePath = try await XCTUnwrap(server.indexStorePath)
  XCTAssertTrue(FileManager.default.fileExists(atPath: storePath.path), "index store should exist after prepare")
}
```

- [ ] **Step 5: Run it**

Run: `SWIFTCI_USE_LOCAL_DEPS=1 swift test --filter BuildServerIntegrationTests.XcodeBuildServerTests/testPreparePopulatesIndexStore`
Expected: PASS (macOS+Xcode) / SKIPPED otherwise.

- [ ] **Step 6: Commit**

```bash
git add Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift
git commit -m "test(BuildServerIntegration): XcodeBuildServer integration tests

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: Non-regression check for SwiftPM detection

**Files:**
- Modify: `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift`

- [ ] **Step 1: Write the test**

A directory with only `Package.swift` (no `.xcodeproj`) must NOT be claimed by the Xcode detector.

```swift
func testSwiftPMProjectNotClaimedByXcode() throws {
  let dir = try temporaryDirectory()
  try "// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: \"P\")\n"
    .write(to: dir.appending(component: "Package.swift"), atomically: true, encoding: .utf8)
  XCTAssertNil(XcodeBuildServer.searchForConfig(in: dir, options: SourceKitLSPOptions()))
}
```

- [ ] **Step 2: Run it**

Run: `SWIFTCI_USE_LOCAL_DEPS=1 swift test --filter BuildServerIntegrationTests.XcodeBuildServerTests/testSwiftPMProjectNotClaimedByXcode`
Expected: PASS.

- [ ] **Step 3: Run the full module test suite**

Run: `SWIFTCI_USE_LOCAL_DEPS=1 swift test --filter BuildServerIntegrationTests`
Expected: all existing tests still PASS (no SwiftPM-detection regression).

- [ ] **Step 4: Commit**

```bash
git add Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift
git commit -m "test(BuildServerIntegration): SwiftPM detection non-regression

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Definition of Done

- `swift build` succeeds with the new `swift-build` dependency.
- A directory containing `MyApp.xcodeproj` (no `Package.swift`) is detected as `.xcode`; `.xcworkspace` wins over `.xcodeproj`; explicit `buildServer.json` still wins overall; SwiftPM-only projects are unaffected.
- On macOS with Xcode: opening a source file in an `.xcodeproj` yields compiler arguments containing an `-sdk`/`-target`; `buildTargetSources` lists the project's sources; `prepare` populates an index store.
- `xcode` options (`container`, `scheme`, `configuration`, `destination`) are documented in `config.schema.json` and override the defaults.
- All Xcode code is behind `#if !NO_SWIFTPM_DEPENDENCY` and degrades gracefully (declines detection) when `xcodebuild` is absent.

## Known risks / verify-at-implementation

- **SwiftBuild API shapes** (`SWBWorkspaceInfo` fields, `SWBRunDestinationInfo` constructors, `SWBArenaInfo` members, build-operation methods, `sourceFileBuildInfos` keys): confirmed by source reading but not compiled. Task 5 + Task 9 are the reconciliation points; only `SwiftBuildSession.swift` should need changes.
- **`project.pbxproj` fixture** (Task 8): use a known-good template captured from a real Xcode "Command Line Tool" project.
- **Destination inference** for iOS/tvOS/watchOS: default is macOS + config override; per-platform simulator inference is a contained follow-up inside `SwiftBuildSession.runDestination(for:)`.
