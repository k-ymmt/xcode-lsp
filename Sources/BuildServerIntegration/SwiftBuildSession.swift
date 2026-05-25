//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

#if !NO_SWIFTPM_DEPENDENCY
package import Foundation
package import LanguageServerProtocol
@_spi(SourceKitLSP) import SKLogging
@preconcurrency import SwiftBuild
import SwiftExtensions

// MARK: - Public value types

/// A target in a loaded `.xcodeproj` / `.xcworkspace` workspace.
///
/// This is a plain value type that intentionally exposes none of the `SwiftBuild` API so that
/// downstream code does not need to depend on `import SwiftBuild`.
package struct XcodeTarget: Sendable, Equatable {
  package var guid: String
  package var name: String
  /// Supported platform names (e.g. "macosx", "iphonesimulator"). Empty if unknown.
  package var platforms: [String]

  package init(guid: String, name: String, platforms: [String]) {
    self.guid = guid
    self.name = name
    self.platforms = platforms
  }
}

/// Per-file indexing information for a source file in an `XcodeTarget`.
package struct XcodeIndexingFile: Sendable, Equatable {
  package var sourceFilePath: URL
  package var outputFilePath: URL?
  package var language: Language
  package var compilerArguments: [String]

  package init(sourceFilePath: URL, outputFilePath: URL?, language: Language, compilerArguments: [String]) {
    self.sourceFilePath = sourceFilePath
    self.outputFilePath = outputFilePath
    self.language = language
    self.compilerArguments = compilerArguments
  }
}

// MARK: - XcodeBuildFailedError

/// Thrown by `SwiftBuildSession.build(targets:)` when a target's build ends in a non-success state,
/// indicating that the index store was not fully populated for that target.
package struct XcodeBuildFailedError: Error, CustomStringConvertible {
  package var targetName: String
  package var targetGUID: String
  /// Human-readable terminal state, e.g. "failed", "cancelled", "aborted".
  package var stateName: String

  package var description: String {
    "Build failed for target '\(targetName)' (guid: \(targetGUID)) with state: \(stateName)"
  }
}

// MARK: - SwiftBuildSession

