# Xcode スキーム同名ターゲット曖昧性解消 実装プラン

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `.xcworkspace` 内の複数 `.xcodeproj` に同名ターゲットがあるとき、スキームの `ReferencedContainer` を絶対 `.xcodeproj` パスに解決し、既存の `XcodeTarget.projectFilePath` と照合してスコープ起点を正しいプロジェクトのターゲットだけに限定する。

**Architecture:** スキーム XML パーサが各 `BuildableReference` から `BlueprintName` と `ReferencedContainer` を抽出する（`SchemeBuildableReference`）。`XcodeScheme.buildTargets` がコンテナの相対パスをスキームファイルの所属コンテナ基準で絶対 URL へ解決する（`SchemeBuildTarget`）。`XcodeBuildServer.resolveScheme` が「名前一致 かつ（両側にパス情報があるときのみ）コンテナパス一致」で起点 GUID を決める。コンテナ情報が欠ける場合は従来どおり名前一致にフォールバック（後方互換）。

**Tech Stack:** Swift, `Foundation` / `FoundationXML`（`XMLParser`）, SwiftBuild（`import SwiftBuild` は `SwiftBuildSession` に隔離、本変更では非依存層のみ拡張）, XCTest。

**設計 spec:** `docs/superpowers/specs/2026-05-27-xcode-scheme-container-disambiguation-design.md`

**ビルド/テスト環境（全タスク共通）:**
- ビルド: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift build`
- 単体テスト（Xcode 不要、Task 1-3）例: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeSchemeTests`
- 統合テスト（実 Xcode + 実 SwiftBuild、Task 5）: `xcodebuild` が必要。`skipUnlessXcodeAvailable()` で自動スキップされる。

**型と関数の最終形（タスクをまたいで一貫させる）:**
- `XcodeScheme.SchemeBuildableReference { blueprintName: String; referencedContainer: String? }`（Hashable, Sendable）— パース結果（生の `container:` 文字列）。
- `XcodeScheme.SchemeBuildTarget { blueprintName: String; container: URL? }`（Equatable, Sendable）— コンテナ解決後。
- `XcodeScheme.buildActionReferences(xcschemeContents: Data) -> [SchemeBuildableReference]`（旧 `buildActionTargetNames` を置換）。
- `XcodeScheme.resolveContainer(_ referencedContainer: String?, relativeTo baseDir: URL) -> URL?`。
- `XcodeScheme.buildTargets(scheme: String, containerPath: URL, projectRoot: URL) -> [SchemeBuildTarget]?`（旧 `targetNames` を置換）。
- `XcodeBuildServer.normalizedPath(_ url: URL) -> String`（`isPartOfRootProject` から抽出した共有ヘルパ）。
- `XcodeBuildServer.resolveScheme(named: String, schemeTargets: [SchemeBuildTarget]?, allTargets: [XcodeTarget]) -> SchemeResolution`（旧 `schemeTargetNames:` を置換）。
- `XcodeTestProject.Kind.workspaceWithDuplicateTargetNames` と `XcodeTestProject.workspaceURL: URL?`。

---

## File Structure

- `Sources/BuildServerIntegration/XcodeScheme.swift`（変更）: 新規 2 構造体、`ReferencedContainer` 捕捉、`resolveContainer`、`buildActionReferences` / `buildTargets` へのリネーム、`schemeFileURL` が一致コンテナも返すよう変更。SwiftBuild 非依存を維持。
- `Sources/BuildServerIntegration/XcodeBuildServer.swift`（変更）: `normalizedPath` 共有ヘルパ抽出、`resolveScheme` のコンテナフィルタ、`applySchemeScope` の呼び出し更新。
- `Sources/SKTestSupport/XcodeTestProject.swift`（変更）: 新 `Kind`、`workspaceURL`、2 プロジェクト `.xcworkspace` 生成、ワークスペース共有スキーム書き出しヘルパ、pbxproj テンプレート 2 種。
- `Tests/BuildServerIntegrationTests/XcodeSchemeTests.swift`（変更）: パース／解決の単体テストを新 API へ移行＋コンテナ抽出・解決を検証。
- `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift`（変更）: `resolveScheme` 単体テストを新シグネチャへ移行＋同名曖昧性解消テスト追加、重複名ワークスペースの統合テスト追加。

---

## Task 1: 共有パスヘルパ抽出 + `resolveContainer`

**Files:**
- Modify: `Sources/BuildServerIntegration/XcodeBuildServer.swift:328-337`（`isPartOfRootProject`）
- Modify: `Sources/BuildServerIntegration/XcodeScheme.swift`（`XcodeScheme` enum に静的関数追加）
- Test: `Tests/BuildServerIntegrationTests/XcodeSchemeTests.swift`（`resolveContainer` の単体テスト追加）

- [ ] **Step 1: `resolveContainer` の失敗テストを書く**

`Tests/BuildServerIntegrationTests/XcodeSchemeTests.swift` の `#if !NO_SWIFTPM_DEPENDENCY` ブロック内・`#endif` の直前に追加:

