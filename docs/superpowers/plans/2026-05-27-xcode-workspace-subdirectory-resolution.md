# Xcode workspace サブディレクトリ解決 実装プラン

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `.xcworkspace` のメンバー `.xcodeproj` 列挙を `projectRoot` 直下のグロブから `contents.xcworkspacedata` の解析(再帰 + 全 location 形式)に置き換え、サブディレクトリ構成のワークスペースを正しく扱う(`.dependency` 誤タグの潜在バグも修正)。

**Architecture:** `XcodeScheme` と並ぶ純粋ユーティリティ `XcodeWorkspace`(`import SwiftBuild` なし)を新設し、`contents.xcworkspacedata` を `Foundation.XMLParser` で解析してメンバー `.xcodeproj` を解決する。`XcodeBuildServer.rootProjectPaths()`(`.dependency` タグ付けの基準)と `XcodeScheme.searchContainers()`(scheme ファイル探索)の重複したトップレベルグロブを、この単一実装に置き換える。解析失敗時のみ従来のグロブにフォールバックするので、成功時は厳密に改善、失敗時は非回帰。

**Tech Stack:** Swift, Foundation (`XMLParser` / `FoundationXML`), SwiftPM, XCTest。ローカル実行は `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer` を前提(`SWIFTCI_USE_LOCAL_DEPS=1` はこのチェックアウトでは不可)。

設計 spec: `docs/superpowers/specs/2026-05-27-xcode-workspace-subdirectory-resolution-design.md`

---

## ファイル構成

| ファイル | 役割 | 操作 |
|---|---|---|
| `Sources/BuildServerIntegration/XcodeWorkspace.swift` | `contents.xcworkspacedata` の解析・メンバー `.xcodeproj` 解決(純粋、`import SwiftBuild` なし) | 新規 |
| `Tests/BuildServerIntegrationTests/XcodeWorkspaceTests.swift` | `XcodeWorkspace` の単体テスト(Xcode 不要) | 新規 |
| `Sources/BuildServerIntegration/XcodeScheme.swift` | `searchContainers()` をメンバー解決ベースに変更 | 変更(75-83 行) |
| `Sources/BuildServerIntegration/XcodeBuildServer.swift` | `rootProjectPaths()` をメンバー解決ベースに変更 | 変更(142-151 行) |
| `Sources/SKTestSupport/XcodeTestProject.swift` | フィクスチャ `.workspaceWithNestedProject` を追加 | 変更 |
| `Tests/BuildServerIntegrationTests/XcodeSchemeTests.swift` | サブディレクトリ member の scheme 探索テスト追加 | 変更 |
| `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift` | フィクスチャ smoke テスト + `.dependency` 統合テスト追加 | 変更 |

各テストの実行は以下の形式(`<filter>` を差し替え):

```sh
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter <filter>
```

---

## Task 1: `XcodeWorkspace.resolveLocation`(location 解決の純関数)

**Files:**
- Create: `Sources/BuildServerIntegration/XcodeWorkspace.swift`
- Create: `Tests/BuildServerIntegrationTests/XcodeWorkspaceTests.swift`

`location="<kind>:<path>"` を kind 別に解決する純関数。`group:` は現在の(親 `<Group>` の)ベース基準、`container:` は workspace ディレクトリ基準(ネスト無視)、`absolute:` は絶対、`self:` は現在のベースそのもの、未知 kind / コロン無しは `nil`。パス結合は `NSString.appendingPathComponent` + `standardizedFileURL`(`.`/`..` を解決、symlink は比較時に委ねる)で RFC 相対解決の落とし穴を避ける。

- [ ] **Step 1: 失敗するテストを書く**

`Tests/BuildServerIntegrationTests/XcodeWorkspaceTests.swift` を新規作成:

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

final class XcodeWorkspaceTests: XCTestCase {
  #if !NO_SWIFTPM_DEPENDENCY

  // MARK: - resolveLocation

  func testResolveLocationGroupRelativeToCurrentBase() {
    let base = URL(fileURLWithPath: "/root/Modules", isDirectory: true)
    let ws = URL(fileURLWithPath: "/root", isDirectory: true)
    XCTAssertEqual(
      XcodeWorkspace.resolveLocation("group:App/App.xcodeproj", currentBase: base, workspaceDir: ws)?.path,
      "/root/Modules/App/App.xcodeproj"
    )
  }

  func testResolveLocationContainerRelativeToWorkspaceDir() {
    // container: ignores the current group base; it is always relative to the workspace directory.
    let base = URL(fileURLWithPath: "/root/Modules", isDirectory: true)
    let ws = URL(fileURLWithPath: "/root", isDirectory: true)
    XCTAssertEqual(
      XcodeWorkspace.resolveLocation("container:Top.xcodeproj", currentBase: base, workspaceDir: ws)?.path,
      "/root/Top.xcodeproj"
    )
  }

