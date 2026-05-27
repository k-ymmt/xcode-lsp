# Xcode Dependency Graph Exposure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose Xcode target dependency information to BSP by tagging SwiftPM-package targets with `.dependency` (gap #4) and populating `BuildTarget.dependencies` with direct upstream edges (gap #5).

**Architecture:** Add two SwiftBuild queries to `SwiftBuildSession` (`PROJECT_FILE_PATH` per-target macro evaluation and a direct-dependency adjacency list via `computeDependencyGraph`), keep all `import SwiftBuild` usage inside `SwiftBuildSession`, and do the classification in `XcodeBuildServer` through `import SwiftBuild`-free pure functions (mirroring the existing `isTestProductType` / `resolveScheme` pattern). `XcodeBuildServer.buildTargets()` then attaches `.dependency` tags and `dependencies` edges.

**Tech Stack:** Swift, SwiftPM, swift-build (SwiftBuild engine), BuildServerProtocol (BSP), XCTest, real `xcodebuild` (Xcode 26.4) for integration tests.

**Build/test command (per repo memory):** prefix every `swift` invocation with `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer`. `SWIFTCI_USE_LOCAL_DEPS=1` does NOT work in this checkout (missing sibling checkouts); use remote dependencies + the Xcode 26.4 toolchain.

**Reference spec:** `docs/superpowers/specs/2026-05-27-xcode-dependency-graph-design.md`

---

## File Structure

- `Sources/BuildServerIntegration/SwiftBuildSession.swift` — add `XcodeTarget.projectFilePath`; add `projectFilePath(forTargetGUID:)` and populate it in `targets()`; add `dependencyGraph(forTargetGUIDs:)` wrapper. (All SwiftBuild-facing.)
- `Sources/BuildServerIntegration/XcodeBuildServer.swift` — add pure `isPartOfRootProject(projectFilePath:rootProjectPaths:)` and `dependencyIdentifiers(forTargetGUID:graph:scopedGUIDs:)`; add private `rootProjectPaths()`; rewrite `buildTargets()` to attach `.dependency` tags and `dependencies` edges.
- `Sources/SKTestSupport/XcodeTestProject.swift` — add `.appWithPackageDependency` fixture kind (Task 6 only).
- `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift` — add unit tests (pure functions) and integration tests (gated by `skipUnlessXcodeAvailable()` + `#if !NO_SWIFTPM_DEPENDENCY`).

---

## Task 1: `XcodeTarget.projectFilePath` field + `isPartOfRootProject` pure function

**Files:**
- Modify: `Sources/BuildServerIntegration/SwiftBuildSession.swift:26-42` (`XcodeTarget`)
- Modify: `Sources/BuildServerIntegration/XcodeBuildServer.swift` (add to the `extension XcodeBuildServer` that holds `resolveScheme`, near `:298`)
- Test: `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift` (new `// MARK: - isPartOfRootProject classification` section)

- [ ] **Step 1: Add the `projectFilePath` stored property to `XcodeTarget`**

Replace the `XcodeTarget` struct body (`SwiftBuildSession.swift:26-42`) with:

```swift
package struct XcodeTarget: Sendable, Equatable {
  package var guid: String
  package var name: String
  /// Supported platform names (e.g. "macosx", "iphonesimulator"). Empty if unknown.
  package var platforms: [String]
  /// Whether this target builds a test bundle (unit-test or UI-testing product type).
  package var isTestTarget: Bool
  /// Absolute path of the `.xcodeproj` that owns this target (from `PROJECT_FILE_PATH`). `nil` if
  /// the build setting could not be evaluated. Used to classify the target as part of the opened
  /// project vs. a dependency (e.g. a SwiftPM package).
  package var projectFilePath: URL?

  // `isTestTarget` and `projectFilePath` default so existing call sites that don't care about them
  // (e.g. the `resolveScheme` unit tests in `XcodeBuildServerTests.swift`) compile unchanged.
  package init(
    guid: String,
    name: String,
    platforms: [String],
    isTestTarget: Bool = false,
    projectFilePath: URL? = nil
  ) {
    self.guid = guid
    self.name = name
    self.platforms = platforms
    self.isTestTarget = isTestTarget
    self.projectFilePath = projectFilePath
  }
}
```

- [ ] **Step 2: Write the failing unit tests for `isPartOfRootProject`**