```swift
  // MARK: - resolveContainer

  func testResolveContainerResolvesRelativeToBaseDir() {
    let base = URL(fileURLWithPath: "/ws", isDirectory: true)
    XCTAssertEqual(
      XcodeScheme.resolveContainer("container:AppA/AppA.xcodeproj", relativeTo: base)?.standardizedFileURL.path,
      "/ws/AppA/AppA.xcodeproj"
    )
  }

  func testResolveContainerReturnsNilForNilOrNonContainerPrefix() {
    let base = URL(fileURLWithPath: "/ws", isDirectory: true)
    XCTAssertNil(XcodeScheme.resolveContainer(nil, relativeTo: base))
    XCTAssertNil(XcodeScheme.resolveContainer("AppA.xcodeproj", relativeTo: base))
    XCTAssertNil(XcodeScheme.resolveContainer("container:", relativeTo: base))
  }
```

- [ ] **Step 2: 失敗を確認**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeSchemeTests/testResolveContainerResolvesRelativeToBaseDir`
Expected: コンパイルエラー（`resolveContainer` 未定義）または FAIL。

- [ ] **Step 3: `resolveContainer` を実装**

`Sources/BuildServerIntegration/XcodeScheme.swift` の `XcodeScheme` enum 内（`buildActionTargetNames` の直後あたり）に追加:

```swift
  /// Resolve a scheme `BuildableReference`'s `ReferencedContainer` (e.g. `container:AppA/AppA.xcodeproj`)
  /// to an absolute `.xcodeproj` URL, relative to `baseDir` (the directory holding the container that owns
  /// the scheme file). Returns `nil` when the attribute is absent, not `container:`-prefixed, or empty —
  /// callers then fall back to matching by target name alone.
  ///
  /// Uses `standardizedFileURL` (resolves `.`/`..` but not symlinks) so the result stays comparable to the
  /// caller-supplied `baseDir`; symlink canonicalization happens later in `XcodeBuildServer.resolveScheme`.
  package static func resolveContainer(_ referencedContainer: String?, relativeTo baseDir: URL) -> URL? {
    guard let raw = referencedContainer, raw.hasPrefix("container:") else {
      return nil
    }
    let relativePath = String(raw.dropFirst("container:".count))
    guard !relativePath.isEmpty else {
      return nil
    }
    return URL(fileURLWithPath: relativePath, relativeTo: baseDir).standardizedFileURL
  }
```

- [ ] **Step 4: テスト通過を確認**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeSchemeTests/testResolveContainer`
Expected: PASS（2 メソッド）。

- [ ] **Step 5: `normalizedPath` 共有ヘルパを抽出（リファクタ、挙動不変）**

`Sources/BuildServerIntegration/XcodeBuildServer.swift` の `isPartOfRootProject`(`:328-337`) を、ローカル関数 `normalized` を `package static func normalizedPath` に切り出して書き換える:

```swift
  /// Canonical path of `url` for on-disk equality comparison (resolves symlinks). Shared by
  /// `isPartOfRootProject` and `resolveScheme`'s container matching.
  package static func normalizedPath(_ url: URL) -> String {
    url.resolvingSymlinksInPath().path
  }

  package static func isPartOfRootProject(projectFilePath: URL?, rootProjectPaths: Set<URL>) -> Bool {
    guard let projectFilePath else {
      return true
    }
    let normalizedProjectPath = normalizedPath(projectFilePath)
    return rootProjectPaths.contains { normalizedPath($0) == normalizedProjectPath }
  }
```

- [ ] **Step 6: 既存 `isPartOfRootProject` テストで非回帰を確認**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeBuildServerTests/testRootProjectTargetIsPartOfRootProject`
Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeBuildServerTests/testWorkspaceMemberProjectIsPartOfRootProject`
Expected: 両方 PASS。

- [ ] **Step 7: コミット**

```bash
git add Sources/BuildServerIntegration/XcodeScheme.swift Sources/BuildServerIntegration/XcodeBuildServer.swift Tests/BuildServerIntegrationTests/XcodeSchemeTests.swift
git commit -m "feat(BuildServerIntegration): resolveContainer + shared normalizedPath helper

Task context: スキーム同名ターゲット曖昧性解消（#2, ReferencedContainer 照合）の
土台。container: 相対パスを絶対 .xcodeproj URL に解決する純粋関数と、
isPartOfRootProject から抽出した symlink 正規化ヘルパを共有化。

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 2: `ReferencedContainer` のパース + `buildTargets` 解決

**Files:**
- Modify: `Sources/BuildServerIntegration/XcodeScheme.swift`（構造体追加、デリゲート・関数のリネーム/拡張、`schemeFileURL` 戻り値変更）
- Modify: `Sources/BuildServerIntegration/XcodeBuildServer.swift:94-99`（`applySchemeScope` の呼び出しを `buildTargets` に更新。`resolveScheme` は名前マップで従来挙動を維持）
- Test: `Tests/BuildServerIntegrationTests/XcodeSchemeTests.swift`（パース／解決テストを新 API へ移行）

- [ ] **Step 1: 新 API での失敗テストを書く（既存パーステストを置換）**

`Tests/BuildServerIntegrationTests/XcodeSchemeTests.swift` の `entry(blueprintName:)` ヘルパに任意のコンテナ指定を追加し、既存の `testParses... / testEmpty... / testDeduplicates... / testIgnores...` 群と `testTargetNames...` 群を新 API へ置き換える。

`entry` を次に置換:

```swift
  private func entry(blueprintName: String, container: String = "MyApp.xcodeproj") -> String {
    """
          <BuildActionEntry buildForRunning="YES">
             <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="\(blueprintName)" BuildableName="\(blueprintName)" BlueprintName="\(blueprintName)" ReferencedContainer="container:\(container)"></BuildableReference>
          </BuildActionEntry>
    """
  }