/// Wraps a `SwiftBuild` build-service session, isolating all `import SwiftBuild` usage behind plain
/// Swift value types.
///
/// A session starts a SwiftBuild build-service process, loads an `.xcodeproj` / `.xcworkspace` (which
/// internally runs `xcrun xcodebuild -dumpPIF`), enumerates targets, returns per-file compiler arguments
/// and output paths, and can run builds to populate the index store.
package actor SwiftBuildSession {
  private let service: SWBBuildService
  private let session: SWBBuildServiceSession
  private var closed = false
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
    self.indexStorePath = derivedDataPath.appendingPathComponent("Index.noindex").appendingPathComponent("DataStore")
    self.indexDatabasePath = derivedDataPath.appendingPathComponent("IndexDatabase")

    let containerFilePath = try containerPath.filePath
    // Run the SwiftBuild service in-process. SourceKit-LSP links the `SwiftBuild` library directly, so there is no
    // standalone `SWBBuildServiceBundle` executable to launch out-of-process (the default mode on macOS); attempting
    // the out-of-process path fails with "cannot determine build service executable URL". The in-process mode loads
    // the `swiftbuildServiceEntryPoint` symbol from the already-linked SwiftBuild image, which is exactly the
    // configuration we ship.
    let service = try await SWBBuildService(connectionMode: .inProcess)
    self.service = service
    let (sessionResult, _) = await service.createSession(
      name: containerFilePath,
      cachePath: nil,
      inferiorProductsPath: nil,
      environment: nil
    )
    do {
      self.session = try sessionResult.get()
    } catch {
      await service.close()
      throw error
    }
    do {
      try await session.loadWorkspace(containerPath: containerFilePath)
    } catch {
      try? await session.close()
      await service.close()
      throw error
    }
  }

  // MARK: Targets

  /// All targets in the loaded workspace.
  package func targets() async throws -> [XcodeTarget] {
    let info = try await session.workspaceInfo()
    var result: [XcodeTarget] = []
    for targetInfo in info.targetInfos {
      let platforms = await supportedPlatforms(forTargetGUID: targetInfo.guid)
      result.append(
        XcodeTarget(guid: targetInfo.guid, name: targetInfo.targetName, platforms: platforms)
      )
    }
    return result
  }

  /// Evaluate the target's `SUPPORTED_PLATFORMS` build setting (e.g. `["iphoneos", "iphonesimulator"]`).
  ///
  /// `SUPPORTED_PLATFORMS` does not depend on the active run destination, so this evaluates with build
  /// parameters that set only the configuration. Returns an empty array on failure so that destination
  /// selection falls back to macOS rather than failing target enumeration.
  private func supportedPlatforms(forTargetGUID guid: String) async -> [String] {
    var params = SWBBuildParameters()
    params.configurationName = configuration
    return await orLog("Evaluating SUPPORTED_PLATFORMS for target \(guid)") {
      try await session.evaluateMacroAsStringList(
        "SUPPORTED_PLATFORMS",
        level: .target(guid),
        buildParameters: params,
        overrides: [:]
      )
    } ?? []
  }

  // MARK: Indexing info

  /// Per-file indexing info for a target (source list + compiler args + output paths).
  package func indexingFiles(for target: XcodeTarget) async throws -> [XcodeIndexingFile] {
    let request = try makeBuildRequest(for: target)
    let settings = try await session.generateIndexingFileSettings(
      for: request,
      targetID: target.guid,
      filePath: nil,
      outputPathOnly: false,
      delegate: IndexingDelegate()
    )

    var result: [XcodeIndexingFile] = []
    for info in settings.sourceFileBuildInfos {
      guard let sourceFilePath = info["sourceFilePath"]?.stringValue else {
        continue
      }
      let dialect = info["LanguageDialect"]?.stringValue
      let language = Self.language(forDialect: dialect)

      // Swift sources use `swiftASTCommandArguments`; clang-family sources use
      // `clangASTCommandArguments`.
      let arguments: [String]?
      if let swiftArgs = info["swiftASTCommandArguments"]?.stringArrayValue {
        arguments = swiftArgs
      } else {
        arguments = info["clangASTCommandArguments"]?.stringArrayValue
      }
      guard let arguments, !arguments.isEmpty else {
        // Entries without compiler arguments (e.g. asset catalogs, output-only entries) are not
        // indexable source files.
        continue
      }
      guard let language else {
        continue
      }

      let outputFilePath = info["outputFilePath"]?.stringValue.map { URL(fileURLWithPath: $0) }
      result.append(
        XcodeIndexingFile(
          sourceFilePath: URL(fileURLWithPath: sourceFilePath),
          outputFilePath: outputFilePath,
          language: language,
          compilerArguments: arguments
        )
      )
    }
    return result
  }

  // MARK: Build

  /// Builds the given targets to populate the index store. Used by `prepare`.
  package func build(targets: [XcodeTarget]) async throws {
    for target in targets {
      let request = try makeBuildRequest(for: target)
      let operation = try await session.createBuildOperation(
        request: request,
        delegate: IndexingDelegate()
      )
      // Drain the event stream; the last event is always `BuildCompletedInfo` which signals the
      // terminal state. `waitForCompletion()` then provides a stronger completion guarantee even if
      // stream iteration is interrupted.
      let events = try await operation.start()
      for await event in events {
        // Surface build error diagnostics so that a failed preparation can be diagnosed. Only the generic `.diagnostic`
        // case carries an error/warning/note kind; restrict logging to errors there to avoid noise from notes and
        // progress events.
        if case .diagnostic(let info) = event, info.kind == .error {
          logger.error(
            "SwiftBuild prepare error for '\(target.name, privacy: .public)': \(info.message, privacy: .public)"
          )
        }
      }
      await operation.waitForCompletion()
      // Check the terminal state. Any outcome other than `.succeeded` means the index store was
      // not fully populated, and the caller (prepare) must be informed so it can surface the error.
      switch operation.state {
      case .succeeded:
        break
      case .failed:
        throw XcodeBuildFailedError(targetName: target.name, targetGUID: target.guid, stateName: "failed")
      case .cancelled:
        throw XcodeBuildFailedError(targetName: target.name, targetGUID: target.guid, stateName: "cancelled")
      case .aborted:
        throw XcodeBuildFailedError(targetName: target.name, targetGUID: target.guid, stateName: "aborted")
      case .requested, .running:
        // Logically unreachable after waitForCompletion(), but handle defensively.
        throw XcodeBuildFailedError(targetName: target.name, targetGUID: target.guid, stateName: "\(operation.state)")
      }
    }
  }

  // MARK: Reload

  /// Reload the workspace after project files changed on disk.
  package func reload() async throws {
    try await session.loadWorkspace(containerPath: containerPath.filePath)
  }

  // MARK: Lifecycle

  /// Close the underlying SwiftBuild session and shut down the build service.
  ///
  /// SwiftBuild requires `SWBBuildServiceSession` to be closed before it is deallocated (it `assertionFailure`s
  /// otherwise), so this must be called when the session is no longer needed. Safe to call more than once.
  package func close() async {
    if closed { return }
    closed = true
    await orLog("Closing SwiftBuild session") {
      try await session.close()
    }
    await service.close()
  }

  // MARK: Helpers

  private func makeBuildRequest(for target: XcodeTarget) throws -> SWBBuildRequest {
    var parameters = SWBBuildParameters()
    parameters.action = "build"
    parameters.configurationName = configuration
    parameters.activeRunDestination = runDestination(for: target)
    parameters.arenaInfo = try makeArenaInfo()
    parameters.overrides.synthesized = indexingBuildSettingOverrides()

    var request = SWBBuildRequest()
    request.parameters = parameters
    request.add(target: SWBConfiguredTarget(guid: target.guid))
    return request
  }

  /// Build setting overrides applied to indexing / preparation builds.
  ///
  /// Preparation only needs the compilation step that populates the index store; it does not need a fully signed,
  /// linked product. Code signing in particular fails for product types that require it (e.g. macOS command-line
  /// tools on recent SDKs report "An empty code signing identity is not valid" / "Entitlements are required") and
  /// would otherwise abort the build before — or regardless of whether — the index store has been populated. Disabling
  /// signing here mirrors what an indexing build does and keeps preparation hermetic and headless.
  private func indexingBuildSettingOverrides() -> SWBSettingsTable {
    var table = SWBSettingsTable()
    table.set(value: "NO", for: "CODE_SIGNING_ALLOWED")
    table.set(value: "NO", for: "CODE_SIGNING_REQUIRED")
    table.set(value: "", for: "CODE_SIGN_IDENTITY")
    table.set(value: "", for: "CODE_SIGN_ENTITLEMENTS")
    table.set(value: "-", for: "AD_HOC_CODE_SIGNING_ALLOWED")
    table.set(value: "NO", for: "ENTITLEMENTS_REQUIRED")
    return table
  }

  /// An arena whose index data store path points at our index store, with the index data store enabled.
  private func makeArenaInfo() throws -> SWBArenaInfo {
    let build = derivedDataPath.appendingPathComponent("Build")
    return SWBArenaInfo(
      derivedDataPath: try derivedDataPath.filePath,
      buildProductsPath: try build.appendingPathComponent("Products").filePath,
      buildIntermediatesPath: try build.appendingPathComponent("Intermediates.noindex").filePath,
      pchPath: try build.appendingPathComponent("PrecompiledHeaders").filePath,
      indexRegularBuildProductsPath: nil,
      indexRegularBuildIntermediatesPath: nil,
      indexPCHPath: try derivedDataPath.appendingPathComponent("Index.noindex").appendingPathComponent(
        "PrecompiledHeaders"
      ).filePath,
      indexDataStoreFolderPath: try indexStorePath.filePath,
      indexEnableDataStore: true
    )
  }

  private func runDestination(for target: XcodeTarget) -> SWBRunDestinationInfo {
    if let destinationOverride, let parsed = Self.parseDestination(destinationOverride) {
      return parsed
    }
    return Self.runDestination(forPlatform: Self.preferredPlatform(forSupportedPlatforms: target.platforms))
  }

  /// Choose the preferred platform name from a target's supported platforms for headless indexing.
  ///
  /// Priority: macOS first (host-native, always available, needs no simulator runtime); then each
  /// non-macOS family's simulator (no code signing / device provisioning required for indexing);
  /// then devices. Falls back to "macosx" when nothing is recognized (e.g. an empty list).
  ///
  /// This is `package` (unlike `runDestination(forPlatform:)`) because it operates purely on
  /// platform-name strings and is unit-tested from the test module; keeping it free of any
  /// `SwiftBuild` type preserves this file's isolation of `import SwiftBuild`.
  package static func preferredPlatform(forSupportedPlatforms supported: [String]) -> String {
    let set = Set(supported)
    let order = [
      "macosx",
      "iphonesimulator", "appletvsimulator", "watchsimulator",
      "iphoneos", "appletvos", "watchos",
    ]
    return order.first { set.contains($0) } ?? "macosx"
  }

  /// Map a platform name to a run destination. Unknown names fall back to macOS.
  static func runDestination(forPlatform platform: String) -> SWBRunDestinationInfo {
    switch platform {
    case "iphonesimulator":
      return .iOSSimulator
    case "iphoneos":
      return .iOS
    case "appletvsimulator":
      return .tvOSSimulator
    case "appletvos":
      return .tvOS
    case "watchsimulator":
      return .watchOSSimulator
    case "watchos":
      return .watchOS
    case "macosx":
      return .macOS
    default:
      return .macOS
    }
  }

  /// Parse a destination string of the form `platform=macOS` / `platform=iOS Simulator`.
  ///
  /// Supports at least `macOS` and `iOS Simulator`; other Apple platforms are supported too.
  static func parseDestination(_ string: String) -> SWBRunDestinationInfo? {
    var platform: String?
    for component in string.split(separator: ",") {
      let pair = component.split(separator: "=", maxSplits: 1)
      guard pair.count == 2 else { continue }
      let key = pair[0].trimmingCharacters(in: .whitespaces)
      let value = pair[1].trimmingCharacters(in: .whitespaces)
      if key == "platform" {
        platform = value
      }
    }
    let platformName = platform ?? string.trimmingCharacters(in: .whitespaces)
    switch platformName.lowercased() {
    case "macos", "macosx", "os x":
      return .macOS
    case "ios simulator", "iphonesimulator":
      return .iOSSimulator
    case "ios", "iphoneos":
      return .iOS
    case "tvos simulator", "appletvsimulator":
      return .tvOSSimulator
    case "tvos", "appletvos":
      return .tvOS
    case "watchos simulator", "watchsimulator":
      return .watchOSSimulator
    case "watchos":
      return .watchOS
    default:
      return nil
    }
  }

  /// Map a SwiftBuild `LanguageDialect` string to an LSP `Language`.
  private static func language(forDialect dialect: String?) -> Language? {
    switch dialect {
    case "swift":
      return .swift
    case "objective-c":
      return .objective_c
    case "objective-c++":
      return .objective_cpp
    case "c++":
      return .cpp
    case "c":
      return .c
    default:
      return nil
    }
  }
}