  func testResolveLocationAbsolute() {
    let ws = URL(fileURLWithPath: "/root", isDirectory: true)
    XCTAssertEqual(
      XcodeWorkspace.resolveLocation("absolute:/elsewhere/Lib.xcodeproj", currentBase: ws, workspaceDir: ws)?.path,
      "/elsewhere/Lib.xcodeproj"
    )
  }

  func testResolveLocationSelfReturnsCurrentBase() {
    let base = URL(fileURLWithPath: "/root/Modules", isDirectory: true)
    let ws = URL(fileURLWithPath: "/root", isDirectory: true)
    XCTAssertEqual(
      XcodeWorkspace.resolveLocation("self:", currentBase: base, workspaceDir: ws)?.path,
      "/root/Modules"
    )
  }

  func testResolveLocationResolvesDotDot() {
    let base = URL(fileURLWithPath: "/root/Modules", isDirectory: true)
    let ws = URL(fileURLWithPath: "/root", isDirectory: true)
    XCTAssertEqual(
      XcodeWorkspace.resolveLocation("group:../Shared/Lib.xcodeproj", currentBase: base, workspaceDir: ws)?.path,
      "/root/Shared/Lib.xcodeproj"
    )
  }

  func testResolveLocationUnknownKindOrNoColonReturnsNil() {
    let ws = URL(fileURLWithPath: "/root", isDirectory: true)
    XCTAssertNil(XcodeWorkspace.resolveLocation("developer:usr/bin", currentBase: ws, workspaceDir: ws))
    XCTAssertNil(XcodeWorkspace.resolveLocation("noColonHere", currentBase: ws, workspaceDir: ws))
  }
  #endif
}
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeWorkspaceTests`
Expected: ビルド失敗 — `cannot find 'XcodeWorkspace' in scope`(型が未定義)。

- [ ] **Step 3: 最小実装を書く**

`Sources/BuildServerIntegration/XcodeWorkspace.swift` を新規作成:

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

/// Parses an Xcode `.xcworkspace`'s `contents.xcworkspacedata` to enumerate its member `.xcodeproj`s.
/// SwiftBuild does not expose workspace membership, so the build server reads it from disk itself.
/// This type has no `import SwiftBuild` dependency.
package enum XcodeWorkspace {
  /// Resolve a workspace `location="<kind>:<path>"` attribute to an absolute URL.
  ///
  /// - `group:` … relative to `currentBase` (the nearest enclosing `<Group>`'s resolved directory, or the
  ///   workspace directory at the top level).
  /// - `container:` … relative to `workspaceDir`, regardless of group nesting.
  /// - `absolute:` … an absolute path.
  /// - `self:` … the `currentBase` itself (the workspace/group's own directory).
  /// - any other kind, or a string without a `:` … `nil`.
  ///
  /// Paths are joined as filesystem paths and `standardizedFileURL`-normalized (resolves `.`/`..`, not
  /// symlinks); symlink canonicalization happens later in `XcodeBuildServer.normalizedPath`.
  package static func resolveLocation(_ raw: String, currentBase: URL, workspaceDir: URL) -> URL? {
    guard let colon = raw.firstIndex(of: ":") else {
      return nil
    }
    let kind = String(raw[..<colon])
    let path = String(raw[raw.index(after: colon)...])
    let baseDir: String
    switch kind {
    case "group": baseDir = currentBase.path
    case "container": baseDir = workspaceDir.path
    case "absolute": return URL(fileURLWithPath: path).standardizedFileURL
    case "self": return currentBase.standardizedFileURL
    default: return nil
    }
    guard !path.isEmpty else {
      return URL(fileURLWithPath: baseDir).standardizedFileURL
    }
    return URL(fileURLWithPath: (baseDir as NSString).appendingPathComponent(path)).standardizedFileURL
  }
}
#endif
```

- [ ] **Step 4: テストを実行して成功を確認**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeWorkspaceTests`
Expected: PASS(6 テスト)。

- [ ] **Step 5: コミット**

```bash
git add Sources/BuildServerIntegration/XcodeWorkspace.swift Tests/BuildServerIntegrationTests/XcodeWorkspaceTests.swift
git commit -m "feat(BuildServerIntegration): XcodeWorkspace.resolveLocation

Pure resolver for .xcworkspace contents.xcworkspacedata location attributes
(group/container/absolute/self), the basis for subdirectory-aware member
project enumeration.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 2: `XcodeWorkspace.projectReferences`(XML パース・ネスト・dedupe)

**Files:**
- Modify: `Sources/BuildServerIntegration/XcodeWorkspace.swift`
- Test: `Tests/BuildServerIntegrationTests/XcodeWorkspaceTests.swift`

`contents.xcworkspacedata` の XML から `.xcodeproj` で終わる `FileRef` を全解決する。`<Group>` の開始でベース URL をスタックに push、終了で pop して接頭辞を累積。重複は解決後パスで dedupe、文書順を保持。