```

パーステスト群を次に置換:

```swift
  func testParsesBuildActionReferencesWithContainer() {
    let data = scheme(buildEntries: entry(blueprintName: "App") + "\n" + entry(blueprintName: "Framework"))
    XCTAssertEqual(
      XcodeScheme.buildActionReferences(xcschemeContents: data),
      [
        XcodeScheme.SchemeBuildableReference(blueprintName: "App", referencedContainer: "container:MyApp.xcodeproj"),
        XcodeScheme.SchemeBuildableReference(blueprintName: "Framework", referencedContainer: "container:MyApp.xcodeproj"),
      ]
    )
  }

  func testEmptyBuildActionReturnsEmpty() {
    let data = scheme(buildEntries: "")
    XCTAssertEqual(XcodeScheme.buildActionReferences(xcschemeContents: data), [])
  }

  func testDeduplicatesByNameAndContainer() {
    // Same name + same container collapses to one; same name + different container stays distinct.
    let data = scheme(
      buildEntries: entry(blueprintName: "App") + "\n" + entry(blueprintName: "App") + "\n"
        + entry(blueprintName: "App", container: "Other.xcodeproj")
    )
    XCTAssertEqual(
      XcodeScheme.buildActionReferences(xcschemeContents: data),
      [
        XcodeScheme.SchemeBuildableReference(blueprintName: "App", referencedContainer: "container:MyApp.xcodeproj"),
        XcodeScheme.SchemeBuildableReference(blueprintName: "App", referencedContainer: "container:Other.xcodeproj"),
      ]
    )
  }

  func testIgnoresBuildableReferencesOutsideBuildAction() {
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
    XCTAssertEqual(
      XcodeScheme.buildActionReferences(xcschemeContents: data),
      [XcodeScheme.SchemeBuildableReference(blueprintName: "App", referencedContainer: "container:MyApp.xcodeproj")]
    )
  }
```

`buildTargets` 群（旧 `targetNames` 群）を次に置換。`container` が絶対 URL へ解決されることを検証する:

```swift
  func testBuildTargetsFindsSharedSchemeAndResolvesContainer() throws {
    let root = try makeTempDir()
    let container = root.appendingPathComponent("MyApp.xcodeproj", isDirectory: true)
    try writeScheme(
      "MyApp",
      into: container.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true),
      blueprintName: "MyApp"
    )
    let result = try XCTUnwrap(XcodeScheme.buildTargets(scheme: "MyApp", containerPath: container, projectRoot: root))
    XCTAssertEqual(result.map(\.blueprintName), ["MyApp"])
    XCTAssertEqual(
      result.first?.container?.standardizedFileURL.path,
      root.appendingPathComponent("MyApp.xcodeproj").standardizedFileURL.path
    )
  }

  func testBuildTargetsPrefersSharedOverUser() throws {
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
      XcodeScheme.buildTargets(scheme: "MyApp", containerPath: container, projectRoot: root)?.map(\.blueprintName),
      ["SharedTarget"]
    )
  }

  func testBuildTargetsFindsUserSchemeWhenNoShared() throws {
    let root = try makeTempDir()
    let container = root.appendingPathComponent("MyApp.xcodeproj", isDirectory: true)
    try writeScheme(
      "MyApp",
      into: container.appendingPathComponent("xcuserdata/me.xcuserdatad/xcschemes", isDirectory: true),
      blueprintName: "UserTarget"
    )
    XCTAssertEqual(
      XcodeScheme.buildTargets(scheme: "MyApp", containerPath: container, projectRoot: root)?.map(\.blueprintName),
      ["UserTarget"]
    )
  }

  func testBuildTargetsReturnsNilWhenMissing() throws {
    let root = try makeTempDir()
    let container = root.appendingPathComponent("MyApp.xcodeproj", isDirectory: true)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    XCTAssertNil(XcodeScheme.buildTargets(scheme: "Nope", containerPath: container, projectRoot: root))
  }

  func testBuildTargetsResolvesContainerRelativeToMatchedContainerDir() throws {
    // Workspace shared scheme: container references resolve relative to the workspace's parent dir.
    let root = try makeTempDir()
    let workspace = root.appendingPathComponent("MyWorkspace.xcworkspace", isDirectory: true)
    try writeSchemeWithContainer(
      "App",
      into: workspace.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true),
      blueprintName: "App",
      container: "AppA/AppA.xcodeproj"
    )
    let result = try XCTUnwrap(XcodeScheme.buildTargets(scheme: "App", containerPath: workspace, projectRoot: root))
    XCTAssertEqual(result.first?.blueprintName, "App")
    XCTAssertEqual(
      result.first?.container?.standardizedFileURL.path,
      root.appendingPathComponent("AppA/AppA.xcodeproj").standardizedFileURL.path
    )
  }
```

`writeScheme` の隣に、コンテナを明示指定できるヘルパを追加:

```swift
  private func writeSchemeWithContainer(
    _ name: String,
    into schemesDir: URL,
    blueprintName: String,
    container: String
  ) throws {
    try FileManager.default.createDirectory(at: schemesDir, withIntermediateDirectories: true)
    let data = scheme(buildEntries: entry(blueprintName: blueprintName, container: container))
    try data.write(to: schemesDir.appendingPathComponent("\(name).xcscheme", isDirectory: false))
  }