// MARK: - SWBRunDestinationInfo convenience destinations

extension SWBRunDestinationInfo {
  // SwiftBuild only exposes these statics in its test support module, so we reconstruct them from the
  // public memberwise initializer here using the same platform / sdk / architecture values.

  fileprivate static var macOS: SWBRunDestinationInfo {
    #if arch(arm64)
    return SWBRunDestinationInfo(
      platform: "macosx",
      sdk: "macosx",
      sdkVariant: "macos",
      targetArchitecture: "arm64",
      supportedArchitectures: ["arm64", "x86_64"],
      disableOnlyActiveArch: false
    )
    #else
    return SWBRunDestinationInfo(
      platform: "macosx",
      sdk: "macosx",
      sdkVariant: "macos",
      targetArchitecture: "x86_64",
      supportedArchitectures: ["x86_64h", "x86_64"],
      disableOnlyActiveArch: false
    )
    #endif
  }

  fileprivate static var iOS: SWBRunDestinationInfo {
    SWBRunDestinationInfo(
      platform: "iphoneos",
      sdk: "iphoneos",
      sdkVariant: "iphoneos",
      targetArchitecture: "arm64",
      supportedArchitectures: ["arm64"],
      disableOnlyActiveArch: false
    )
  }

  fileprivate static var iOSSimulator: SWBRunDestinationInfo {
    SWBRunDestinationInfo(
      platform: "iphonesimulator",
      sdk: "iphonesimulator",
      sdkVariant: "iphonesimulator",
      targetArchitecture: "arm64",
      supportedArchitectures: ["arm64", "x86_64"],
      disableOnlyActiveArch: false
    )
  }