- [ ] **Step 1: 失敗するテストを書く**

`XcodeWorkspaceTests.swift` の `#endif` の直前に以下を追加:

```swift
  // MARK: - projectReferences

  private func data(_ xml: String) -> Data { Data(xml.utf8) }

  func testProjectReferencesFlatFileRefs() {
    let base = URL(fileURLWithPath: "/root", isDirectory: true)
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <Workspace version = "1.0">
         <FileRef location = "group:AppA/AppA.xcodeproj"></FileRef>
         <FileRef location = "group:AppB/AppB.xcodeproj"></FileRef>
      </Workspace>
      """
    XCTAssertEqual(
      XcodeWorkspace.projectReferences(xcworkspacedataContents: data(xml), baseDir: base).map(\.path),
      ["/root/AppA/AppA.xcodeproj", "/root/AppB/AppB.xcodeproj"]
    )
  }

  func testProjectReferencesNestedGroupAccumulatesPrefix() {
    let base = URL(fileURLWithPath: "/root", isDirectory: true)
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <Workspace version = "1.0">
         <Group location = "group:Modules">
            <FileRef location = "group:MyLib/MyLib.xcodeproj"></FileRef>
         </Group>
      </Workspace>
      """
    XCTAssertEqual(
      XcodeWorkspace.projectReferences(xcworkspacedataContents: data(xml), baseDir: base).map(\.path),
      ["/root/Modules/MyLib/MyLib.xcodeproj"]
    )
  }

  func testProjectReferencesContainerIgnoresGroupPrefix() {
    let base = URL(fileURLWithPath: "/root", isDirectory: true)
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <Workspace version = "1.0">
         <Group location = "group:Modules">
            <FileRef location = "container:Top.xcodeproj"></FileRef>
         </Group>
      </Workspace>
      """
    XCTAssertEqual(
      XcodeWorkspace.projectReferences(xcworkspacedataContents: data(xml), baseDir: base).map(\.path),
      ["/root/Top.xcodeproj"]
    )
  }

  func testProjectReferencesIgnoresNonXcodeprojAndSelf() {
    let base = URL(fileURLWithPath: "/root", isDirectory: true)
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <Workspace version = "1.0">
         <FileRef location = "self:"></FileRef>
         <FileRef location = "group:Package.swift"></FileRef>
         <FileRef location = "group:App/App.xcodeproj"></FileRef>
      </Workspace>
      """
    XCTAssertEqual(
      XcodeWorkspace.projectReferences(xcworkspacedataContents: data(xml), baseDir: base).map(\.path),
      ["/root/App/App.xcodeproj"]
    )
  }

  func testProjectReferencesDeduplicates() {
    let base = URL(fileURLWithPath: "/root", isDirectory: true)
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <Workspace version = "1.0">
         <FileRef location = "group:App/App.xcodeproj"></FileRef>
         <FileRef location = "group:App/App.xcodeproj"></FileRef>
      </Workspace>
      """
    XCTAssertEqual(
      XcodeWorkspace.projectReferences(xcworkspacedataContents: data(xml), baseDir: base).map(\.path),
      ["/root/App/App.xcodeproj"]
    )
  }

  func testProjectReferencesEmptyForGarbage() {
    let base = URL(fileURLWithPath: "/root", isDirectory: true)
    XCTAssertEqual(XcodeWorkspace.projectReferences(xcworkspacedataContents: data("not xml <<<"), baseDir: base), [])
    XCTAssertEqual(XcodeWorkspace.projectReferences(xcworkspacedataContents: Data(), baseDir: base), [])
  }
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeWorkspaceTests`
Expected: ビルド失敗 — `type 'XcodeWorkspace' has no member 'projectReferences'`。

- [ ] **Step 3: 最小実装を書く**

`XcodeWorkspace.swift` の `resolveLocation` メソッドの**直後**(enum の閉じ `}` の前)に追加:

```swift
  /// Parse `contents.xcworkspacedata` XML and return every member `.xcodeproj`, fully resolved relative to
  /// `baseDir` (the directory containing the `.xcworkspace`). Recurses into nested `<Group>`s, accumulating
  /// their location prefixes. De-duplicated by resolved path, preserving document order.
  package static func projectReferences(xcworkspacedataContents: Data, baseDir: URL) -> [URL] {
    let parser = XMLParser(data: xcworkspacedataContents)
    let delegate = WorkspaceDataDelegate(workspaceDir: baseDir)
    parser.delegate = delegate
    parser.parse()
    var seen = Set<String>()
    return delegate.projects.filter { seen.insert($0.path).inserted }
  }
```

そして enum の閉じ `}` の**後ろ**、ファイル末尾の `#endif` の**前**に delegate を追加:

```swift
private final class WorkspaceDataDelegate: NSObject, XMLParserDelegate {
  private let workspaceDir: URL
  /// Stack of resolved base directories: the workspace dir, then one entry per open `<Group>`.
  private var baseStack: [URL]
  var projects: [URL] = []

  init(workspaceDir: URL) {
    self.workspaceDir = workspaceDir
    self.baseStack = [workspaceDir]
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String]
  ) {
    let current = baseStack.last ?? workspaceDir
    switch elementName {
    case "Group":
      let resolved = attributeDict["location"].flatMap {
        XcodeWorkspace.resolveLocation($0, currentBase: current, workspaceDir: workspaceDir)
      }
      // A location-less or unresolvable Group does not change the base.
      baseStack.append(resolved ?? current)
    case "FileRef":
      if let location = attributeDict["location"],
        let resolved = XcodeWorkspace.resolveLocation(location, currentBase: current, workspaceDir: workspaceDir),
        resolved.pathExtension == "xcodeproj"
      {
        projects.append(resolved)
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
    if elementName == "Group", baseStack.count > 1 {
      baseStack.removeLast()
    }
  }
}
```

- [ ] **Step 4: テストを実行して成功を確認**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeWorkspaceTests`
Expected: PASS(12 テスト)。

- [ ] **Step 5: コミット**

```bash
git add Sources/BuildServerIntegration/XcodeWorkspace.swift Tests/BuildServerIntegrationTests/XcodeWorkspaceTests.swift
git commit -m "feat(BuildServerIntegration): XcodeWorkspace.projectReferences

Recursive contents.xcworkspacedata parser: resolves FileRef/Group locations,
accumulates nested group prefixes, dedupes, collects member .xcodeproj.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 3: `XcodeWorkspace.memberProjects`(ファイル IO + フォールバック nil)

**Files:**
- Modify: `Sources/BuildServerIntegration/XcodeWorkspace.swift`
- Test: `Tests/BuildServerIntegrationTests/XcodeWorkspaceTests.swift`

`<workspace>/contents.xcworkspacedata` を読み、`projectReferences` を呼ぶ。読めなければ `nil`(呼び出し側がトップレベルグロブにフォールバック)。

- [ ] **Step 1: 失敗するテストを書く**

`XcodeWorkspaceTests.swift` の `#endif` の直前に以下を追加(`makeTempDir` ヘルパ含む):

```swift
  // MARK: - memberProjects

  private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcworkspace-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }

  func testMemberProjectsReadsWorkspacedata() throws {
    let dir = try makeTempDir()
    let workspace = dir.appendingPathComponent("MyWorkspace.xcworkspace", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <Workspace version = "1.0">
         <Group location = "group:Modules">
            <FileRef location = "group:MyLib/MyLib.xcodeproj"></FileRef>
         </Group>
         <FileRef location = "group:MyApp.xcodeproj"></FileRef>
      </Workspace>
      """
    try (xml + "\n").write(
      to: workspace.appendingPathComponent("contents.xcworkspacedata", isDirectory: false),
      atomically: true,
      encoding: .utf8
    )
    let members = try XCTUnwrap(XcodeWorkspace.memberProjects(workspaceURL: workspace)).map(\.path)
    XCTAssertEqual(
      Set(members),
      Set([
        dir.appendingPathComponent("Modules/MyLib/MyLib.xcodeproj").standardizedFileURL.path,
        dir.appendingPathComponent("MyApp.xcodeproj").standardizedFileURL.path,
      ])
    )
  }

  func testMemberProjectsNilWhenFileMissing() throws {
    let dir = try makeTempDir()
    let workspace = dir.appendingPathComponent("Empty.xcworkspace", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    XCTAssertNil(XcodeWorkspace.memberProjects(workspaceURL: workspace))
  }
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeWorkspaceTests`
Expected: ビルド失敗 — `type 'XcodeWorkspace' has no member 'memberProjects'`。

- [ ] **Step 3: 最小実装を書く**

`XcodeWorkspace.swift` の `projectReferences` メソッドの**直前**(`resolveLocation` の後)に追加:

```swift
  /// Member `.xcodeproj`s declared in `workspaceURL`'s `contents.xcworkspacedata`, fully resolved. Returns
  /// `nil` when the file is absent or unreadable, so callers can fall back to a top-level directory scan.
  package static func memberProjects(workspaceURL: URL) -> [URL]? {
    let dataURL = workspaceURL.appendingPathComponent("contents.xcworkspacedata", isDirectory: false)
    guard let data = try? Data(contentsOf: dataURL) else {
      return nil
    }
    return projectReferences(xcworkspacedataContents: data, baseDir: workspaceURL.deletingLastPathComponent())
  }
```

- [ ] **Step 4: テストを実行して成功を確認**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeWorkspaceTests`
Expected: PASS(14 テスト)。

- [ ] **Step 5: コミット**

```bash
git add Sources/BuildServerIntegration/XcodeWorkspace.swift Tests/BuildServerIntegrationTests/XcodeWorkspaceTests.swift
git commit -m "feat(BuildServerIntegration): XcodeWorkspace.memberProjects