```

- [ ] **Step 2: 失敗を確認**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeSchemeTests`
Expected: コンパイルエラー（`SchemeBuildableReference` / `buildActionReferences` / `buildTargets` 未定義）。

- [ ] **Step 3: `XcodeScheme.swift` を新 API に実装**

`Sources/BuildServerIntegration/XcodeScheme.swift` を次のように変更する。

(a) `package import Foundation` の下、`XcodeScheme` enum の前に 2 構造体を追加:

```swift
/// One `BuildableReference` parsed from a scheme's `BuildAction`, before container path resolution.
package struct SchemeBuildableReference: Hashable, Sendable {
  /// The `BlueprintName` attribute (the target name).
  package var blueprintName: String
  /// The raw `ReferencedContainer` attribute (e.g. `container:AppA/AppA.xcodeproj`), or `nil` if absent.
  package var referencedContainer: String?

  package init(blueprintName: String, referencedContainer: String?) {
    self.blueprintName = blueprintName
    self.referencedContainer = referencedContainer
  }
}

/// A scheme Build-action target with its `ReferencedContainer` resolved to an absolute `.xcodeproj` path.
package struct SchemeBuildTarget: Equatable, Sendable {
  /// The target name (`BlueprintName`).
  package var blueprintName: String
  /// The owning `.xcodeproj` absolute path, or `nil` when no resolvable container was present.
  package var container: URL?

  package init(blueprintName: String, container: URL?) {
    self.blueprintName = blueprintName
    self.container = container
  }
}
```

(b) `targetNames(...)` を `buildTargets(...)` に置換（コンテナ解決を行う）:

```swift
  /// Locate the `.xcscheme` named `scheme` and return its `BuildAction` targets, with each
  /// `ReferencedContainer` resolved to an absolute `.xcodeproj` path (relative to the directory of the
  /// container the scheme file was found in). Returns `nil` if no matching file exists.
  package static func buildTargets(scheme: String, containerPath: URL, projectRoot: URL) -> [SchemeBuildTarget]? {
    guard let (url, container) = schemeFileURL(scheme: scheme, containerPath: containerPath, projectRoot: projectRoot),
      let data = try? Data(contentsOf: url)
    else {
      return nil
    }
    let baseDir = container.deletingLastPathComponent()
    return buildActionReferences(xcschemeContents: data).map { reference in
      SchemeBuildTarget(
        blueprintName: reference.blueprintName,
        container: resolveContainer(reference.referencedContainer, relativeTo: baseDir)
      )
    }
  }
```

(c) `schemeFileURL` が一致したコンテナ URL も返すよう戻り値を変更:

```swift
  private static func schemeFileURL(
    scheme: String,
    containerPath: URL,
    projectRoot: URL
  ) -> (url: URL, container: URL)? {
    let fm = FileManager.default
    let containers = searchContainers(containerPath: containerPath, projectRoot: projectRoot)

    // Shared schemes first, across all candidate containers.
    for container in containers {
      let shared = container.appendingPathComponent("xcshareddata/xcschemes/\(scheme).xcscheme", isDirectory: false)
      if fm.fileExists(atPath: shared.path) {
        return (shared, container)
      }
    }
    // Then user schemes: xcuserdata/<anything>.xcuserdatad/xcschemes/<name>.xcscheme
    for container in containers {
      let userdata = container.appendingPathComponent("xcuserdata", isDirectory: true)
      guard let userDirs = try? fm.contentsOfDirectory(at: userdata, includingPropertiesForKeys: nil) else {
        continue
      }
      for dir in userDirs where dir.pathExtension == "xcuserdatad" {
        let candidate = dir.appendingPathComponent("xcschemes/\(scheme).xcscheme", isDirectory: false)
        if fm.fileExists(atPath: candidate.path) {
          return (candidate, container)
        }
      }
    }
    return nil
  }
```

(d) `buildActionTargetNames` を `buildActionReferences` に置換:

```swift
  /// Extract the `BuildableReference`s (name + `ReferencedContainer`) referenced by a scheme's
  /// `BuildAction`. References in `TestAction`/`LaunchAction`/etc. are ignored. De-duplicated by
  /// (name, container) pair, preserving order.
  package static func buildActionReferences(xcschemeContents: Data) -> [SchemeBuildableReference] {
    let parser = XMLParser(data: xcschemeContents)
    let delegate = BuildActionDelegate()
    parser.delegate = delegate
    parser.parse()
    var seen = Set<SchemeBuildableReference>()
    return delegate.references.filter { seen.insert($0).inserted }
  }
```

(e) `BuildActionDelegate` がコンテナも捕捉するよう変更:

```swift
private final class BuildActionDelegate: NSObject, XMLParserDelegate {
  var references: [SchemeBuildableReference] = []
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
        references.append(
          SchemeBuildableReference(blueprintName: name, referencedContainer: attributeDict["ReferencedContainer"])
        )
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
```

- [ ] **Step 4: `applySchemeScope` の呼び出しを更新（この時点では挙動不変）**

`Sources/BuildServerIntegration/XcodeBuildServer.swift:94-99` を変更。`buildTargets` を呼び、`resolveScheme` には従来どおり名前リストを渡す（コンテナフィルタは Task 3 で有効化）:

