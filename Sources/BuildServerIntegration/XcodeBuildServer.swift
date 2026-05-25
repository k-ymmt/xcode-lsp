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
@_spi(SourceKitLSP) package import BuildServerProtocol
package import Foundation
@_spi(SourceKitLSP) package import LanguageServerProtocol
@_spi(SourceKitLSP) import SKLogging
package import SKOptions
import SwiftExtensions
package import ToolchainRegistry

/// A `BuiltInBuildServer` that loads an `.xcodeproj` / `.xcworkspace` via SwiftBuild and provides
/// compiler arguments, output paths and target preparation, mapping a `SwiftBuildSession` onto BSP types.
package actor XcodeBuildServer: BuiltInBuildServer {
  private let projectRoot: URL
  private let containerPath: URL
  private let options: SourceKitLSPOptions
  private let connectionToSourceKitLSP: any Connection
  private let session: SwiftBuildSession

  /// Cache of indexing files keyed by target GUID.
  private var indexingFilesByTarget: [String: [XcodeIndexingFile]] = [:]
  /// Cache of all targets in the loaded workspace.
  private var cachedTargets: [XcodeTarget]?

  package let fileWatchers: [FileSystemWatcher] = [
    FileSystemWatcher(globPattern: "**/*.xcodeproj/project.pbxproj", kind: [.create, .change, .delete]),
    FileSystemWatcher(globPattern: "**/*.xcworkspace/contents.xcworkspacedata", kind: [.create, .change, .delete]),
    FileSystemWatcher(globPattern: "**/*.xcscheme", kind: [.create, .change, .delete]),
    FileSystemWatcher(globPattern: "**/*.xcconfig", kind: [.create, .change, .delete]),
  ]

  // `SwiftBuildSession.indexStorePath`/`indexDatabasePath` are immutable Sendable `let`s on an actor,
  // hence nonisolated — access them SYNCHRONOUSLY (no `await`), otherwise `-Werror` rejects the
  // unnecessary `await` with "no 'async' operations occur within 'await' expression".
  package var indexStorePath: URL? { get async { session.indexStorePath } }
  package var indexDatabasePath: URL? { get async { session.indexDatabasePath } }
  package nonisolated var supportsPreparationAndOutputPaths: Bool { true }

  package init(
    projectRoot: URL,
    containerPath: URL,
    // toolchainRegistry is accepted for call-site uniformity with other build servers; SwiftBuild resolves toolchains internally.
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

  // MARK: Caching

  /// All targets in the loaded workspace, cached after first load.
  private func allTargets() async throws -> [XcodeTarget] {
    if let cachedTargets {
      return cachedTargets
    }
    let targets = try await session.targets()
    self.cachedTargets = targets
    return targets
  }

  /// Per-file indexing info for the target with the given GUID, cached after first load.
  private func indexingFiles(forTargetGUID guid: String) async throws -> [XcodeIndexingFile] {
    if let cached = indexingFilesByTarget[guid] {
      return cached
    }
    guard let target = try await allTargets().first(where: { $0.guid == guid }) else {
      return []
    }
    let files = try await session.indexingFiles(for: target)
    indexingFilesByTarget[guid] = files
    return files
  }

  private func invalidateCaches() {
    cachedTargets = nil
    indexingFilesByTarget = [:]
  }

  // MARK: BuiltInBuildServer

  package func buildTargets(request: WorkspaceBuildTargetsRequest) async throws -> WorkspaceBuildTargetsResponse {
    let targets = try await allTargets().asyncMap { (target) -> BuildTarget in
      return BuildTarget(
        id: try BuildTargetIdentifier.createXcode(targetGUID: target.guid),
        displayName: target.name,
        tags: [],
        capabilities: BuildTargetCapabilities(),
        // Be conservative with the languages that might be used in the target. SourceKit-LSP doesn't use this property.
        languageIds: [.c, .cpp, .objective_c, .objective_cpp, .swift],
        dependencies: [],
        dataKind: .sourceKit,
        data: SourceKitBuildTarget(toolchain: nil).encodeToLSPAny()  // SwiftBuild resolves the toolchain internally, so no explicit toolchain URI is provided.
      )
    }
    return WorkspaceBuildTargetsResponse(targets: targets)
  }

  package func buildTargetSources(request: BuildTargetSourcesRequest) async throws -> BuildTargetSourcesResponse {
    let items = try await request.targets.asyncCompactMap { (target) -> SourcesItem? in
      guard let guid = orLog("Xcode target GUID", { try target.xcodeTargetGUID }) else {
        return nil
      }
      let indexingFiles = try await self.indexingFiles(forTargetGUID: guid)
      let sources = indexingFiles.map { file -> SourceItem in
        let outputPath: String? = file.outputFilePath.flatMap { outputFile in
          orLog("Getting file path of output file") { try outputFile.filePath }
        }
        return SourceItem(
          uri: DocumentURI(file.sourceFilePath),
          kind: .file,
          generated: false,
          dataKind: .sourceKit,
          data: SourceKitSourceItemData(outputPath: outputPath).encodeToLSPAny()
        )
      }
      return SourcesItem(target: target, sources: sources)
    }
    return BuildTargetSourcesResponse(items: items)
  }

  package func didChangeWatchedFiles(notification: OnWatchedFilesDidChangeNotification) async {
    await orLog("Reloading Xcode workspace") {
      try await session.reload()
    }
    invalidateCaches()
    connectionToSourceKitLSP.send(OnBuildTargetDidChangeNotification(changes: nil))
  }

  package func prepare(request: BuildTargetPrepareRequest) async throws -> BuildTargetPrepareResponse {
    let guids = Set(request.targets.compactMap { target in orLog("Xcode target GUID", { try target.xcodeTargetGUID }) })
    let targets = try await allTargets().filter { guids.contains($0.guid) }
    try await session.build(targets: targets)
    return BuildTargetPrepareResponse()
  }

  package func sourceKitOptions(
    request: TextDocumentSourceKitOptionsRequest
  ) async throws -> TextDocumentSourceKitOptionsResponse? {
    let guid = try request.target.xcodeTargetGUID
    guard let fileURL = request.textDocument.uri.fileURL else {
      return nil
    }
    let resolvedURL = fileURL.resolvingSymlinksInPath()
    let indexingFiles = try await indexingFiles(forTargetGUID: guid)
    guard let match = indexingFiles.first(where: { $0.sourceFilePath.resolvingSymlinksInPath() == resolvedURL }) else {
      return nil
    }
    return TextDocumentSourceKitOptionsResponse(
      compilerArguments: match.compilerArguments,
      workingDirectory: try? projectRoot.filePath
    )
  }

  package func waitForBuildSystemUpdates(request: WorkspaceWaitForBuildSystemUpdatesRequest) async -> VoidResponse {
    return VoidResponse()
  }
}

extension XcodeBuildServer {
  /// Look for an Xcode workspace/project in `path`. Prefers `.xcworkspace`, honors `options.xcode.container`.
  static package func searchForConfig(in path: URL, options: SourceKitLSPOptions) -> BuildServerSpec? {
    let fm = FileManager.default

    if let container = options.xcodeOrDefault.container {
      let url = path.appendingPathComponent(container)
      if fm.fileExists(atPath: url.path) {
        return BuildServerSpec(kind: .xcode, projectRoot: path, configPath: url)
      }
    }

    guard let entries = try? fm.contentsOfDirectory(at: path, includingPropertiesForKeys: nil) else {
      return nil
    }
    func pick(_ ext: String) -> URL? {
      let matches = entries.filter { $0.pathExtension == ext }.sorted { $0.lastPathComponent < $1.lastPathComponent }
      return matches.first(where: { $0.deletingPathExtension().lastPathComponent == path.lastPathComponent })
        ?? matches.first
    }
    guard let container = pick("xcworkspace") ?? pick("xcodeproj") else {
      return nil
    }
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
#endif