Read contents.xcworkspacedata from disk and resolve member .xcodeproj; nil on
read failure so callers fall back to a top-level scan.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 4: テストフィクスチャ `.workspaceWithNestedProject`

**Files:**
- Modify: `Sources/SKTestSupport/XcodeTestProject.swift`
- Test: `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift`

ルートに `MyApp.xcodeproj`(target `MyApp`、`pbxprojTemplate`、A1 prefix)、サブディレクトリ `Modules/App/App.xcodeproj`(target `App`、`duplicateTargetAppBTemplate`、B2 prefix)を配置した `.xcworkspace` を生成。`contents.xcworkspacedata` でルートは直下参照、サブディレクトリはネスト `<Group location="group:Modules">` + `group:App/App.xcodeproj` で参照。既存テンプレートの再利用で ID 衝突を回避(byte-verified pbxproj を新規に書かない)。

- [ ] **Step 1: 失敗するテストを書く**

`Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift` の `#endif`(ファイル末尾)の直前、最後のテストメソッドの後に追加。`XcodeWorkspace` は `import BuildServerIntegration` 経由で利用可能(このファイルは既に `BuildServerIntegration` と `SKTestSupport` を import している):

```swift
  /// The `.workspaceWithNestedProject` fixture writes a contents.xcworkspacedata that references its root
  /// project directly and its subdirectory project through a nested `<Group>`. This validates the fixture
  /// and `XcodeWorkspace.memberProjects` together, without needing Xcode.
  func testNestedWorkspaceFixtureMemberProjects() throws {
    let project = try XcodeTestProject(kind: .workspaceWithNestedProject, sourceContents: "print(\"hi\")\n")
    defer { project.keepAlive() }
    let workspaceURL = try XCTUnwrap(project.workspaceURL)
    let members = Set(
      try XCTUnwrap(XcodeWorkspace.memberProjects(workspaceURL: workspaceURL)).map { $0.standardizedFileURL.path }
    )
    XCTAssertEqual(
      members,
      Set([
        project.projectRoot.appendingPathComponent("MyApp.xcodeproj").standardizedFileURL.path,
        project.projectRoot.appendingPathComponent("Modules/App/App.xcodeproj").standardizedFileURL.path,
      ])
    )
  }
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeBuildServerTests/testNestedWorkspaceFixtureMemberProjects`
Expected: ビルド失敗 — `type 'XcodeTestProject.Kind' has no member 'workspaceWithNestedProject'`。

- [ ] **Step 3: フィクスチャを実装する**

`Sources/SKTestSupport/XcodeTestProject.swift` を編集。

(3a) `Kind` enum(`case workspaceWithDuplicateTargetNames` の後)に追加:

```swift
    /// A `.xcworkspace` bundling a root project (`MyApp.xcodeproj`, target `MyApp`) and a subdirectory
    /// project (`Modules/App/App.xcodeproj`, target `App`), the latter referenced via a nested `<Group>`
    /// in `contents.xcworkspacedata`. Exercises subdirectory member-project resolution.
    case workspaceWithNestedProject
```

(3b) `init` の `xcodeprojURL`/`workspaceURL` を決める `switch kind` に arm を追加:

```swift
    case .workspaceWithNestedProject:
      self.xcodeprojURL = root.appendingPathComponent("MyApp.xcodeproj", isDirectory: true)
      self.workspaceURL = root.appendingPathComponent("MyWorkspace.xcworkspace", isDirectory: true)
```

(3c) `sourceFileURL` を決める `switch kind` の `main.swift` at root の arm に新 kind を追加:

```swift
    case .macOSCommandLineTool, .iOSApp, .appWithUnitTestTarget, .appWithPackageDependency,
      .workspaceWithNestedProject:
      self.sourceFileURL = root.appendingPathComponent("main.swift", isDirectory: false)
```

(3d) 単一プロジェクト生成のガードを両ワークスペース kind 除外に変更:

変更前:
```swift
    if kind != .workspaceWithDuplicateTargetNames {
```
変更後:
```swift
    if kind != .workspaceWithDuplicateTargetNames && kind != .workspaceWithNestedProject {
```

(3e) 同ブロック内の `template` 選択 `switch kind` にある preconditionFailure arm に新 kind を併記:

変更前:
```swift
      case .workspaceWithDuplicateTargetNames:
        // Unreachable: excluded by the enclosing `if kind != .workspaceWithDuplicateTargetNames`.
        // This arm exists only to keep the switch exhaustive; workspace projects are generated below.
        preconditionFailure(
          "workspaceWithDuplicateTargetNames is generated separately, not via the single-project template"
        )
```
変更後:
```swift
      case .workspaceWithDuplicateTargetNames, .workspaceWithNestedProject:
        // Unreachable: excluded by the enclosing guard. This arm exists only to keep the switch
        // exhaustive; workspace projects are generated in dedicated blocks below.
        preconditionFailure("workspace kinds are generated separately, not via the single-project template")
```