```swift
    let schemeTargets = XcodeScheme.buildTargets(
      scheme: scheme,
      containerPath: containerPath,
      projectRoot: projectRoot
    )
    switch Self.resolveScheme(named: scheme, schemeTargetNames: schemeTargets?.map(\.blueprintName), allTargets: all) {
```

- [ ] **Step 5: 単体テスト + 既存スキームスコープテストで通過・非回帰を確認**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeSchemeTests`
Expected: 全 PASS。
Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift build`
Expected: ビルド成功（`applySchemeScope` が新 `buildTargets` を使う）。

- [ ] **Step 6: コミット**

```bash
git add Sources/BuildServerIntegration/XcodeScheme.swift Sources/BuildServerIntegration/XcodeBuildServer.swift Tests/BuildServerIntegrationTests/XcodeSchemeTests.swift
git commit -m "feat(BuildServerIntegration): parse + resolve scheme ReferencedContainer

Task context: スキーム同名ターゲット曖昧性解消（#2）。スキームパーサが各
BuildableReference の ReferencedContainer を抽出し、buildTargets がスキームファイルの
所属コンテナ基準で絶対 .xcodeproj パスへ解決する。この時点では resolveScheme は
従来どおり名前一致のみ（挙動不変）。

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 3: `resolveScheme` のコンテナフィルタ

**Files:**
- Modify: `Sources/BuildServerIntegration/XcodeBuildServer.swift:358-372`（`resolveScheme` のシグネチャと照合ロジック）
- Modify: `Sources/BuildServerIntegration/XcodeBuildServer.swift`（`applySchemeScope` が `schemeTargets` を直接渡す）
- Test: `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift:125-181`（`resolveScheme` 単体テストを新シグネチャへ移行＋曖昧性解消テスト追加）

- [ ] **Step 1: 新シグネチャでの失敗テストを書く（既存 resolveScheme テストを置換 + 追加）**

`Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift:125-181` の `resolveScheme` テスト群を次に置換する（`schemeTargetNames:` → `schemeTargets:`）:

```swift
  func testResolveSchemeMatchesNamedTargets() {
    let targets = [
      XcodeTarget(guid: "G_App", name: "App", platforms: ["macosx"]),
      XcodeTarget(guid: "G_Fw", name: "Framework", platforms: ["macosx"]),
      XcodeTarget(guid: "G_Other", name: "Other", platforms: ["macosx"]),
    ]
    let resolution = XcodeBuildServer.resolveScheme(
      named: "AppScheme",
      schemeTargets: [SchemeBuildTarget(blueprintName: "App", container: nil)],
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
        SchemeBuildTarget(blueprintName: "App", container: nil),
        SchemeBuildTarget(blueprintName: "Framework", container: nil),
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
      schemeTargets: [SchemeBuildTarget(blueprintName: "Vanished", container: nil)],
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
      schemeTargets: [SchemeBuildTarget(blueprintName: "App", container: appA)],
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
    // No container on the scheme reference → legacy name-only match (both selected).
    let resolution = XcodeBuildServer.resolveScheme(
      named: "App",
      schemeTargets: [SchemeBuildTarget(blueprintName: "App", container: nil)],
      allTargets: targets
    )
    XCTAssertEqual(resolution, .seeds(["G_A", "G_B"]))
  }

  func testResolveSchemeMatchesByNameWhenTargetProjectPathAbsent() {
    let appA = URL(fileURLWithPath: "/ws/AppA/AppA.xcodeproj")
    // Targets have no projectFilePath (evaluation failed) → container cannot constrain → name-only.
    let targets = [
      XcodeTarget(guid: "G_A", name: "App", platforms: ["macosx"]),
      XcodeTarget(guid: "G_B", name: "App", platforms: ["macosx"]),
    ]
    let resolution = XcodeBuildServer.resolveScheme(
      named: "App",
      schemeTargets: [SchemeBuildTarget(blueprintName: "App", container: appA)],
      allTargets: targets
    )
    XCTAssertEqual(resolution, .seeds(["G_A", "G_B"]))
  }
```

- [ ] **Step 2: 失敗を確認**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeBuildServerTests/testResolveSchemeDisambiguatesSameNamedTargetsByContainer`
Expected: コンパイルエラー（`resolveScheme` の `schemeTargets:` ラベル未定義）。

- [ ] **Step 3: `resolveScheme` をコンテナフィルタ付きに実装**

`Sources/BuildServerIntegration/XcodeBuildServer.swift:358-372` の `resolveScheme` を置換:

```swift
  package static func resolveScheme(
    named scheme: String,
    schemeTargets: [SchemeBuildTarget]?,
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
```

`SchemeResolution` enum と doc コメント(`:307-356`)はそのまま。`resolveScheme` の doc コメントの `schemeTargetNames` 記述があれば `schemeTargets`（コンテナ照合を含む）に更新する。

- [ ] **Step 4: `applySchemeScope` が `schemeTargets` を直接渡すよう更新**

Task 2 Step 4 で書いた呼び出しを次に変更:

```swift
    switch Self.resolveScheme(named: scheme, schemeTargets: schemeTargets, allTargets: all) {
```

- [ ] **Step 5: テスト通過と非回帰を確認**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeBuildServerTests/testResolveScheme`
Expected: 8 メソッド全 PASS。
Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift build`
Expected: ビルド成功。

- [ ] **Step 6: コミット**

```bash
git add Sources/BuildServerIntegration/XcodeBuildServer.swift Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift
git commit -m "feat(BuildServerIntegration): scope scheme seeds by ReferencedContainer

Task context: スキーム同名ターゲット曖昧性解消（#2）。resolveScheme が
名前一致に加え、両側にパス情報があるときコンテナパス（解決済み container ==
projectFilePath）で起点を絞る。情報欠落時は名前一致にフォールバック（後方互換）。

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 4: 重複ターゲット名ワークスペースのテストフィクスチャ

> **高負荷・Xcode 必須タスク。** 2 つの `.xcodeproj` を持つ `.xcworkspace` を生成する。pbxproj は既存の検証済みテンプレートから機械的に派生させ、Xcode 26.4 で `xcodebuild -list` / `xcrun xcodebuild -dumpPIF` / `plutil -lint` により再検証する（既存フィクスチャと同じ運用）。SwiftBuild が両プロジェクトのターゲットを GUID で区別して列挙できることが要件。

**Files:**
- Modify: `Sources/SKTestSupport/XcodeTestProject.swift`（`Kind` 追加、`workspaceURL` 追加、init の生成分岐、テンプレート 2 種、ワークスペーススキーム書き出し）

- [ ] **Step 1: `Kind` と `workspaceURL` プロパティを追加**

`Sources/SKTestSupport/XcodeTestProject.swift:46-60` の `Kind` enum に追加:

```swift
    /// A `.xcworkspace` bundling two sibling-subdir `.xcodeproj`s (`AppA/AppA.xcodeproj`,
    /// `AppB/AppB.xcodeproj`), each with a target named `App`. Exercises scheme container
    /// disambiguation: a workspace-shared scheme `App` references only `AppA/AppA.xcodeproj`.
    case workspaceWithDuplicateTargetNames
```

`xcodeprojURL` / `sourceFileURL` のプロパティ宣言の近くに、ワークスペース URL を追加（非ワークスペース kind では `nil`）:

```swift
  /// For `.workspaceWithDuplicateTargetNames`, the `.xcworkspace` container path; `nil` otherwise.
  package let workspaceURL: URL?
```

- [ ] **Step 2: 2 種の pbxproj テンプレートを追加（既存検証済みテンプレートから派生）**

`Sources/SKTestSupport/XcodeTestProject.swift` のテンプレート定義群の末尾に、2 つの `static let` を追加する。いずれも `// swift-format-ignore` を付ける。

- `duplicateTargetAppATemplate`: 既存 `Self.pbxprojTemplate`（macOS command-line tool, target `MyApp`）の全文をコピーし、**`MyApp` を全て `App` に置換**したもの（target 名・productName・product reference・コメント・`PBXProject "MyApp"` → `"App"`・`path = MyApp` → `path = App`）。`main.swift` 参照（`path = main.swift; sourceTree = "<group>"`）はそのまま。
- `duplicateTargetAppBTemplate`: 上記 `duplicateTargetAppATemplate` をコピーし、**全オブジェクト ID の接頭辞 `A1` を `B2` に置換**したもの（例 `A100000000000000000000E1` → `B200000000000000000000E1`、`rootObject` 含む全 24 桁 ID）。target 名は `App` のまま（曖昧性のため AppA と同名）。

> 機械的置換の指針: AppA は `s/MyApp/App/g`（既存検証済みテンプレートに対して）。AppB は AppA に対して `s/A1\(0\{20\}\)/B2\1/g`（ID 先頭 2 文字のみ）。置換後は必ず Step 5 で実ファイルとして検証する。

- [ ] **Step 3: ワークスペース共有スキーム書き出しヘルパを追加**

`writeSharedScheme`(`:1370-1395`) の直後に追加:

```swift
  /// Write a workspace-level shared `.xcscheme` named `name` into `<workspaceURL>/xcshareddata/xcschemes`,
  /// whose Build action references each `(blueprintName, container)` pair. `container` is the `container:`
  /// relative path (e.g. `AppA/AppA.xcodeproj`). Requires `workspaceURL` to be set.
  @discardableResult
  package func writeWorkspaceSharedScheme(named name: String, buildTargets: [(blueprintName: String, container: String)]) throws -> URL {
    struct NotAWorkspaceError: Error, CustomStringConvertible {
      var description: String { "writeWorkspaceSharedScheme requires a .workspaceWithDuplicateTargetNames project" }
    }
    guard let workspaceURL else {
      throw NotAWorkspaceError()
    }
    let schemesDir = workspaceURL.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true)
    try fileManager.createDirectory(at: schemesDir, withIntermediateDirectories: true)
    let entryLines: [String] = buildTargets.flatMap { target -> [String] in
      [
        "         <BuildActionEntry buildForTesting=\"YES\" buildForRunning=\"YES\" buildForProfiling=\"YES\" buildForArchiving=\"YES\" buildForAnalyzing=\"YES\">",
        "            <BuildableReference BuildableIdentifier=\"primary\" BlueprintIdentifier=\"\(target.blueprintName)\" BuildableName=\"\(target.blueprintName)\" BlueprintName=\"\(target.blueprintName)\" ReferencedContainer=\"container:\(target.container)\"></BuildableReference>",
        "         </BuildActionEntry>",
      ]
    }
    let lines: [String] =
      [
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
        "<Scheme LastUpgradeVersion=\"1500\" version=\"1.7\">",
        "   <BuildAction parallelizeBuildables=\"YES\" buildImplicitDependencies=\"YES\">",
        "      <BuildActionEntries>",
      ] + entryLines + [
        "      </BuildActionEntries>",
        "   </BuildAction>",
        "</Scheme>",
      ]
    let url = schemesDir.appendingPathComponent("\(name).xcscheme", isDirectory: false)
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    return url
  }
```

注: `XcodeTestProject` は `Foundation` のみ import（XCTest 非依存）。上の `NotAWorkspaceError` はメソッド内ローカル定義で完結するため、追加 import は不要。

- [ ] **Step 4: init にワークスペース生成分岐を追加**

`init` (`:1248-1350`) を次のように拡張する。

(a) `self.workspaceURL` を全経路で初期化する。`self.xcodeprojURL = ...` の直後に、非ワークスペース kind では `nil`、ワークスペース kind では `.xcworkspace` を設定する。`xcodeprojURL` はワークスペース kind では `AppA/AppA.xcodeproj` を指す:

```swift
    switch kind {
    case .workspaceWithDuplicateTargetNames:
      self.workspaceURL = root.appendingPathComponent("MyWorkspace.xcworkspace", isDirectory: true)
      self.xcodeprojURL = root.appendingPathComponent("AppA/AppA.xcodeproj", isDirectory: true)
    default:
      self.workspaceURL = nil
      self.xcodeprojURL = root.appendingPathComponent("MyApp.xcodeproj", isDirectory: true)
    }
```

（既存の `self.xcodeprojURL = root.appendingPathComponent("MyApp.xcodeproj", ...)` の単独代入は上の switch に統合する。）

(b) `sourceFileURL` の switch(`:1268-1276`)に新 kind を追加（AppA のソース）:

```swift
    case .workspaceWithDuplicateTargetNames:
      self.sourceFileURL =
        root
        .appendingPathComponent("AppA", isDirectory: true)
        .appendingPathComponent("main.swift", isDirectory: false)
```

(c) テンプレート選択 switch(`:1280-1286`)は新 kind を `default` 扱いにしない。新 kind は下の (d) ブロックで 2 プロジェクトを個別生成するため、`:1278` の `try fileManager.createDirectory(at: xcodeprojURL, ...)` と `:1287-1291` の単一 pbxproj 書き出しを**新 kind では行わない**よう、これらを `if kind != .workspaceWithDuplicateTargetNames { ... }` で囲む（あるいは switch で分岐）。`template` の switch には新 kind を含めない（含めるとコンパイルエラーになるので、単一プロジェクト生成全体をガードする）。

(d) `init` 末尾（`.appWithPackageDependency` ブロックの後）に新 kind の生成を追加:

```swift
    if case .workspaceWithDuplicateTargetNames = kind {
      // Two sibling-subdir projects, each with a target named `App`.
      for (subdir, template) in [
        ("AppA", Self.duplicateTargetAppATemplate),
        ("AppB", Self.duplicateTargetAppBTemplate),
      ] {
        let projDir = root.appendingPathComponent(subdir, isDirectory: true)
        let xcodeproj = projDir.appendingPathComponent("\(subdir).xcodeproj", isDirectory: true)
        try fileManager.createDirectory(at: xcodeproj, withIntermediateDirectories: true)
        try template.write(
          to: xcodeproj.appendingPathComponent("project.pbxproj", isDirectory: false),
          atomically: true,
          encoding: .utf8
        )
        try sourceContents.write(
          to: projDir.appendingPathComponent("main.swift", isDirectory: false),
          atomically: true,
          encoding: .utf8
        )
      }
      // Workspace document referencing both projects.
      let workspace = root.appendingPathComponent("MyWorkspace.xcworkspace", isDirectory: true)
      try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
      let contents = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Workspace version = "1.0">
           <FileRef location = "group:AppA/AppA.xcodeproj"></FileRef>
           <FileRef location = "group:AppB/AppB.xcodeproj"></FileRef>
        </Workspace>
        """
      try (contents + "\n").write(
        to: workspace.appendingPathComponent("contents.xcworkspacedata", isDirectory: false),
        atomically: true,
        encoding: .utf8
      )
    }
```

注意: 新 kind では Step 4(c) のガードにより、共通の `main.swift` 書き出し(`:1293-1297`)も二重に走らないようにする（AppA の `sourceFileURL` は上の (d) で `AppA/main.swift` として書かれる）。`:1293-1297` も単一プロジェクトガードに含めるか、`sourceFileURL` への書き込みが (d) と矛盾しないことを確認する。最も安全なのは、`:1278` 以降の単一プロジェクト生成（pbxproj + main.swift 書き出し）全体を `if kind != .workspaceWithDuplicateTargetNames` で囲み、新 kind は (d) ブロックだけで完結させること。

- [ ] **Step 5: フィクスチャを実ファイルとして検証（Xcode 必須）**

一時的な検証用テストかスクリプトで `XcodeTestProject(kind: .workspaceWithDuplicateTargetNames, sourceContents: "print(\"hi\")\n")` を生成し、`projectRoot` を控える。生成物に対し以下を実行:

```bash
cd <projectRoot>
plutil -lint AppA/AppA.xcodeproj/project.pbxproj
plutil -lint AppB/AppB.xcodeproj/project.pbxproj
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer xcodebuild -list -workspace MyWorkspace.xcworkspace
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer xcrun xcodebuild -dumpPIF -workspace MyWorkspace.xcworkspace
```

Expected:
- `plutil -lint`: 両 pbxproj が `OK`。
- `xcodebuild -list`: スキーム/ターゲットとして `App` が両プロジェクト由来で見える（または workspace のスキーム一覧）。
- `xcrun xcodebuild -dumpPIF`: エラーなく PIF が出力され、`App` ターゲットが 2 件（AppA / AppB）含まれる。

ID 重複や PIF 失敗が出たら、AppB テンプレートの ID 接頭辞置換漏れ・workspace 参照パスを修正して再検証する。検証 OK 後、テンプレートの doc コメントに「Xcode 26.4 で `xcodebuild -list`/`-dumpPIF`/`plutil -lint` 検証済み」と明記する。

- [ ] **Step 6: ビルドが通ることを確認してコミット**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift build`
Expected: ビルド成功（`SKTestSupport` がコンパイルされる）。

```bash
git add Sources/SKTestSupport/XcodeTestProject.swift
git commit -m "test(SKTestSupport): workspaceWithDuplicateTargetNames fixture

Task context: スキーム同名ターゲット曖昧性解消（#2）の統合テスト用フィクスチャ。
projectRoot 直下の AppA/ と AppB/ に同名ターゲット App を持つ 2 つの .xcodeproj を
束ねる .xcworkspace を生成。ワークスペース共有スキーム App は container:AppA/AppA.xcodeproj
のみ参照。pbxproj は検証済みテンプレートから派生し Xcode 26.4 で再検証済み。

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 5: 統合テスト — ワークスペースのコンテナ曖昧性解消

**Files:**
- Test: `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift`（統合テスト群の末尾に追加）

- [ ] **Step 1: 統合テストを書く**

`Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift` の統合テスト群（`testSchemeIncludesDependencyClosure` の近く）に追加:

```swift
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
      "container:AppA should scope to exactly one App target (not both AppA and AppB), got \(targetsResponse.targets.map(\\.displayName))"
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
```

- [ ] **Step 2: テストを実行して通過を確認（Xcode 必須）**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeBuildServerTests/testSchemeDisambiguatesSameNamedTargetsByContainer`
Expected: PASS（`xcodebuild` 不在環境では `XCTSkip`）。

検証ポイント: 修正前(`git stash` で Task 3 の `resolveScheme` 変更を一時退避するか、`container: nil` でスキームを書いた版)では `targets.count == 2` になり、本テストが赤になることを一度確認しておくと、テストが意味を持つことの証明になる（任意）。

- [ ] **Step 3: 全 `BuildServerIntegrationTests` で非回帰を確認**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter BuildServerIntegrationTests 2>&1 | tail -40`
Expected: 0 失敗（既存スキーム・依存グラフ・プラットフォーム推定・`.test` タグを含む）。

- [ ] **Step 4: コミット**

```bash
git add Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift
git commit -m "test(BuildServerIntegration): scheme container disambiguation integration

Task context: スキーム同名ターゲット曖昧性解消（#2）の end-to-end 検証。重複名
ワークスペースを xcode.scheme=App でロードし、container:AppA/AppA.xcodeproj により
スコープが AppA の App ターゲット 1 件に限定され、ソースが AppA 由来で AppB を含まない
ことを実 SwiftBuild で確認。

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Self-Review チェック結果

**1. Spec coverage:**
- 「`ReferencedContainer` 抽出」→ Task 2（`buildActionReferences` + `SchemeBuildableReference`）。
- 「`resolveContainer` 解決・無効入力で nil」→ Task 1。
- 「`buildTargets` が所属コンテナ基準で絶対 URL 解決」→ Task 2（`schemeFileURL` がコンテナを返す + `buildTargets`）。
- 「`resolveScheme` の name+container 照合・欠落時フォールバック」→ Task 3（単体テスト含む）。
- 「重複名ワークスペース統合テスト（AppA のみ）」→ Task 4（フィクスチャ）+ Task 5（統合テスト）。
- 「`applySchemeScope` のフォールバック／ログ不変」→ Task 2/3 で呼び出しのみ変更、分岐・ログは不変。
- 「既存テスト非回帰」→ Task 5 Step 3。

**2. Placeholder scan:** コード手順はすべて実コードを掲載。Task 4 の pbxproj だけは「既存検証済みテンプレートからの機械的派生 + 実ファイル検証」とした（巨大な検証不能ブロックを盲目的に貼らないため）。派生規則と検証コマンドを具体的に明示済み。

**3. Type consistency:** `SchemeBuildableReference` / `SchemeBuildTarget` / `buildActionReferences` / `buildTargets` / `resolveContainer` / `resolveScheme(schemeTargets:)` / `normalizedPath` / `workspaceURL` / `Kind.workspaceWithDuplicateTargetNames` をヘッダの最終形と全タスクで一致させた。`applySchemeScope` は Task 2 で名前マップ（旧 `resolveScheme`）→ Task 3 で `schemeTargets` 直渡し（新 `resolveScheme`）へ移行し、各コミットでコンパイルが通る。
