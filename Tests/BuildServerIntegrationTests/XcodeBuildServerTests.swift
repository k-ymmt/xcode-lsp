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
  #endif
}
