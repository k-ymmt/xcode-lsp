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
@_spi(SourceKitLSP) import BuildServerProtocol
import Foundation
@_spi(SourceKitLSP) import LanguageServerProtocol
@_spi(SourceKitLSP) import LanguageServerProtocolTransport
import SKOptions
import SKTestSupport
import ToolchainRegistry
import XCTest

final class XcodeBuildServerTests: XCTestCase {
  func testXcodeTargetIdentifierRoundTrip() throws {
    let id = try BuildTargetIdentifier.createXcode(targetGUID: "T1::TARGET@v1")
    XCTAssertEqual(try id.xcodeTargetGUID, "T1::TARGET@v1")
  }

  #if !NO_SWIFTPM_DEPENDENCY
  func testDetectsXcodeproj() throws {
    let dir = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: dir.appendingPathComponent("MyApp.xcodeproj"),
      withIntermediateDirectories: true
    )
    let spec = XcodeBuildServer.searchForConfig(in: dir, options: SourceKitLSPOptions())
    XCTAssertEqual(spec?.configPath.lastPathComponent, "MyApp.xcodeproj")
  }

  func testPrefersXcworkspaceOverXcodeproj() throws {
    let dir = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: dir.appendingPathComponent("MyApp.xcodeproj"),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: dir.appendingPathComponent("MyApp.xcworkspace"),
      withIntermediateDirectories: true
    )
    let spec = XcodeBuildServer.searchForConfig(in: dir, options: SourceKitLSPOptions())
    XCTAssertEqual(spec?.configPath.pathExtension, "xcworkspace")
  }

  func testNoXcodeContainerReturnsNil() throws {
    let dir = try temporaryDirectory()
    XCTAssertNil(XcodeBuildServer.searchForConfig(in: dir, options: SourceKitLSPOptions()))
  }

  func testSwiftPMProjectNotClaimedByXcode() throws {
    let dir = try temporaryDirectory()
    try "// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: \"P\")\n"
      .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    XCTAssertNil(XcodeBuildServer.searchForConfig(in: dir, options: SourceKitLSPOptions()))
  }

  // MARK: - preferredPlatform selection logic

  func testPreferredPlatformMacOnly() {
    XCTAssertEqual(SwiftBuildSession.preferredPlatform(forSupportedPlatforms: ["macosx"]), "macosx")
  }

  func testPreferredPlatformIOSPrefersSimulator() {
    XCTAssertEqual(
      SwiftBuildSession.preferredPlatform(forSupportedPlatforms: ["iphoneos", "iphonesimulator"]),
      "iphonesimulator"
    )
  }

  func testPreferredPlatformIOSDeviceOnly() {
    XCTAssertEqual(SwiftBuildSession.preferredPlatform(forSupportedPlatforms: ["iphoneos"]), "iphoneos")
  }

  func testPreferredPlatformTVOSPrefersSimulator() {
    XCTAssertEqual(
      SwiftBuildSession.preferredPlatform(forSupportedPlatforms: ["appletvos", "appletvsimulator"]),
      "appletvsimulator"
    )
  }

  func testPreferredPlatformWatchOSPrefersSimulator() {
    XCTAssertEqual(
      SwiftBuildSession.preferredPlatform(forSupportedPlatforms: ["watchos", "watchsimulator"]),
      "watchsimulator"
    )
  }

  func testPreferredPlatformCrossFamilyPrefersMacOS() {
    XCTAssertEqual(
      SwiftBuildSession.preferredPlatform(forSupportedPlatforms: ["macosx", "iphoneos", "iphonesimulator"]),
      "macosx"
    )
  }

  func testPreferredPlatformEmptyFallsBackToMacOS() {
    XCTAssertEqual(SwiftBuildSession.preferredPlatform(forSupportedPlatforms: []), "macosx")
  }

  func testPreferredPlatformTVOSDeviceOnly() {
    XCTAssertEqual(SwiftBuildSession.preferredPlatform(forSupportedPlatforms: ["appletvos"]), "appletvos")
  }

  func testPreferredPlatformWatchOSDeviceOnly() {
    XCTAssertEqual(SwiftBuildSession.preferredPlatform(forSupportedPlatforms: ["watchos"]), "watchos")
  }

  func testPreferredPlatformIsOrderIndependent() {
    XCTAssertEqual(
      SwiftBuildSession.preferredPlatform(forSupportedPlatforms: ["iphonesimulator", "iphoneos"]),
      "iphonesimulator"
    )
  }

  // MARK: - resolveScheme decision logic

  func testResolveSchemeMatchesNamedTargets() {
    let targets = [
      XcodeTarget(guid: "G_App", name: "App", platforms: ["macosx"]),
      XcodeTarget(guid: "G_Fw", name: "Framework", platforms: ["macosx"]),
      XcodeTarget(guid: "G_Other", name: "Other", platforms: ["macosx"]),
    ]
    let resolution = XcodeBuildServer.resolveScheme(
      named: "AppScheme",
      schemeTargets: [XcodeScheme.SchemeBuildTarget(blueprintName: "App", container: nil)],
      allTargets: targets
    )
    XCTAssertEqual(resolution, .seeds(["G_App"]))
  }

  func testResolveSchemeMatchesMultipleNamedTargets() {
    let targets = [
      XcodeTarget(guid: "G_App", name: "App", platforms: ["macosx"]),
      XcodeTarget(guid: "G_Fw", name: "Framework", platforms: ["macosx"]),
      XcodeTarget(guid: "G_Other", name: "Other", platforms: ["macosx"]),
    ]
    let resolution = XcodeBuildServer.resolveScheme(
      named: "AppScheme",
      schemeTargets: [
        XcodeScheme.SchemeBuildTarget(blueprintName: "App", container: nil),
        XcodeScheme.SchemeBuildTarget(blueprintName: "Framework", container: nil),
      ],
      allTargets: targets
    )
    XCTAssertEqual(resolution, .seeds(["G_App", "G_Fw"]))
  }

  func testResolveSchemeFallsBackToSameNamedTargetWhenNoFile() {
    let targets = [XcodeTarget(guid: "G_App", name: "App", platforms: ["macosx"])]
    let resolution = XcodeBuildServer.resolveScheme(
      named: "App",
      schemeTargets: nil,
      allTargets: targets
    )
    XCTAssertEqual(resolution, .seeds(["G_App"]))
  }

  func testResolveSchemeNotFoundWhenNoFileAndNoSameNamedTarget() {
    let targets = [XcodeTarget(guid: "G_App", name: "App", platforms: ["macosx"])]
    let resolution = XcodeBuildServer.resolveScheme(
      named: "Ghost",
      schemeTargets: nil,
      allTargets: targets
    )
    XCTAssertEqual(resolution, .fallbackNotFound)
  }

  func testResolveSchemeNoKnownTargetsWhenFileNamesDoNotMatch() {
    let targets = [XcodeTarget(guid: "G_App", name: "App", platforms: ["macosx"])]
    let resolution = XcodeBuildServer.resolveScheme(
      named: "AppScheme",
      schemeTargets: [XcodeScheme.SchemeBuildTarget(blueprintName: "Vanished", container: nil)],
      allTargets: targets
    )
    XCTAssertEqual(resolution, .fallbackNoKnownTargets)
  }

  func testResolveSchemeDisambiguatesSameNamedTargetsByContainer() {
    let appA = URL(fileURLWithPath: "/ws/AppA/AppA.xcodeproj")
    let appB = URL(fileURLWithPath: "/ws/AppB/AppB.xcodeproj")
    let targets = [
      XcodeTarget(guid: "G_A", name: "App", platforms: ["macosx"], projectFilePath: appA),
      XcodeTarget(guid: "G_B", name: "App", platforms: ["macosx"], projectFilePath: appB),
    ]
    let resolution = XcodeBuildServer.resolveScheme(
      named: "App",
      schemeTargets: [XcodeScheme.SchemeBuildTarget(blueprintName: "App", container: appA)],
      allTargets: targets
    )
    XCTAssertEqual(resolution, .seeds(["G_A"]), "container:AppA should select only AppA's App")
  }

  func testResolveSchemeMatchesByNameWhenContainerAbsent() {
    let appA = URL(fileURLWithPath: "/ws/AppA/AppA.xcodeproj")
    let appB = URL(fileURLWithPath: "/ws/AppB/AppB.xcodeproj")
    let targets = [
      XcodeTarget(guid: "G_A", name: "App", platforms: ["macosx"], projectFilePath: appA),
      XcodeTarget(guid: "G_B", name: "App", platforms: ["macosx"], projectFilePath: appB),
    ]
    // No container on the scheme reference -> legacy name-only match (both selected).
    let resolution = XcodeBuildServer.resolveScheme(
      named: "App",
      schemeTargets: [XcodeScheme.SchemeBuildTarget(blueprintName: "App", container: nil)],
      allTargets: targets
    )
    XCTAssertEqual(resolution, .seeds(["G_A", "G_B"]))
  }

  func testResolveSchemeMatchesByNameWhenTargetProjectPathAbsent() {
    let appA = URL(fileURLWithPath: "/ws/AppA/AppA.xcodeproj")
    // Targets have no projectFilePath (evaluation failed) -> container cannot constrain -> name-only.
    let targets = [
      XcodeTarget(guid: "G_A", name: "App", platforms: ["macosx"]),
      XcodeTarget(guid: "G_B", name: "App", platforms: ["macosx"]),
    ]
    let resolution = XcodeBuildServer.resolveScheme(
      named: "App",
      schemeTargets: [XcodeScheme.SchemeBuildTarget(blueprintName: "App", container: appA)],
      allTargets: targets
    )
    XCTAssertEqual(resolution, .seeds(["G_A", "G_B"]))
  }

  // MARK: - isTestProductType classification

  func testUnitTestProductTypeIsTest() {
    XCTAssertTrue(SwiftBuildSession.isTestProductType("com.apple.product-type.bundle.unit-test"))
  }

  func testUITestingProductTypeIsTest() {
    XCTAssertTrue(SwiftBuildSession.isTestProductType("com.apple.product-type.bundle.ui-testing"))
  }

  func testApplicationProductTypeIsNotTest() {
    XCTAssertFalse(SwiftBuildSession.isTestProductType("com.apple.product-type.application"))
  }

  func testFrameworkProductTypeIsNotTest() {
    XCTAssertFalse(SwiftBuildSession.isTestProductType("com.apple.product-type.framework"))
  }

  func testEmptyProductTypeIsNotTest() {
    XCTAssertFalse(SwiftBuildSession.isTestProductType(""))
  }

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

  func testNonMemberProjectIsNotPartOfRootProjectAmongMultipleRoots() {
    let appProject = URL(fileURLWithPath: "/proj/AppA.xcodeproj")
    let otherProject = URL(fileURLWithPath: "/proj/OtherC.xcodeproj")
    let package = URL(fileURLWithPath: "/proj/.build/SourcePackages/checkouts/Pkg/Pkg.xcodeproj")
    XCTAssertFalse(
      XcodeBuildServer.isPartOfRootProject(projectFilePath: package, rootProjectPaths: [appProject, otherProject])
    )
  }

  // MARK: - dependencyIdentifiers

  func testDependencyIdentifiersFiltersOutOfScopeGUIDs() throws {
    let graph = ["G_App": ["G_Fw", "G_External"]]
    let ids = try XcodeBuildServer.dependencyIdentifiers(
      forTargetGUID: "G_App",
      graph: graph,
      scopedGUIDs: ["G_App", "G_Fw"]
    )
    XCTAssertEqual(try ids.map { try $0.xcodeTargetGUID }, ["G_Fw"])
  }

  func testDependencyIdentifiersAreSortedForDeterminism() throws {
    let graph = ["G_App": ["G_Z", "G_A"]]
    let ids = try XcodeBuildServer.dependencyIdentifiers(
      forTargetGUID: "G_App",
      graph: graph,
      scopedGUIDs: ["G_A", "G_Z"]
    )
    XCTAssertEqual(try ids.map { try $0.xcodeTargetGUID }, ["G_A", "G_Z"])
  }

  func testDependencyIdentifiersEmptyWhenNoEntry() throws {
    let ids = try XcodeBuildServer.dependencyIdentifiers(
      forTargetGUID: "G_Unknown",
      graph: [:],
      scopedGUIDs: ["G_App"]
    )
    XCTAssertTrue(ids.isEmpty)
  }

  private func temporaryDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcode-bs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }

  // MARK: - End-to-end integration tests (real SwiftBuild + real xcodebuild)

  /// Skips the test unless we are on macOS with `xcodebuild` available, since the Xcode build server requires a real
  /// SwiftBuild session backed by `xcrun xcodebuild`.
  private func skipUnlessXcodeAvailable() throws {
    #if os(macOS)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    p.arguments = ["--find", "xcodebuild"]
    p.standardOutput = nil
    p.standardError = nil
    try? p.run()
    p.waitUntilExit()
    if p.terminationStatus != 0 { throw XCTSkip("xcodebuild not available") }
    #else
    throw XCTSkip("Xcode build server requires macOS")
    #endif
  }

  /// Test 1: loading a real `.xcodeproj` yields at least one target, its sources include `main.swift`, and
  /// `sourceKitOptions` returns real compiler arguments for `main.swift`.
  func testTargetsSourcesAndSourceKitOptions() async throws {
    try skipUnlessXcodeAvailable()

    let project = try XcodeTestProject(sourceContents: "print(\"hello\")\n")
    defer { project.keepAlive() }

    let buildServer = try await XcodeBuildServer(
      projectRoot: project.projectRoot,
      containerPath: project.xcodeprojURL,
      toolchainRegistry: .forTesting,
      options: SourceKitLSPOptions(),
      connectionToSourceKitLSP: LocalConnection(receiverName: "Dummy SourceKit-LSP")
    )
    // SwiftBuild requires its session to be closed before deallocation, so close it once the test finishes.
    addTeardownBlock { await buildServer.close() }

    // Targets
    let targetsResponse = try await buildServer.buildTargets(request: WorkspaceBuildTargetsRequest())
    XCTAssertFalse(targetsResponse.targets.isEmpty, "expected at least one target from the Xcode project")
    let targetIds = targetsResponse.targets.map(\.id)

    // Sources
    let sourcesResponse = try await buildServer.buildTargetSources(
      request: BuildTargetSourcesRequest(targets: targetIds)
    )
    let allSourceURIs = sourcesResponse.items.flatMap(\.sources).map(\.uri)
    let sourceFileNames = allSourceURIs.compactMap { $0.fileURL?.lastPathComponent }
    XCTAssertTrue(
      sourceFileNames.contains("main.swift"),
      "expected main.swift among target sources, got: \(sourceFileNames)"
    )

    // sourceKitOptions for main.swift
    let firstTarget = try XCTUnwrap(targetIds.first)
    let options = try await buildServer.sourceKitOptions(
      request: TextDocumentSourceKitOptionsRequest(
        textDocument: TextDocumentIdentifier(DocumentURI(project.sourceFileURL)),
        target: firstTarget,
        language: .swift
      )
    )
    let unwrappedOptions = try XCTUnwrap(options, "expected sourceKitOptions for main.swift")
    let args = unwrappedOptions.compilerArguments

    XCTAssertFalse(args.isEmpty, "expected non-empty compiler arguments for main.swift")
    // Prove these are real Swift compiler arguments for main.swift (not an empty/fallback set):
    // - the source file path must appear in the argument list
    // - a real SDK must be referenced (either via `-sdk` or an `.sdk` path on the command line)
    XCTAssertTrue(
      args.contains { $0.hasSuffix("main.swift") },
      "expected main.swift path in compiler arguments, got: \(args)"
    )
    let referencesSDK = args.contains("-sdk") || args.contains { $0.hasSuffix(".sdk") }
    let referencesTarget = args.contains("-target")
    XCTAssertTrue(
      referencesSDK || referencesTarget,
      "expected real Swift compilation flags (-sdk/.sdk path or -target) in compiler arguments, got: \(args)"
    )
  }

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

  /// A scheme whose Build action builds only `MyApp` but whose Test action's `Testables` reference
  /// `MyAppTests` must scope the build server to include the test target. `MyAppTests` is not reachable
  /// from `MyApp`'s dependency closure (the test depends on the app, not vice versa), so this only passes
  /// if Test-action references are collected as scope seeds.
  func testSchemeScopesToTestActionTestables() async throws {
    try skipUnlessXcodeAvailable()

    let project = try XcodeTestProject(kind: .appWithUnitTestTarget, sourceContents: "print(\"hi\")\n")
    defer { project.keepAlive() }
    try project.writeSharedScheme(
      named: "MyAppScheme",
      buildTargetNames: ["MyApp"],
      testTargetNames: ["MyAppTests"]
    )

    let buildServer = try await XcodeBuildServer(
      projectRoot: project.projectRoot,
      containerPath: project.xcodeprojURL,
      toolchainRegistry: .forTesting,
      options: SourceKitLSPOptions(xcode: SourceKitLSPOptions.XcodeOptions(scheme: "MyAppScheme")),
      connectionToSourceKitLSP: LocalConnection(receiverName: "Dummy SourceKit-LSP")
    )
    addTeardownBlock { await buildServer.close() }

    let targetsResponse = try await buildServer.buildTargets(request: WorkspaceBuildTargetsRequest())
    let names = Set(targetsResponse.targets.compactMap(\.displayName))
    XCTAssertTrue(
      names.contains("MyAppTests"),
      "Test-action testable MyAppTests should be in scope; got \(names.sorted())"
    )
    XCTAssertTrue(
      names.contains("MyApp"),
      "Build-action target MyApp should be in scope; got \(names.sorted())"
    )
  }

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

  /// In a workspace with two projects each owning a target named `App`, a scheme whose
  /// `ReferencedContainer` points to `AppA/AppA.xcodeproj` scopes to AppA's `App` only.
  func testSchemeDisambiguatesSameNamedTargetsByContainer() async throws {
    try skipUnlessXcodeAvailable()

    let project = try XcodeTestProject(kind: .workspaceWithDuplicateTargetNames, sourceContents: "print(\"hi\")\n")
    defer { project.keepAlive() }
    try project.writeWorkspaceSharedScheme(
      named: "App",
      buildTargets: [(blueprintName: "App", container: "AppA/AppA.xcodeproj")]
    )

    let workspaceURL = try XCTUnwrap(project.workspaceURL)
    let buildServer = try await XcodeBuildServer(
      projectRoot: project.projectRoot,
      containerPath: workspaceURL,
      toolchainRegistry: .forTesting,
      options: SourceKitLSPOptions(xcode: SourceKitLSPOptions.XcodeOptions(scheme: "App")),
      connectionToSourceKitLSP: LocalConnection(receiverName: "Dummy SourceKit-LSP")
    )
    addTeardownBlock { await buildServer.close() }

    let targetsResponse = try await buildServer.buildTargets(request: WorkspaceBuildTargetsRequest())
    XCTAssertEqual(
      targetsResponse.targets.count,
      1,
      "container:AppA should scope to exactly one App target (not both AppA and AppB), got \(targetsResponse.targets.map(\.displayName))"
    )

    let sourcesResponse = try await buildServer.buildTargetSources(
      request: BuildTargetSourcesRequest(targets: targetsResponse.targets.map(\.id))
    )
    let sourcePaths = sourcesResponse.items.flatMap(\.sources).compactMap { $0.uri.fileURL?.path }
    XCTAssertTrue(
      sourcePaths.contains { $0.contains("/AppA/") },
      "scoped target's sources should come from AppA, got: \(sourcePaths)"
    )
    XCTAssertFalse(
      sourcePaths.contains { $0.contains("/AppB/") },
      "AppB sources must not be in scope, got: \(sourcePaths)"
    )
  }

  /// Test 2: `prepare` runs an actual build that populates the index store directory on disk.
  func testPreparePopulatesIndexStore() async throws {
    try skipUnlessXcodeAvailable()

    let project = try XcodeTestProject(sourceContents: "let x = 1\n")
    defer { project.keepAlive() }

    let buildServer = try await XcodeBuildServer(
      projectRoot: project.projectRoot,
      containerPath: project.xcodeprojURL,
      toolchainRegistry: .forTesting,
      options: SourceKitLSPOptions(),
      connectionToSourceKitLSP: LocalConnection(receiverName: "Dummy SourceKit-LSP")
    )
    // SwiftBuild requires its session to be closed before deallocation, so close it once the test finishes.
    addTeardownBlock { await buildServer.close() }

    let targetsResponse = try await buildServer.buildTargets(request: WorkspaceBuildTargetsRequest())
    let targetIds = targetsResponse.targets.map(\.id)
    XCTAssertFalse(targetIds.isEmpty, "expected at least one target to prepare")

    _ = try await buildServer.prepare(request: BuildTargetPrepareRequest(targets: targetIds))

    let indexStorePathOrNil = await buildServer.indexStorePath
    let indexStorePath = try XCTUnwrap(indexStorePathOrNil, "expected an index store path after prepare")
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: indexStorePath.path, isDirectory: &isDirectory)
    XCTAssertTrue(exists, "expected index store directory to exist at \(indexStorePath.path) after prepare")
    XCTAssertTrue(isDirectory.boolValue, "expected index store path \(indexStorePath.path) to be a directory")
  }

  /// Test 3: a real macOS target reports `macosx` among its supported platforms, proving that
  /// `SUPPORTED_PLATFORMS` macro evaluation works end-to-end against a real SwiftBuild session.
  func testMacOSTargetReportsMacosxPlatform() async throws {
    try skipUnlessXcodeAvailable()

    let project = try XcodeTestProject(sourceContents: "print(\"hello\")\n")
    defer { project.keepAlive() }

    // `platforms` is not surfaced through the BSP `BuildTarget` response, so this exercises
    // `SwiftBuildSession.targets()` directly — the unit that computes supported platforms.
    let session = try await SwiftBuildSession(
      containerPath: project.xcodeprojURL,
      configuration: "Debug",
      destinationOverride: nil,
      derivedDataPath: project.projectRoot.appending(component: ".build").appending(component: "sk-xcode")
    )
    addTeardownBlock { await session.close() }

    let targets = try await session.targets()
    XCTAssertTrue(
      targets.contains { $0.platforms.contains("macosx") },
      "expected a target whose supported platforms include macosx, got: \(targets.map(\.platforms))"
    )
  }

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
    let target = try XCTUnwrap(
      targets.first { $0.name == "MyApp" },
      "expected a target named MyApp, got \(targets.map(\.name))"
    )
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

  /// Test 4: an iOS target reports a simulator platform and, with no destination override, its indexing
  /// compiler arguments reference the iOS Simulator SDK — the direct regression test for the previous
  /// "always fall back to macOS" behavior.
  func testIOSTargetInfersSimulatorDestination() async throws {
    try skipUnlessXcodeAvailable()

    let project = try XcodeTestProject(kind: .iOSApp, sourceContents: "let x = 1\n")
    defer { project.keepAlive() }

    let session = try await SwiftBuildSession(
      containerPath: project.xcodeprojURL,
      configuration: "Debug",
      destinationOverride: nil,
      derivedDataPath: project.projectRoot.appending(component: ".build").appending(component: "sk-xcode")
    )
    addTeardownBlock { await session.close() }

    let targets = try await session.targets()
    let iosTarget = try XCTUnwrap(
      targets.first { $0.platforms.contains("iphonesimulator") },
      "expected a target whose supported platforms include iphonesimulator, got: \(targets.map(\.platforms))"
    )

    let indexingFiles = try await session.indexingFiles(for: iosTarget)
    let args = indexingFiles.flatMap(\.compilerArguments)
    XCTAssertFalse(args.isEmpty, "expected compiler arguments for the iOS target source files")

    // The chosen destination must be the iOS Simulator: either the SDK path mentions iPhoneSimulator,
    // or the `-target` triple is an iOS simulator triple (e.g. arm64-apple-ios17.0-simulator).
    let mentionsIOSSimulator = args.contains { arg in
      let lower = arg.lowercased()
      return lower.contains("iphonesimulator") || (lower.contains("-apple-ios") && lower.contains("simulator"))
    }
    XCTAssertTrue(
      mentionsIOSSimulator,
      "expected iOS Simulator SDK/target in compiler arguments, got: \(args)"
    )
  }

  /// Both targets of `.appWithFrameworkDependency` live in the opened `MyApp.xcodeproj`, so neither
  /// is tagged `.dependency`. Also proves `PROJECT_FILE_PATH` classification is wired into buildTargets.
  /// The positive counterpart — a SwiftPM package target that IS tagged `.dependency` — is covered by
  /// `testPackageDependencyTargetIsTaggedDependency`.
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

  /// Test 5: a unit-test target is tagged `.test` while a non-test target is not. This is what
  /// drives `mayContainTests`, and therefore SourceKit-LSP test discovery, for Xcode projects.
  func testTestTargetIsTaggedAsTest() async throws {
    try skipUnlessXcodeAvailable()

    let project = try XcodeTestProject(kind: .appWithUnitTestTarget, sourceContents: "print(\"hi\")\n")
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
    let testTarget = try XCTUnwrap(
      response.targets.first { $0.displayName == "MyAppTests" },
      "expected a MyAppTests target, got: \(response.targets.map(\.displayName))"
    )
    let appTarget = try XCTUnwrap(
      response.targets.first { $0.displayName == "MyApp" },
      "expected a MyApp target, got: \(response.targets.map(\.displayName))"
    )
    XCTAssertTrue(
      testTarget.tags.contains(.test),
      "expected MyAppTests to be tagged .test, got tags: \(testTarget.tags)"
    )
    XCTAssertFalse(
      appTarget.tags.contains(.test),
      "expected MyApp (non-test) to have no .test tag, got tags: \(appTarget.tags)"
    )
  }
  #endif
}
