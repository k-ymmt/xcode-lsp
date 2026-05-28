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
  private let scheme: String?

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
    self.scheme = options.xcodeOrDefault.scheme
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

  /// All in-scope targets, cached after first load. When `xcode.scheme` is set, this is the scheme's
  /// Build / Test / Launch action targets plus their dependency closure; otherwise it is every workspace
  /// target.
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
    let schemeTargets = XcodeScheme.buildTargets(
      scheme: scheme,
      containerPath: containerPath,
      projectRoot: projectRoot
    )
    switch Self.resolveScheme(named: scheme, schemeTargets: schemeTargets, allTargets: all) {
    case .seeds(let seedGUIDs):
      let closure = Set(try await session.dependencyClosure(forTargetGUIDs: seedGUIDs))
      let scoped = all.filter { closure.contains($0.guid) }
      // Defensive: if the closure unexpectedly excludes everything, prefer indexing all targets over none.
      guard !scoped.isEmpty else {
        return all
      }
      logger.log("Xcode scheme '\(scheme, privacy: .public)' scoped to \(scoped.count) target(s)")
      return scoped
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

  /// The set of `.xcodeproj` paths considered part of the project the user opened: the container itself
  /// for an `.xcodeproj` (or the member `.xcodeproj`s of an `.xcworkspace`), plus every `.xcodeproj` they
  /// reach transitively through `PBXProject.projectReferences`. A target whose owning project is outside
  /// this set (e.g. a SwiftPM package, which is not a project reference) is tagged `.dependency`.
  private func rootProjectPaths() -> Set<URL> {
    let seeds: Set<URL>
    if containerPath.pathExtension == "xcworkspace" {
      if let members = XcodeWorkspace.memberProjects(workspaceURL: containerPath) {
        seeds = Set(members)
      } else {
        // Fallback when contents.xcworkspacedata is absent/unreadable: previous top-level scan behavior.
        let entries =
          orLog("Enumerating member projects under \(projectRoot.path)") {
            try FileManager.default.contentsOfDirectory(at: projectRoot, includingPropertiesForKeys: nil)
          } ?? []
        seeds = Set(entries.filter { $0.pathExtension == "xcodeproj" })
      }
    } else {
      seeds = [containerPath]
    }
    return Self.expandedRootProjects(seeds: seeds) { projectURL in
      XcodeProject.referencedProjects(ofProjectAt: projectURL).filter {
        FileManager.default.fileExists(atPath: $0.path)
      }
    }
  }

  // MARK: BuiltInBuildServer

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

  /// Shut down the underlying SwiftBuild session and build service.
  ///
  /// SwiftBuild requires its session to be closed before deallocation, so this should be called when the build server
  /// is no longer needed. Safe to call more than once.
  package func close() async {
    await session.close()
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

extension XcodeBuildServer {
  /// Result of resolving an `xcode.scheme` setting against the workspace's targets.
  ///
  /// `package` so the pure decision can be unit-tested from `BuildServerIntegrationTests`.
  package enum SchemeResolution: Equatable {
    /// Seed target GUIDs to expand via the dependency closure. Order is not significant — callers
    /// treat these as a set when computing the closure.
    case seeds([String])
    /// No scheme file and no same-named target — index all targets.
    case fallbackNotFound
    /// A scheme file was found but none of its targets exist in the workspace — index all targets.
    case fallbackNoKnownTargets
  }

  /// Whether a target whose owning `.xcodeproj` is `projectFilePath` belongs to the project the user
  /// opened (vs. a dependency such as a SwiftPM package, whose project lives outside the opened
  /// container). A `nil` path (evaluation failed) is treated conservatively as part of the root
  /// project so its sources are not wrongly excluded from project/test discovery.
  ///
  /// Paths are compared after symlink resolution. In production both `projectFilePath` (from
  /// `PROJECT_FILE_PATH`) and the `rootProjectPaths` (from the opened container) refer to projects that
  /// exist on disk, so the comparison is canonical.
  package static func isPartOfRootProject(projectFilePath: URL?, rootProjectPaths: Set<URL>) -> Bool {
    guard let projectFilePath else {
      return true
    }
    let normalizedProjectPath = normalizedPath(projectFilePath)
    return rootProjectPaths.contains { normalizedPath($0) == normalizedProjectPath }
  }

  /// Canonical path of `url` for on-disk equality comparison (resolves symlinks). Shared by
  /// `isPartOfRootProject` and `resolveScheme`'s container matching.
  package static func normalizedPath(_ url: URL) -> String {
    url.resolvingSymlinksInPath().path
  }

  /// Expand a seed set of `.xcodeproj` paths by transitively following project references, so that the
  /// project the user opened — and every other `.xcodeproj` it project-references (directly or
  /// transitively) — counts as part of the root project. `referencedProjects` returns the direct project
  /// references of one `.xcodeproj` (resolved, and in production existence-filtered). Cycles and duplicate
  /// seeds are handled by tracking visited projects via `normalizedPath`.
  package static func expandedRootProjects(
    seeds: Set<URL>,
    referencedProjects: (URL) -> [URL]
  ) -> Set<URL> {
    var byKey: [String: URL] = [:]
    var queue: [URL] = []
    for seed in seeds where byKey[normalizedPath(seed)] == nil {
      byKey[normalizedPath(seed)] = seed
      queue.append(seed)
    }
    while let current = queue.popLast() {
      for referenced in referencedProjects(current) {
        let key = normalizedPath(referenced)
        if byKey[key] == nil {
          byKey[key] = referenced
          queue.append(referenced)
        }
      }
    }
    return Set(byKey.values)
  }

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

  /// Decide which targets a scheme scopes to, purely from already-loaded data.
  ///
  /// - `schemeTargets`: Build-action targets from the `.xcscheme` file (name + optional container path),
  ///   or `nil` if no file was found. When `nil`, a target whose name equals the scheme name is used as
  ///   the seed (this rescues Xcode's autogenerated schemes, which have no file and build a single
  ///   same-named target). When targets are provided, each reference's container (if known) is compared
  ///   to the candidate target's `projectFilePath` to disambiguate same-named targets across projects.
  ///
  /// `package` (not `private`) so it is unit-testable; it touches no `SwiftBuild` types.
  package static func resolveScheme(
    named scheme: String,
    schemeTargets: [XcodeScheme.SchemeBuildTarget]?,
    allTargets: [XcodeTarget]
  ) -> SchemeResolution {
    if let schemeTargets {
      let guids =
        allTargets
        .filter { target in
          schemeTargets.contains { reference in
            reference.blueprintName == target.name
              && containerMatches(reference.container, target.projectFilePath)
          }
        }
        .map(\.guid)
      return guids.isEmpty ? .fallbackNoKnownTargets : .seeds(guids)
    }
    if let sameNamed = allTargets.first(where: { $0.name == scheme }) {
      return .seeds([sameNamed.guid])
    }
    return .fallbackNotFound
  }

  /// Whether a scheme reference's resolved `container` matches a target's owning `projectFilePath`.
  /// The container only constrains the match when BOTH paths are known; if either is `nil`, the target
  /// matches on name alone (backward compatible with schemes/targets lacking container info).
  private static func containerMatches(_ container: URL?, _ projectFilePath: URL?) -> Bool {
    guard let container, let projectFilePath else {
      return true
    }
    return normalizedPath(container) == normalizedPath(projectFilePath)
  }
}
#endif