(3f) `.workspaceWithDuplicateTargetNames` 生成ブロック(`if case .workspaceWithDuplicateTargetNames = kind { ... }`)の**後ろ**、`init` の閉じ `}` の前に新ブロックを追加:

```swift
    if case .workspaceWithNestedProject = kind {
      // Root project: MyApp.xcodeproj (target MyApp, A1-prefixed ids), with main.swift at the project root.
      try fileManager.createDirectory(at: xcodeprojURL, withIntermediateDirectories: true)
      try Self.pbxprojTemplate.write(
        to: xcodeprojURL.appendingPathComponent("project.pbxproj", isDirectory: false),
        atomically: true,
        encoding: .utf8
      )
      try sourceContents.write(to: sourceFileURL, atomically: true, encoding: .utf8)

      // Subdirectory project: Modules/App/App.xcodeproj (target App, B2-prefixed ids => no id collision
      // with the root project), with its own main.swift as a sibling of the .xcodeproj.
      let subProjDir = root.appendingPathComponent("Modules/App", isDirectory: true)
      let subXcodeproj = subProjDir.appendingPathComponent("App.xcodeproj", isDirectory: true)
      try fileManager.createDirectory(at: subXcodeproj, withIntermediateDirectories: true)
      try Self.duplicateTargetAppBTemplate.write(
        to: subXcodeproj.appendingPathComponent("project.pbxproj", isDirectory: false),
        atomically: true,
        encoding: .utf8
      )
      try sourceContents.write(
        to: subProjDir.appendingPathComponent("main.swift", isDirectory: false),
        atomically: true,
        encoding: .utf8
      )

      // Workspace: root project referenced directly; subdir project via a nested <Group location="group:Modules">.
      let workspace = root.appendingPathComponent("MyWorkspace.xcworkspace", isDirectory: true)
      try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
      let contents = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Workspace version = "1.0">
           <FileRef location = "group:MyApp.xcodeproj"></FileRef>
           <Group location = "group:Modules">
              <FileRef location = "group:App/App.xcodeproj"></FileRef>
           </Group>
        </Workspace>
        """
      try (contents + "\n").write(
        to: workspace.appendingPathComponent("contents.xcworkspacedata", isDirectory: false),
        atomically: true,
        encoding: .utf8
      )
    }
```

(3g) 型 doc コメント(`XcodeTestProject` 宣言直前)の説明文に一文追加(任意だが推奨):

`/// ... each with a target named `App`.` の段落の後に:
```
/// `.workspaceWithNestedProject` produces a `.xcworkspace` bundling a root `MyApp.xcodeproj` (target
/// `MyApp`) and a subdirectory `Modules/App/App.xcodeproj` (target `App`) referenced via a nested
/// `<Group>`, exercising subdirectory member-project resolution.
```

- [ ] **Step 4: テストを実行して成功を確認**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeBuildServerTests/testNestedWorkspaceFixtureMemberProjects`
Expected: PASS。

- [ ] **Step 5: コミット**

```bash
git add Sources/SKTestSupport/XcodeTestProject.swift Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift
git commit -m "test(SKTestSupport): workspaceWithNestedProject fixture

A .xcworkspace whose subdirectory member project is referenced through a nested
<Group>, plus a (non-Xcode) test asserting XcodeWorkspace.memberProjects resolves
both members.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 5: `XcodeScheme.searchContainers()` をメンバー解決ベースに

**Files:**
- Modify: `Sources/BuildServerIntegration/XcodeScheme.swift:75-83`
- Test: `Tests/BuildServerIntegrationTests/XcodeSchemeTests.swift`

scheme ファイル探索のコンテナ列挙を `XcodeWorkspace.memberProjects` ベースに置き換え(失敗時のみ従来のトップレベルグロブ)。サブディレクトリ member 内の scheme が発見されるようになる。

- [ ] **Step 1: 失敗するテストを書く**

`Tests/BuildServerIntegrationTests/XcodeSchemeTests.swift` の `// MARK: - resolveContainer` の**直前**に追加(既存の `makeTempDir` / `writeSchemeWithContainer` ヘルパを利用):