Add to `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift`, immediately after the `// MARK: - isTestProductType classification` block (after line 203, before the `temporaryDirectory()` helper). These reference `XcodeBuildServer`, which is only compiled when SwiftPM is available, so they MUST sit INSIDE the existing `#if !NO_SWIFTPM_DEPENDENCY` block (opened at `:29`, closed at `:498`) — the same region as the `resolveScheme`/`isTestProductType` unit tests. Line 203 is already inside that block, so placing them there is correct:

```swift
  // MARK: - isPartOfRootProject classification

  func testRootProjectTargetIsPartOfRootProject() {
    let container = URL(fileURLWithPath: "/proj/MyApp.xcodeproj")
    XCTAssertTrue(
      XcodeBuildServer.isPartOfRootProject(projectFilePath: container, rootProjectPaths: [container])
    )
  }

  func testPackageDependencyTargetIsNotPartOfRootProject() {
    let container = URL(fileURLWithPath: "/proj/MyApp.xcodeproj")
    let package = URL(
      fileURLWithPath: "/proj/.build/sourcekit-lsp-xcode/SourcePackages/checkouts/Pkg/Pkg.xcodeproj"
    )
    XCTAssertFalse(
      XcodeBuildServer.isPartOfRootProject(projectFilePath: package, rootProjectPaths: [container])
    )
  }

  func testNilProjectFilePathIsTreatedAsRootProject() {
    let container = URL(fileURLWithPath: "/proj/MyApp.xcodeproj")
    XCTAssertTrue(
      XcodeBuildServer.isPartOfRootProject(projectFilePath: nil, rootProjectPaths: [container])
    )
  }

  func testWorkspaceMemberProjectIsPartOfRootProject() {
    let appProject = URL(fileURLWithPath: "/proj/AppA.xcodeproj")
    let libProject = URL(fileURLWithPath: "/proj/LibB.xcodeproj")
    XCTAssertTrue(
      XcodeBuildServer.isPartOfRootProject(projectFilePath: libProject, rootProjectPaths: [appProject, libProject])
    )
  }
```

- [ ] **Step 3: Run the tests to verify they fail to compile**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift build --target BuildServerIntegration`
Expected: FAIL — `XcodeBuildServer` has no member `isPartOfRootProject`.

- [ ] **Step 4: Implement `isPartOfRootProject`**

Add inside the `extension XcodeBuildServer { ... }` that defines `resolveScheme` (the `import SwiftBuild`-free extension around `XcodeBuildServer.swift:298`):

```swift
  /// Whether a target whose owning `.xcodeproj` is `projectFilePath` belongs to the project the user
  /// opened (vs. a dependency such as a SwiftPM package, whose project lives outside the opened
  /// container). A `nil` path (evaluation failed) is treated conservatively as part of the root
  /// project so its sources are not wrongly excluded from project/test discovery.
  package static func isPartOfRootProject(projectFilePath: URL?, rootProjectPaths: Set<URL>) -> Bool {
    guard let projectFilePath else {
      return true
    }
    func normalized(_ url: URL) -> String {
      url.resolvingSymlinksInPath().standardizedFileURL.path
    }
    let target = normalized(projectFilePath)
    return rootProjectPaths.contains { normalized($0) == target }
  }
```

- [ ] **Step 5: Run the unit tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter "XcodeBuildServerTests/test.*PartOfRootProject"`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/BuildServerIntegration/SwiftBuildSession.swift Sources/BuildServerIntegration/XcodeBuildServer.swift Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift
git commit -m "feat(BuildServerIntegration): isPartOfRootProject classifier + XcodeTarget.projectFilePath