  fileprivate static var tvOS: SWBRunDestinationInfo {
    SWBRunDestinationInfo(
      platform: "appletvos",
      sdk: "appletvos",
      sdkVariant: "appletvos",
      targetArchitecture: "arm64",
      supportedArchitectures: ["arm64"],
      disableOnlyActiveArch: false
    )
  }

  fileprivate static var tvOSSimulator: SWBRunDestinationInfo {
    SWBRunDestinationInfo(
      platform: "appletvsimulator",
      sdk: "appletvsimulator",
      sdkVariant: "appletvsimulator",
      targetArchitecture: "arm64",
      supportedArchitectures: ["arm64", "x86_64"],
      disableOnlyActiveArch: false
    )
  }

  fileprivate static var watchOS: SWBRunDestinationInfo {
    SWBRunDestinationInfo(
      platform: "watchos",
      sdk: "watchos",
      sdkVariant: "watchos",
      targetArchitecture: "arm64_32",
      supportedArchitectures: ["arm64_32"],
      disableOnlyActiveArch: false
    )
  }

  fileprivate static var watchOSSimulator: SWBRunDestinationInfo {
    SWBRunDestinationInfo(
      platform: "watchsimulator",
      sdk: "watchsimulator",
      sdkVariant: "watchsimulator",
      targetArchitecture: "arm64",
      supportedArchitectures: ["arm64", "x86_64"],
      disableOnlyActiveArch: false
    )
  }
}

// MARK: - SWBPropertyListItem accessors

extension SWBPropertyListItem {
  /// The string value, if this item is a string.
  fileprivate var stringValue: String? {
    guard case .plString(let value) = self else {
      return nil
    }
    return value
  }

  /// The array of strings, if this item is an array whose elements are all strings.
  fileprivate var stringArrayValue: [String]? {
    guard case .plArray(let items) = self else {
      return nil
    }
    var result: [String] = []
    result.reserveCapacity(items.count)
    for item in items {
      guard case .plString(let value) = item else {
        return nil
      }
      result.append(value)
    }
    return result
  }
}

// MARK: - Indexing delegate

/// A minimal `SWBIndexingDelegate` that performs no client-side work.
private final class IndexingDelegate: SWBIndexingDelegate, Sendable {
  func provisioningTaskInputs(
    targetGUID: String,
    provisioningSourceData: SWBProvisioningTaskInputsSourceData
  ) async -> SWBProvisioningTaskInputs {
    SWBProvisioningTaskInputs()
  }

  func executeExternalTool(
    commandLine: [String],
    workingDirectory: String?,
    environment: [String: String]
  ) async throws -> SWBExternalToolResult {
    .deferred
  }
}
#endif