```swift
  func testBuildTargetsFindsSchemeInSubdirectoryMemberViaNestedGroup() throws {
    // The workspace references a member .xcodeproj nested in a subdirectory via <Group>. The scheme lives in
    // that subdir project; discovery must follow contents.xcworkspacedata, not a top-level glob.
    let root = try makeTempDir()
    let workspace = root.appendingPathComponent("MyWorkspace.xcworkspace", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let workspacedata = """
      <?xml version="1.0" encoding="UTF-8"?>
      <Workspace version = "1.0">
         <Group location = "group:Modules">
            <FileRef location = "group:MyLib/MyLib.xcodeproj"></FileRef>
         </Group>
      </Workspace>
      """
    try (workspacedata + "\n").write(
      to: workspace.appendingPathComponent("contents.xcworkspacedata", isDirectory: false),
      atomically: true,
      encoding: .utf8
    )
    let member = root.appendingPathComponent("Modules/MyLib/MyLib.xcodeproj", isDirectory: true)
    try writeSchemeWithContainer(
      "MyLib",
      into: member.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true),
      blueprintName: "MyLib",
      container: "MyLib.xcodeproj"
    )
    let result = try XCTUnwrap(
      XcodeScheme.buildTargets(scheme: "MyLib", containerPath: workspace, projectRoot: root)
    )
    XCTAssertEqual(result.first?.blueprintName, "MyLib")
  }
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeSchemeTests/testBuildTargetsFindsSchemeInSubdirectoryMemberViaNestedGroup`
Expected: FAIL — `XCTUnwrap` で nil(現状 `searchContainers` はトップレベルしか見ず、サブディレクトリの member project を見つけられないため scheme 未発見)。

- [ ] **Step 3: 実装を変更する**

`Sources/BuildServerIntegration/XcodeScheme.swift` の `searchContainers` を置き換え:

変更前:
```swift
  /// Containers to search for scheme files: the container itself, plus (for a workspace) member
  /// `.xcodeproj`s directly under `projectRoot`.
  private static func searchContainers(containerPath: URL, projectRoot: URL) -> [URL] {
    var containers = [containerPath]
    if containerPath.pathExtension == "xcworkspace",
      let entries = try? FileManager.default.contentsOfDirectory(at: projectRoot, includingPropertiesForKeys: nil)
    {
      containers.append(contentsOf: entries.filter { $0.pathExtension == "xcodeproj" }.sorted { $0.path < $1.path })
    }
    return containers
  }
```
変更後:
```swift
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
```

- [ ] **Step 4: テストを実行して成功を確認**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeSchemeTests`
Expected: PASS(新規 1 件 + 既存全件。特にフォールバックに依存する `testBuildTargetsFindsSchemeInWorkspaceMemberProject` も通る)。

- [ ] **Step 5: コミット**

```bash
git add Sources/BuildServerIntegration/XcodeScheme.swift Tests/BuildServerIntegrationTests/XcodeSchemeTests.swift
git commit -m "feat(BuildServerIntegration): scheme search uses workspace membership

searchContainers() now enumerates member .xcodeproj from contents.xcworkspacedata
(falling back to a top-level scan), so schemes in subdirectory member projects are
found.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 6: `XcodeBuildServer.rootProjectPaths()` をメンバー解決ベースに(`.dependency` 誤タグ修正)

**Files:**
- Modify: `Sources/BuildServerIntegration/XcodeBuildServer.swift:142-151`
- Test: `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift`(統合テスト、`skipUnlessXcodeAvailable()`)

`.dependency` タグ付けの基準集合をメンバー解決ベースに置き換え。サブディレクトリの member project のターゲットが誤って `.dependency` タグになる潜在バグを修正。

- [ ] **Step 1: 失敗するテストを書く**

`Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift` の `testNestedWorkspaceFixtureMemberProjects`(Task 4 で追加)の後に追加:

```swift
  /// Real SwiftBuild integration: every project in `.workspaceWithNestedProject` (the root MyApp.xcodeproj
  /// and the subdirectory Modules/App/App.xcodeproj) is a workspace member, so no target may be tagged
  /// `.dependency`. Before parsing contents.xcworkspacedata, rootProjectPaths() globbed only the top level
  /// and missed the subdir project, mis-tagging its target as a dependency.
  func testWorkspaceMemberInSubdirectoryNotTaggedAsDependency() async throws {
    try skipUnlessXcodeAvailable()

    let project = try XcodeTestProject(kind: .workspaceWithNestedProject, sourceContents: "print(\"hi\")\n")
    defer { project.keepAlive() }

    let workspaceURL = try XCTUnwrap(project.workspaceURL)
    let buildServer = try await XcodeBuildServer(
      projectRoot: project.projectRoot,
      containerPath: workspaceURL,
      toolchainRegistry: .forTesting,
      options: SourceKitLSPOptions(),
      connectionToSourceKitLSP: LocalConnection(receiverName: "Dummy SourceKit-LSP")
    )
    addTeardownBlock { await buildServer.close() }

    let targetsResponse = try await buildServer.buildTargets(request: WorkspaceBuildTargetsRequest())
    let dependencyTargets = targetsResponse.targets.filter { $0.tags.contains(.dependency) }
    XCTAssertTrue(
      dependencyTargets.isEmpty,
      "no workspace member should be tagged .dependency, got: \(dependencyTargets.map(\.displayName))"
    )

    // Sanity: the subdirectory project actually loaded (its sources are present).
    let sourcesResponse = try await buildServer.buildTargetSources(
      request: BuildTargetSourcesRequest(targets: targetsResponse.targets.map(\.id))
    )
    let sourcePaths = sourcesResponse.items.flatMap(\.sources).compactMap { $0.uri.fileURL?.path }
    XCTAssertTrue(
      sourcePaths.contains { $0.contains("/Modules/App/") },
      "expected the subdirectory member project's sources to be present, got: \(sourcePaths)"
    )
  }
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeBuildServerTests/testWorkspaceMemberInSubdirectoryNotTaggedAsDependency`
Expected: FAIL — サブディレクトリの `App` ターゲットが `.dependency` タグ付き(現状 `rootProjectPaths()` がトップレベルグロブで `Modules/App/App.xcodeproj` を見落とすため)。`dependencyTargets` が空でなく `XCTAssertTrue` 失敗。
(注: Xcode 不在環境では `XCTSkip`。ローカル Xcode 26.4 で確認すること。初回ビルドは数分かかる場合あり。)