Task context: Xcode dependency-graph (#4) — pure root-vs-dependency classifier
and the projectFilePath field it consumes.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 2: `dependencyIdentifiers` pure function

**Files:**
- Modify: `Sources/BuildServerIntegration/XcodeBuildServer.swift` (same `resolveScheme` extension)
- Test: `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift` (new `// MARK: - dependencyIdentifiers` section)

- [ ] **Step 1: Write the failing unit tests**

Add after the `isPartOfRootProject` tests from Task 1 (still inside the `#if !NO_SWIFTPM_DEPENDENCY` block):

```swift
  // MARK: - dependencyIdentifiers

  func testDependencyIdentifiersFiltersOutOfScopeGUIDs() throws {
    let graph = ["G_App": ["G_Fw", "G_External"]]
    let ids = try XcodeBuildServer.dependencyIdentifiers(
      forTargetGUID: "G_App",
      graph: graph,
      scopedGUIDs: ["G_App", "G_Fw"]
    )
    XCTAssertEqual(try ids.map(\.xcodeTargetGUID), ["G_Fw"])
  }

  func testDependencyIdentifiersAreSortedForDeterminism() throws {
    let graph = ["G_App": ["G_Z", "G_A"]]
    let ids = try XcodeBuildServer.dependencyIdentifiers(
      forTargetGUID: "G_App",
      graph: graph,
      scopedGUIDs: ["G_A", "G_Z"]
    )
    XCTAssertEqual(try ids.map(\.xcodeTargetGUID), ["G_A", "G_Z"])
  }

  func testDependencyIdentifiersEmptyWhenNoEntry() throws {
    let ids = try XcodeBuildServer.dependencyIdentifiers(
      forTargetGUID: "G_Unknown",
      graph: [:],
      scopedGUIDs: ["G_App"]
    )
    XCTAssertTrue(ids.isEmpty)
  }
```

- [ ] **Step 2: Run the tests to verify they fail to compile**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift build --target BuildServerIntegration`
Expected: FAIL — `XcodeBuildServer` has no member `dependencyIdentifiers`.

- [ ] **Step 3: Implement `dependencyIdentifiers`**

Add to the same `resolveScheme` extension:

```swift
  /// The BSP identifiers of `guid`'s direct dependencies, restricted to targets in `scopedGUIDs` so we
  /// never reference a target outside the build server's target list (e.g. when a scheme has scoped the
  /// workspace to a subset). Sorted by GUID for deterministic output.
  package static func dependencyIdentifiers(
    forTargetGUID guid: String,
    graph: [String: [String]],
    scopedGUIDs: Set<String>
  ) throws -> [BuildTargetIdentifier] {
    let direct = (graph[guid] ?? []).filter { scopedGUIDs.contains($0) }.sorted()
    return try direct.map { try BuildTargetIdentifier.createXcode(targetGUID: $0) }
  }
```

- [ ] **Step 4: Run the unit tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter "XcodeBuildServerTests/testDependencyIdentifiers"`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/BuildServerIntegration/XcodeBuildServer.swift Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift
git commit -m "feat(BuildServerIntegration): dependencyIdentifiers (scope-filtered direct deps)

Task context: Xcode dependency-graph (#5) — pure mapping from a direct-dependency
adjacency list to scope-filtered BSP identifiers.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 3: Populate `XcodeTarget.projectFilePath` via `PROJECT_FILE_PATH`

**Files:**
- Modify: `Sources/BuildServerIntegration/SwiftBuildSession.swift:138-149` (`targets()`) and add helper near `:174-204`
- Test: `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift` (integration section)

- [ ] **Step 1: Write the failing integration test**

Add in the integration-test region (inside `#if !NO_SWIFTPM_DEPENDENCY`, after `testMacOSTargetReportsMacosxPlatform`, around line 422). This exercises `SwiftBuildSession.targets()` directly because `projectFilePath` is not surfaced through the BSP response:

```swift
  /// A real target reports its owning `.xcodeproj` via `PROJECT_FILE_PATH`, proving the macro
  /// evaluation that drives `.dependency` classification works end-to-end against real SwiftBuild.
  func testTargetReportsOwningProjectFilePath() async throws {
    try skipUnlessXcodeAvailable()

    let project = try XcodeTestProject(sourceContents: "print(\"hi\")\n")
    defer { project.keepAlive() }

    let session = try await SwiftBuildSession(
      containerPath: project.xcodeprojURL,
      configuration: "Debug",
      destinationOverride: nil,
      derivedDataPath: project.projectRoot.appending(component: ".build").appending(component: "sk-xcode")
    )
    addTeardownBlock { await session.close() }

    let targets = try await session.targets()
    let target = try XCTUnwrap(targets.first, "expected at least one target")
    let path = try XCTUnwrap(
      target.projectFilePath,
      "expected projectFilePath to be populated via PROJECT_FILE_PATH evaluation"
    )
    XCTAssertEqual(
      path.lastPathComponent,
      "MyApp.xcodeproj",
      "expected owning project to be MyApp.xcodeproj, got \(path.path)"
    )
  }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter "XcodeBuildServerTests/testTargetReportsOwningProjectFilePath"`
Expected: FAIL — `target.projectFilePath` is `nil` (never populated), so `XCTUnwrap` throws.

- [ ] **Step 3: Add the `projectFilePath(forTargetGUID:)` helper**

Add to `SwiftBuildSession.swift` right after `isTestTarget(forTargetGUID:)` (after `:204`):

```swift
  /// Evaluate the target's `PROJECT_FILE_PATH` build setting: the absolute path of the `.xcodeproj`
  /// that owns the target. Used to classify a target as part of the opened project vs. a dependency
  /// (e.g. a SwiftPM package, whose project lives under `…/SourcePackages/…`).
  ///
  /// `PROJECT_FILE_PATH` does not depend on the active run destination, so this evaluates with build
  /// parameters that set only the configuration. Returns `nil` on failure so the target is treated
  /// conservatively as part of the root project.
  private func projectFilePath(forTargetGUID guid: String) async -> URL? {
    var params = SWBBuildParameters()
    params.configurationName = configuration
    let path = await orLog("Evaluating PROJECT_FILE_PATH for target \(guid)") {
      try await session.evaluateMacroAsString(
        "PROJECT_FILE_PATH",
        level: .target(guid),
        buildParameters: params,
        overrides: [:]
      )
    }
    guard let path, !path.isEmpty else {
      return nil
    }
    return URL(fileURLWithPath: path)
  }
```

- [ ] **Step 4: Populate `projectFilePath` in `targets()`**

Replace the loop body in `targets()` (`SwiftBuildSession.swift:141-147`) with:

```swift
    for targetInfo in info.targetInfos {
      let platforms = await supportedPlatforms(forTargetGUID: targetInfo.guid)
      let isTest = await isTestTarget(forTargetGUID: targetInfo.guid)
      let projectFilePath = await projectFilePath(forTargetGUID: targetInfo.guid)
      result.append(
        XcodeTarget(
          guid: targetInfo.guid,
          name: targetInfo.targetName,
          platforms: platforms,
          isTestTarget: isTest,
          projectFilePath: projectFilePath
        )
      )
    }
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter "XcodeBuildServerTests/testTargetReportsOwningProjectFilePath"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/BuildServerIntegration/SwiftBuildSession.swift Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift
git commit -m "feat(BuildServerIntegration): evaluate PROJECT_FILE_PATH per target

Task context: Xcode dependency-graph (#4) — populate XcodeTarget.projectFilePath
so buildTargets() can classify package dependencies.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 4: Attach `.dependency` tags in `buildTargets()`

**Files:**
- Modify: `Sources/BuildServerIntegration/XcodeBuildServer.swift:140-156` (`buildTargets()`) and add private `rootProjectPaths()` in the actor body (near the `// MARK: Caching` helpers, around `:74-136`)
- Test: `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift` (integration section)

- [ ] **Step 1: Write the failing integration test (negative case)**

Add after `testTestTargetIsTaggedAsTest` (around line 497, still inside `#if !NO_SWIFTPM_DEPENDENCY`):

```swift
  /// Both targets of `.appWithFrameworkDependency` live in the opened `MyApp.xcodeproj`, so neither
  /// is tagged `.dependency`. Also proves `PROJECT_FILE_PATH` classification is wired into buildTargets.
  func testInProjectTargetsAreNotTaggedDependency() async throws {
    try skipUnlessXcodeAvailable()

    let project = try XcodeTestProject(kind: .appWithFrameworkDependency, sourceContents: "let x = 1\n")
    defer { project.keepAlive() }

    let buildServer = try await XcodeBuildServer(
      projectRoot: project.projectRoot,
      containerPath: project.xcodeprojURL,
      toolchainRegistry: .forTesting,
      options: SourceKitLSPOptions(),
      connectionToSourceKitLSP: LocalConnection(receiverName: "Dummy SourceKit-LSP")
    )
    addTeardownBlock { await buildServer.close() }

    let response = try await buildServer.buildTargets(request: WorkspaceBuildTargetsRequest())
    XCTAssertFalse(response.targets.isEmpty, "expected at least one target")
    for target in response.targets {
      XCTAssertFalse(
        target.tags.contains(.dependency),
        "expected in-project target \(target.displayName ?? "?") to NOT be tagged .dependency, got \(target.tags)"
      )
    }
  }
```

- [ ] **Step 2: Run the test to verify it fails to compile (no wiring yet)**

The negative assertion would pass trivially today (no `.dependency` is ever attached), so this step verifies the *new code path compiles and still keeps the assertion green* — it becomes a meaningful regression guard once tagging exists. Run after implementing Steps 3-4. First confirm the test compiles and currently passes against the pre-change binary:

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter "XcodeBuildServerTests/testInProjectTargetsAreNotTaggedDependency"`
Expected: PASS (trivially, before wiring). Proceed to add the wiring; it must remain PASS afterwards.

- [ ] **Step 3: Add the `rootProjectPaths()` helper**

Add to the `XcodeBuildServer` actor body, right after `invalidateCaches()` (`:133-136`):

```swift
  /// The set of `.xcodeproj` paths considered part of the project the user opened: the container itself
  /// for an `.xcodeproj`, or the member `.xcodeproj`s directly under `projectRoot` for an `.xcworkspace`.
  /// A target whose owning project is outside this set (e.g. a SwiftPM package) is tagged `.dependency`.
  private func rootProjectPaths() -> Set<URL> {
    if containerPath.pathExtension == "xcworkspace" {
      let entries =
        (try? FileManager.default.contentsOfDirectory(at: projectRoot, includingPropertiesForKeys: nil)) ?? []
      return Set(entries.filter { $0.pathExtension == "xcodeproj" })
    }
    return [containerPath]
  }
```

- [ ] **Step 4: Rewrite `buildTargets()` to attach `.dependency` tags**

Replace `buildTargets()` (`XcodeBuildServer.swift:140-156`) with the following. (This task only adds the tag; `dependencies` stays `[]` and is filled in Task 5.)

```swift
  package func buildTargets(request: WorkspaceBuildTargetsRequest) async throws -> WorkspaceBuildTargetsResponse {
    let targets = try await allTargets()
    let rootPaths = rootProjectPaths()
    let buildTargets = try targets.map { (target) -> BuildTarget in
      var tags: [BuildTargetTag] = []
      if target.isTestTarget {
        tags.append(.test)
      }
      if !Self.isPartOfRootProject(projectFilePath: target.projectFilePath, rootProjectPaths: rootPaths) {
        tags.append(.dependency)
      }
      return BuildTarget(
        id: try BuildTargetIdentifier.createXcode(targetGUID: target.guid),
        displayName: target.name,
        tags: tags,
        capabilities: BuildTargetCapabilities(),
        // Be conservative with the languages that might be used in the target. SourceKit-LSP doesn't use this property.
        languageIds: [.c, .cpp, .objective_c, .objective_cpp, .swift],
        dependencies: [],
        dataKind: .sourceKit,
        // SwiftBuild resolves the toolchain internally, so no explicit toolchain URI is provided.
        data: SourceKitBuildTarget(toolchain: nil).encodeToLSPAny()
      )
    }
    return WorkspaceBuildTargetsResponse(targets: buildTargets)
  }
```

- [ ] **Step 5: Run the test (and the existing `.test`-tag test) to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter "XcodeBuildServerTests/testInProjectTargetsAreNotTaggedDependency|XcodeBuildServerTests/testTestTargetIsTaggedAsTest"`
Expected: PASS (2 tests) — confirms `.dependency` is not over-applied and `.test` still works.

- [ ] **Step 6: Commit**

```bash
git add Sources/BuildServerIntegration/XcodeBuildServer.swift Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift
git commit -m "feat(BuildServerIntegration): tag dependency-project targets with .dependency

Task context: Xcode dependency-graph (#4) — buildTargets() classifies each target
by owning project and tags out-of-project (package) targets .dependency.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 5: Populate `BuildTarget.dependencies` via `computeDependencyGraph`

**Files:**
- Modify: `Sources/BuildServerIntegration/SwiftBuildSession.swift` (add `dependencyGraph(forTargetGUIDs:)` after `dependencyClosure`, near `:156-167`)
- Modify: `Sources/BuildServerIntegration/XcodeBuildServer.swift:140-...` (`buildTargets()` — fill `dependencies`)
- Test: `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift` (integration section)

- [ ] **Step 1: Write the failing integration test (#5 edge)**

Add after `testInProjectTargetsAreNotTaggedDependency`:

```swift
  /// `.appWithFrameworkDependency`'s App target depends on Framework, so App's BSP `dependencies`
  /// includes Framework's identifier. Proves `computeDependencyGraph` is wired end-to-end.
  func testDependenciesExposeFrameworkEdge() async throws {
    try skipUnlessXcodeAvailable()

    let project = try XcodeTestProject(kind: .appWithFrameworkDependency, sourceContents: "let x = 1\n")
    defer { project.keepAlive() }

    let buildServer = try await XcodeBuildServer(
      projectRoot: project.projectRoot,
      containerPath: project.xcodeprojURL,
      toolchainRegistry: .forTesting,
      options: SourceKitLSPOptions(),
      connectionToSourceKitLSP: LocalConnection(receiverName: "Dummy SourceKit-LSP")
    )
    addTeardownBlock { await buildServer.close() }

    let response = try await buildServer.buildTargets(request: WorkspaceBuildTargetsRequest())
    let app = try XCTUnwrap(
      response.targets.first { $0.displayName == "App" },
      "expected App target, got \(response.targets.map(\.displayName))"
    )
    let framework = try XCTUnwrap(
      response.targets.first { $0.displayName == "Framework" },
      "expected Framework target, got \(response.targets.map(\.displayName))"
    )
    XCTAssertTrue(
      app.dependencies.contains(framework.id),
      "expected App.dependencies to include Framework, got \(app.dependencies)"
    )
  }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter "XcodeBuildServerTests/testDependenciesExposeFrameworkEdge"`
Expected: FAIL — `app.dependencies` is empty (still `[]` from Task 4), so `contains` is false.

- [ ] **Step 3: Add the `dependencyGraph(forTargetGUIDs:)` wrapper**

Add to `SwiftBuildSession.swift` right after `dependencyClosure(forTargetGUIDs:)` (after `:167`):

```swift
  /// Compute the direct-dependency adjacency list (including implicit dependencies) for the given
  /// target GUIDs, as `targetGUID -> [direct dependency GUID]`. Used to populate `BuildTarget.dependencies`.
  ///
  /// Unlike `dependencyClosure(forTargetGUIDs:)`, which returns the transitive closure, this returns
  /// only direct edges, matching BSP's "direct upstream build target dependencies" semantics. The graph
  /// does not depend on the run destination, so build parameters set only the configuration.
  package func dependencyGraph(forTargetGUIDs guids: [String]) async throws -> [String: [String]] {
    guard !guids.isEmpty else {
      return [:]
    }
    var params = SWBBuildParameters()
    params.configurationName = configuration
    let adjacency = try await session.computeDependencyGraph(
      targetGUIDs: guids.map { SWBTargetGUID(rawValue: $0) },
      buildParameters: params,
      includeImplicitDependencies: true
    )
    var result: [String: [String]] = [:]
    for (key, values) in adjacency {
      result[key.rawValue] = values.map(\.rawValue)
    }
    return result
  }
```

- [ ] **Step 4: Fill `dependencies` in `buildTargets()`**

Replace `buildTargets()` (the Task 4 version) with the final version that fetches the graph once and fills `dependencies`:

```swift
  package func buildTargets(request: WorkspaceBuildTargetsRequest) async throws -> WorkspaceBuildTargetsResponse {
    let targets = try await allTargets()
    let rootPaths = rootProjectPaths()
    let scopedGUIDs = Set(targets.map(\.guid))
    let graph = try await session.dependencyGraph(forTargetGUIDs: targets.map(\.guid))
    let buildTargets = try targets.map { (target) -> BuildTarget in
      var tags: [BuildTargetTag] = []
      if target.isTestTarget {
        tags.append(.test)
      }
      if !Self.isPartOfRootProject(projectFilePath: target.projectFilePath, rootProjectPaths: rootPaths) {
        tags.append(.dependency)
      }
      return BuildTarget(
        id: try BuildTargetIdentifier.createXcode(targetGUID: target.guid),
        displayName: target.name,
        tags: tags,
        capabilities: BuildTargetCapabilities(),
        // Be conservative with the languages that might be used in the target. SourceKit-LSP doesn't use this property.
        languageIds: [.c, .cpp, .objective_c, .objective_cpp, .swift],
        dependencies: try Self.dependencyIdentifiers(
          forTargetGUID: target.guid,
          graph: graph,
          scopedGUIDs: scopedGUIDs
        ),
        dataKind: .sourceKit,
        // SwiftBuild resolves the toolchain internally, so no explicit toolchain URI is provided.
        data: SourceKitBuildTarget(toolchain: nil).encodeToLSPAny()
      )
    }
    return WorkspaceBuildTargetsResponse(targets: buildTargets)
  }
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter "XcodeBuildServerTests/testDependenciesExposeFrameworkEdge"`
Expected: PASS.

If it fails because the edge is reported only on the dynamic target variant (some product types split into a configured + dynamic target), log `app.dependencies` and `graph` and confirm the Framework GUID matches a target in `scopedGUIDs`; the adjacency key/value GUIDs come straight from `workspaceInfo().targetInfos`, so they must align. Adjust the assertion only if SwiftBuild genuinely reports the edge under a different target name (document the finding in the commit).

- [ ] **Step 6: Commit**

```bash
git add Sources/BuildServerIntegration/SwiftBuildSession.swift Sources/BuildServerIntegration/XcodeBuildServer.swift Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift
git commit -m "feat(BuildServerIntegration): populate BuildTarget.dependencies from SwiftBuild

Task context: Xcode dependency-graph (#5) — expose direct dependency edges via
computeDependencyGraph so SourceKit-LSP can order target preparation.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 6: `.appWithPackageDependency` fixture + positive `.dependency` integration test

> This is the heaviest task: it requires a valid `project.pbxproj` that references a local SwiftPM
> package. Per repo convention, fixture `pbxproj` templates are byte-validated against real Xcode 26.4.
> The Package.swift, source layout, init wiring, and test below are exact; the `project.pbxproj` template
> is produced/validated via the loop in Steps 4-6 (the same way every existing template in this file was
> created). **Escape hatch:** if a valid package `pbxproj` cannot be produced in this session, the pure
> `isPartOfRootProject` unit tests (Task 1, with a `SourcePackages` path) plus the negative integration
> test (Task 4) already cover the classifier; in that case, leave this task's test `XCTSkip`-guarded with
> a `// TODO(followup): real package-dependency fixture` and record the blocker in the commit body. Do
> NOT block the merge of Tasks 1-5 on this task.

**Files:**
- Modify: `Sources/SKTestSupport/XcodeTestProject.swift` (new `Kind` case, new template, init wiring)
- Test: `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift` (integration section)

- [ ] **Step 1: Add the `Kind` case**

In `XcodeTestProject.swift`, add to the `Kind` enum (`:44-55`), after `appWithUnitTestTarget`:

```swift
    /// A macOS command-line tool `MyApp` (with `main.swift` importing `MyLib`) that depends on a local
    /// SwiftPM package `MyPackage` exposing a library product `MyLib`. Exercises `.dependency` tagging.
    case appWithPackageDependency
```

- [ ] **Step 2: Write the failing integration test (#4 positive)**

Add after `testDependenciesExposeFrameworkEdge` in `XcodeBuildServerTests.swift`:

```swift
  /// A target built from a SwiftPM package dependency (`MyLib`) is tagged `.dependency`, while the
  /// opened project's own target (`MyApp`) is not. This is the direct regression test for gap #4.
  func testPackageDependencyTargetIsTaggedDependency() async throws {
    try skipUnlessXcodeAvailable()

    let project = try XcodeTestProject(kind: .appWithPackageDependency, sourceContents: "import MyLib\nlet x = 1\n")
    defer { project.keepAlive() }

    let buildServer = try await XcodeBuildServer(
      projectRoot: project.projectRoot,
      containerPath: project.xcodeprojURL,
      toolchainRegistry: .forTesting,
      options: SourceKitLSPOptions(),
      connectionToSourceKitLSP: LocalConnection(receiverName: "Dummy SourceKit-LSP")
    )
    addTeardownBlock { await buildServer.close() }

    let response = try await buildServer.buildTargets(request: WorkspaceBuildTargetsRequest())
    let names = response.targets.map { $0.displayName ?? "?" }
    let packageTarget = try XCTUnwrap(
      response.targets.first { $0.displayName == "MyLib" },
      "expected a MyLib package-product target, got \(names)"
    )
    let appTarget = try XCTUnwrap(
      response.targets.first { $0.displayName == "MyApp" },
      "expected a MyApp target, got \(names)"
    )
    XCTAssertTrue(
      packageTarget.tags.contains(.dependency),
      "expected MyLib (SwiftPM package) to be tagged .dependency, got \(packageTarget.tags)"
    )
    XCTAssertFalse(
      appTarget.tags.contains(.dependency),
      "expected MyApp (root project) to NOT be tagged .dependency, got \(appTarget.tags)"
    )
  }
```

- [ ] **Step 3: Add the init wiring + local package sources**

In `init` (`:1024-1098`), extend the `sourceFileURL` switch (`:1044-1052`) so `.appWithPackageDependency` keeps `main.swift` at the project root:

```swift
    case .macOSCommandLineTool, .iOSApp, .appWithUnitTestTarget, .appWithPackageDependency:
      self.sourceFileURL = root.appendingPathComponent("main.swift", isDirectory: false)
```

Extend the `template` switch (`:1056-1061`):

```swift
    case .appWithPackageDependency: template = Self.appWithPackageDependencyPbxprojTemplate
```

Add, after the `.appWithUnitTestTarget` block (after `:1097`), the local-package emission:

```swift
    if case .appWithPackageDependency = kind {
      let packageRoot = root.appendingPathComponent("MyPackage", isDirectory: true)
      let libSourceDir = packageRoot.appendingPathComponent("Sources/MyLib", isDirectory: true)
      try fileManager.createDirectory(at: libSourceDir, withIntermediateDirectories: true)
      try """
        // swift-tools-version:5.9
        import PackageDescription

        let package = Package(
          name: "MyPackage",
          products: [.library(name: "MyLib", targets: ["MyLib"])],
          targets: [.target(name: "MyLib")]
        )
        """
        .write(to: packageRoot.appendingPathComponent("Package.swift", isDirectory: false), atomically: true, encoding: .utf8)
      try "public func myLibEntry() {}\n"
        .write(to: libSourceDir.appendingPathComponent("MyLib.swift", isDirectory: false), atomically: true, encoding: .utf8)
    }
```

- [ ] **Step 4: Create and validate the `project.pbxproj` template**

Build a real reference project once, then paste its validated `project.pbxproj` into a new
`appWithPackageDependencyPbxprojTemplate` static (mirror the doc-comment style of the existing templates,
e.g. `:67`). The project must contain:

- A native target `MyApp` (macOS command-line tool) with `main.swift` (path relative to project root).
- An `XCLocalSwiftPackageReference` with `relativePath = "MyPackage"`.
- An `XCSwiftPackageProductDependency` for product `MyLib`, listed in `MyApp`'s
  `packageProductDependencies` and linked in its Frameworks build phase.
- The `XCLocalSwiftPackageReference` listed in the `PBXProject`'s `packageReferences`.

Recipe to generate the validated bytes (run in a scratch dir on the Xcode 26.4 host):

```bash
export DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer
# 1. Create MyPackage (Package.swift + Sources/MyLib/MyLib.swift) exactly as in Step 3.
# 2. In Xcode: New Project > macOS > Command Line Tool named "MyApp" at the scratch root.
#    File > Add Package Dependencies > Add Local... > select MyPackage; add MyLib to MyApp.
# 3. Validate:
plutil -lint MyApp.xcodeproj/project.pbxproj          # expect: OK
xcodebuild -list -project MyApp.xcodeproj             # expect: lists the MyApp target/scheme
xcodebuild -dumpPIF -project MyApp.xcodeproj >/dev/null && echo dumpPIF-ok
```

Paste the validated `project.pbxproj` content verbatim into the new static, replacing any absolute paths
with project-relative paths. Keep `main.swift` at the project root and `relativePath = "MyPackage"`.

- [ ] **Step 5: Run the integration test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter "XcodeBuildServerTests/testPackageDependencyTargetIsTaggedDependency"`
Expected: PASS — `MyLib` is tagged `.dependency`; `MyApp` is not.

If `MyLib` does not appear as a target, log `response.targets.map(\.displayName)` — SwiftBuild may name
the package product target differently (e.g. `MyLib` vs `MyPackage`); adjust the lookup string to the
observed product-target name and document it in the commit body.

- [ ] **Step 6: Commit**

```bash
git add Sources/SKTestSupport/XcodeTestProject.swift Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift
git commit -m "test(BuildServerIntegration): package-dependency fixture asserts .dependency tag

Task context: Xcode dependency-graph (#4) — end-to-end proof that a SwiftPM package
product target is tagged .dependency while the opened project's target is not.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Final Verification

- [ ] **Run the full BuildServerIntegrationTests suite (non-regression):**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter BuildServerIntegrationTests`
Expected: all pass (existing tests + new unit/integration tests; integration tests run because Xcode 26.4 is available).

- [ ] **Confirm Definition of Done (from the spec):**
  - `SwiftBuildSession` returns `projectFilePath` per target (Task 3) and a direct-dependency graph (Task 5).
  - `buildTargets()` tags package targets `.dependency` (Task 4) and fills `dependencies` (Task 5).
  - `isPartOfRootProject` / `dependencyIdentifiers` unit tests pass in all environments (Tasks 1-2).
  - #4 (package fixture) and #5 (framework edge) integration tests pass on macOS + Xcode (Tasks 5-6).
  - Existing `BuildServerIntegrationTests` pass non-regressed.