- [ ] **Step 3: 実装を変更する**

`Sources/BuildServerIntegration/XcodeBuildServer.swift` の `rootProjectPaths` を置き換え:

変更前:
```swift
  private func rootProjectPaths() -> Set<URL> {
    if containerPath.pathExtension == "xcworkspace" {
      let entries =
        orLog("Enumerating member projects under \(projectRoot.path)") {
          try FileManager.default.contentsOfDirectory(at: projectRoot, includingPropertiesForKeys: nil)
        } ?? []
      return Set(entries.filter { $0.pathExtension == "xcodeproj" })
    }
    return [containerPath]
  }
```
変更後:
```swift
  private func rootProjectPaths() -> Set<URL> {
    if containerPath.pathExtension == "xcworkspace" {
      if let members = XcodeWorkspace.memberProjects(workspaceURL: containerPath) {
        return Set(members)
      }
      // Fallback when contents.xcworkspacedata is absent/unreadable: previous top-level scan behavior.
      let entries =
        orLog("Enumerating member projects under \(projectRoot.path)") {
          try FileManager.default.contentsOfDirectory(at: projectRoot, includingPropertiesForKeys: nil)
        } ?? []
      return Set(entries.filter { $0.pathExtension == "xcodeproj" })
    }
    return [containerPath]
  }
```

doc コメント(142 行直上)の `the member `.xcodeproj`s directly under `projectRoot`` を `the member `.xcodeproj`s declared in its `contents.xcworkspacedata`` に更新。

- [ ] **Step 4: テストを実行して成功を確認**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeBuildServerTests/testWorkspaceMemberInSubdirectoryNotTaggedAsDependency`
Expected: PASS(Xcode 利用可能時)。

- [ ] **Step 5: コミット**

```bash
git add Sources/BuildServerIntegration/XcodeBuildServer.swift Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift
git commit -m "fix(BuildServerIntegration): root project set from contents.xcworkspacedata

rootProjectPaths() enumerates member .xcodeproj via XcodeWorkspace.memberProjects
(falling back to a top-level scan). Fixes subdirectory-organized workspaces whose
empty top-level scan mis-tagged all members as .dependency.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 7: フォーマット + 全体回帰 + 最終コミット

**Files:** なし(検証のみ)

- [ ] **Step 1: フォーマット適用**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift format -ipr Sources/BuildServerIntegration/XcodeWorkspace.swift Sources/BuildServerIntegration/XcodeScheme.swift Sources/BuildServerIntegration/XcodeBuildServer.swift Sources/SKTestSupport/XcodeTestProject.swift Tests/BuildServerIntegrationTests/XcodeWorkspaceTests.swift Tests/BuildServerIntegrationTests/XcodeSchemeTests.swift Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift`
Expected: 差分が出れば取り込む。

- [ ] **Step 2: lint 確認**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift format lint --strict Sources/BuildServerIntegration/XcodeWorkspace.swift`
Expected: 出力なし(違反なし)。

- [ ] **Step 3: BuildServerIntegrationTests 全体を実行**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter BuildServerIntegrationTests`
Expected: 全件 PASS(既存 148 件 + 本作業の新規。Xcode 26.4 利用可能環境で統合テスト含め 0 失敗)。

- [ ] **Step 4: フォーマット差分があればコミット**

```bash
git add -A
git commit -m "style(BuildServerIntegration): swift-format workspace resolution changes

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```
(差分が無ければこの Step はスキップ。)

---

## スコープ外 / フォローアップ(本プランで実装しない)

- `BlueprintIdentifier` → GUID 照合(scheme ターゲット照合の厳密化)。
- project reference(別 `.xcodeproj` を project reference する構成)経由のターゲット解決。
- workspace が別 `.xcworkspace` を参照する構成。
- visionOS(`xros`/`xrsimulator`)プラットフォーム対応。
