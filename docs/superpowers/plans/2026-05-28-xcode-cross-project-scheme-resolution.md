# Xcode cross-project scheme コンテナ解決 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `xcode.scheme` でスコープする際、project reference 先プロジェクト内にある scheme ファイル（ケース1）と、開いたプロジェクトの scheme が参照先ターゲットを `ReferencedContainer` で指す参照（ケース2）の双方を正しく解決する。

**Architecture:** scheme ファイル探索のコンテナ集合を `XcodeScheme` 内で算出するのをやめ、呼び出し側 `XcodeBuildServer` が `[containerPath] + rootProjectPaths()`（#C で project reference を推移展開済み）を渡す（案1）。これにより「展開済み root 集合」が scheme 探索の単一真実源になる。`resolveContainer` / `resolveScheme` / `containerMatches` は無改修で、ケース2 は既存ロジックが cross-project でも動くことを統合テストで裏付ける。

**Tech Stack:** Swift / SwiftPM、XCTest、`Sources/BuildServerIntegration`（`XcodeScheme`, `XcodeBuildServer`, SwiftBuild 非依存の純粋型）、`Sources/SKTestSupport/XcodeTestProject`、実 Xcode 26.4 ゲートの統合テスト。

**ビルド/テスト実行（このチェックアウト固有）:** すべて `DEVELOPER_DIR` 前置で実行する。`SWIFTCI_USE_LOCAL_DEPS=1` は使わない。
```sh
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter <...>
```
`swift test` の出力を `tail` 等にパイプしない（終了コードを隠し summary を切り詰めるため）。

---

## File Structure

- `Sources/BuildServerIntegration/XcodeScheme.swift` — `buildTargets`/`schemeFileURL` を `searchContainers:` ベースに変更し、内部の `searchContainers(containerPath:projectRoot:)` と `XcodeWorkspace` 依存を削除。
- `Sources/BuildServerIntegration/XcodeBuildServer.swift` — 純粋ヘルパ `orderedSchemeSearchContainers(containerPath:rootProjects:)` を追加、private `schemeSearchContainers()` を追加、`applySchemeScope` の呼び出しを更新。
- `Sources/SKTestSupport/XcodeTestProject.swift` — `referencedProjectURL` アクセサ追加、private `writeBuildActionScheme(...)` を抽出、`writeSharedScheme(named:inProject:buildTargets:)` を追加、`writeWorkspaceSharedScheme` をその共通実装に載せ替え。
- `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift` — `orderedSchemeSearchContainers` 単体テスト、ケース1/ケース2 の統合テストを追加。
- `Tests/BuildServerIntegrationTests/XcodeSchemeTests.swift` — 既存 `buildTargets` 呼び出しを `searchContainers:` に移行、メンバー探索テストを新契約に変換、nested-group 探索テストを削除、cross-project の `resolveContainer` 単体テストを追加。

---

### Task 1: 純粋ヘルパ `orderedSchemeSearchContainers` を追加

scheme 探索コンテナの順序付け（opened 先頭・残りパスソート・`normalizedPath` で dedup）を純粋関数として切り出し、単体テスト可能にする。Task 2 で利用する前に独立して追加・検証する。

**Files:**
- Modify: `Sources/BuildServerIntegration/XcodeBuildServer.swift`（`extension XcodeBuildServer` の `normalizedPath` 付近、`:350-354`）
- Test: `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift`（`// MARK: - resolveScheme decision logic` 群の近く、`isPartOfRootProject` テストの後ろ `:295` 付近）

- [ ] **Step 1: Write the failing test**

`XcodeBuildServerTests.swift` の `isPartOfRootProject` 系テストの直後（`#endif` の手前）に追加:

```swift
  // MARK: - orderedSchemeSearchContainers

  func testOrderedSchemeSearchContainersPutsOpenedFirstThenSortedDeduped() {
    let opened = URL(fileURLWithPath: "/proj/MyApp.xcodeproj", isDirectory: true)
    let framework = URL(fileURLWithPath: "/proj/Framework/Framework.xcodeproj", isDirectory: true)
    let lib = URL(fileURLWithPath: "/proj/Aaa/Lib.xcodeproj", isDirectory: true)
    let result = XcodeBuildServer.orderedSchemeSearchContainers(
      containerPath: opened,
      // `opened` is also present in the root set and must be de-duplicated (not appended again).
      rootProjects: [opened, framework, lib]
    )
    XCTAssertEqual(
      result.map(\.path),
      ["/proj/MyApp.xcodeproj", "/proj/Aaa/Lib.xcodeproj", "/proj/Framework/Framework.xcodeproj"],
      "opened container first, then the rest sorted by path with the opened container de-duplicated"
    )
  }
```

- [ ] **Step 2: Run the test to verify it fails to compile**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeBuildServerTests/testOrderedSchemeSearchContainersPutsOpenedFirstThenSortedDeduped`
Expected: コンパイルエラー `type 'XcodeBuildServer' has no member 'orderedSchemeSearchContainers'`.

- [ ] **Step 3: Implement the helper**

`Sources/BuildServerIntegration/XcodeBuildServer.swift` の `normalizedPath(_:)`（`:352-354`）の直後に追加:

```swift
  /// The ordered, de-duplicated list of containers to search for `.xcscheme` files: the opened
  /// `containerPath` first (so it wins on scheme-name collisions), followed by every root `.xcodeproj`
  /// in `rootProjects` sorted by path. `rootProjects` is the project-reference-expanded root set from
  /// `rootProjectPaths()`; the opened container is removed from the tail via `normalizedPath` so it is
  /// not searched twice. `package` so the ordering is unit-testable without disk I/O.
  package static func orderedSchemeSearchContainers(containerPath: URL, rootProjects: Set<URL>) -> [URL] {
    var result: [URL] = [containerPath]
    var seen: Set<String> = [normalizedPath(containerPath)]
    for url in rootProjects.sorted(by: { $0.path < $1.path }) where seen.insert(normalizedPath(url)).inserted {
      result.append(url)
    }
    return result
  }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeBuildServerTests/testOrderedSchemeSearchContainersPutsOpenedFirstThenSortedDeduped`
Expected: PASS（1 test）。

- [ ] **Step 5: Commit**

```bash
git add Sources/BuildServerIntegration/XcodeBuildServer.swift Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift
git commit -m "feat(BuildServerIntegration): ordered scheme search-container helper

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 2: `XcodeScheme.buildTargets` を `searchContainers:` ベースへ移行（リファクタ・挙動保存）

`XcodeScheme` のメンバー探索ロジックを呼び出し側へ移し、`buildTargets(scheme:searchContainers:)` に変更する。`XcodeBuildServer` は Task 1 のヘルパ＋`rootProjectPaths()` でコンテナ集合を渡す。これだけで project reference 先が scheme 探索に入る（ケース1 の探索が成立）。挙動は既存統合テストで保存を確認する。

**Files:**
- Modify: `Sources/BuildServerIntegration/XcodeScheme.swift:58-117`
- Modify: `Sources/BuildServerIntegration/XcodeBuildServer.swift:91-99`（`applySchemeScope`）
- Modify: `Tests/BuildServerIntegrationTests/XcodeSchemeTests.swift:138-270`（既存 `buildTargets` 呼び出しの移行）

- [ ] **Step 1: 既存 `XcodeSchemeTests` の `buildTargets` 呼び出しを新シグネチャに更新（テスト先行）**

以下の 5 つは単一コンテナを渡す形に置換する（`containerPath:` / `projectRoot:` → `searchContainers:`）:

`testBuildTargetsFindsSharedSchemeAndResolvesContainer`（`:146`）:
```swift
    let result = try XCTUnwrap(XcodeScheme.buildTargets(scheme: "MyApp", searchContainers: [container]))
```
`testBuildTargetsPrefersSharedOverUser`（`:168`）:
```swift
      XcodeScheme.buildTargets(scheme: "MyApp", searchContainers: [container])?.map(\.blueprintName),
```
`testBuildTargetsFindsUserSchemeWhenNoShared`（`:182`）:
```swift
      XcodeScheme.buildTargets(scheme: "MyApp", searchContainers: [container])?.map(\.blueprintName),
```
`testBuildTargetsReturnsNilWhenMissing`（`:191`）:
```swift
    XCTAssertNil(XcodeScheme.buildTargets(scheme: "Nope", searchContainers: [container]))
```
`testBuildTargetsResolvesContainerRelativeToMatchedContainerDir`（`:204`）:
```swift
    let result = try XCTUnwrap(XcodeScheme.buildTargets(scheme: "App", searchContainers: [workspace]))
```

- [ ] **Step 2: メンバー探索テストを新契約に変換**

`testBuildTargetsFindsSchemeInWorkspaceMemberProject`（`:212-232`）を、メンバー発見を `XcodeScheme` に頼らず「与えられた複数コンテナを走査して 2 番目で見つける」契約に書き換える。メソッド全体を以下に置換:

```swift
  func testBuildTargetsSearchesAllGivenContainers() throws {
    // buildTargets searches every container it is handed (the caller now decides the set), finding a scheme
    // that lives only in a non-first container and resolving its container relative to where it was found.
    let root = try makeTempDir()
    let opened = root.appendingPathComponent("MyApp.xcodeproj", isDirectory: true)
    try FileManager.default.createDirectory(at: opened, withIntermediateDirectories: true)
    let member = root.appendingPathComponent("Member.xcodeproj", isDirectory: true)
    try writeSchemeWithContainer(
      "MyApp",
      into: member.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true),
      blueprintName: "MemberTarget",
      container: "Member.xcodeproj"
    )
    let result = try XCTUnwrap(
      XcodeScheme.buildTargets(scheme: "MyApp", searchContainers: [opened, member])
    )
    XCTAssertEqual(result.first?.blueprintName, "MemberTarget")
    XCTAssertEqual(
      result.first?.container?.standardizedFileURL.path,
      root.appendingPathComponent("Member.xcodeproj").standardizedFileURL.path
    )
  }
```

- [ ] **Step 3: workspacedata 依存の探索テストを削除**

`testBuildTargetsFindsSchemeInSubdirectoryMemberViaNestedGroup`（`:234-270`）をメソッドごと削除する。理由: `contents.xcworkspacedata` の nested `<Group>` 追従は `XcodeScheme` の責務ではなくなり（呼び出し側 `rootProjectPaths()` → `XcodeWorkspace.memberProjects` が担う）、その解決自体は `XcodeWorkspaceTests` と `XcodeBuildServerTests.testNestedWorkspaceFixtureMemberProjects`（`:900`）で既にカバー済み。

- [ ] **Step 4: Run the migrated tests to verify they fail to compile**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeSchemeTests`
Expected: コンパイルエラー（`buildTargets` の引数ラベル `searchContainers:` が未実装）。

- [ ] **Step 5: `XcodeScheme.buildTargets` / `schemeFileURL` を実装変更し `searchContainers` を削除**

`Sources/BuildServerIntegration/XcodeScheme.swift` の `buildTargets`（`:58-71`）を置換:

```swift
  /// Locate the `.xcscheme` named `scheme` in `searchContainers` (the caller-supplied, ordered list of
  /// candidate containers: the opened container plus the project-reference-expanded root `.xcodeproj`s) and
  /// return its Build/Test/Launch action targets, with each `ReferencedContainer` resolved to an absolute
  /// `.xcodeproj` path (relative to the directory of the container the scheme file was found in). Returns
  /// `nil` if no matching file exists (the caller then decides how to fall back).
  ///
  /// Search order: shared schemes (`xcshareddata/xcschemes`) across all containers before user schemes
  /// (`xcuserdata/*.xcuserdatad/xcschemes`), preserving the order of `searchContainers` within each phase.
  package static func buildTargets(scheme: String, searchContainers: [URL]) -> [SchemeBuildTarget]? {
    guard let (url, container) = schemeFileURL(scheme: scheme, searchContainers: searchContainers),
      let data = try? Data(contentsOf: url)
    else {
      return nil
    }
    let baseDir = container.deletingLastPathComponent()
    return schemeSeedReferences(xcschemeContents: data).map { reference in
      SchemeBuildTarget(
        blueprintName: reference.blueprintName,
        container: resolveContainer(reference.referencedContainer, relativeTo: baseDir)
      )
    }
  }
```

`searchContainers(containerPath:projectRoot:)`（`:73-86`）をメソッドごと削除する。

`schemeFileURL`（`:88-117`）を置換:

```swift
  private static func schemeFileURL(
    scheme: String,
    searchContainers: [URL]
  ) -> (url: URL, container: URL)? {
    let fm = FileManager.default

    // Shared schemes first, across all candidate containers.
    for container in searchContainers {
      let shared = container.appendingPathComponent("xcshareddata/xcschemes/\(scheme).xcscheme", isDirectory: false)
      if fm.fileExists(atPath: shared.path) {
        return (shared, container)
      }
    }
    // Then user schemes: xcuserdata/<anything>.xcuserdatad/xcschemes/<name>.xcscheme
    for container in searchContainers {
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

- [ ] **Step 6: `XcodeBuildServer` の呼び出しと `schemeSearchContainers()` を実装**

`Sources/BuildServerIntegration/XcodeBuildServer.swift` の `applySchemeScope`（`:95-99`）の呼び出しを置換:

```swift
    let schemeTargets = XcodeScheme.buildTargets(
      scheme: scheme,
      searchContainers: schemeSearchContainers()
    )
```

`rootProjectPaths()`（`:164` の閉じ括弧）の直後に private メソッドを追加:

```swift
  /// Containers to search for `.xcscheme` files: the opened container first, then every root `.xcodeproj`
  /// (workspace members plus transitively project-referenced projects) from `rootProjectPaths()`. Schemes
  /// can live in the opened workspace/project or in any project it reaches through project references, so
  /// all of them are scheme-file candidates; the opened container is searched first so it wins on
  /// scheme-name collisions.
  private func schemeSearchContainers() -> [URL] {
    Self.orderedSchemeSearchContainers(containerPath: containerPath, rootProjects: rootProjectPaths())
  }
```

- [ ] **Step 7: Run migrated unit tests + the Xcode scheme integration tests to verify behavior is preserved**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeSchemeTests`
Expected: PASS（移行済みの単体テスト群）。

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter "XcodeBuildServerTests/testSchemeScopesToBuildActionTargets|XcodeBuildServerTests/testSchemeDisambiguatesSameNamedTargetsByContainer"`
Expected: PASS（scheme スコープ・workspace 同名曖昧性解消が不変。初回はターゲットビルドで数分かかる場合あり）。

- [ ] **Step 8: Commit**

```bash
git add Sources/BuildServerIntegration/XcodeScheme.swift Sources/BuildServerIntegration/XcodeBuildServer.swift Tests/BuildServerIntegrationTests/XcodeSchemeTests.swift
git commit -m "refactor(BuildServerIntegration): scheme search uses caller-supplied containers

Move scheme-file search-container computation out of XcodeScheme into
XcodeBuildServer, which passes [containerPath] + rootProjectPaths() so the
project-reference-expanded root set (from #C) is the single source of truth.
buildTargets(scheme:searchContainers:) drops the XcodeWorkspace dependency.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 3: cross-project の `resolveContainer` 単体テストを追加（ケース2 のパス演算）

開いたプロジェクトの scheme が参照先プロジェクトを指す `container:Framework/Framework.xcodeproj` を、プロジェクトスキーム基準で正しく絶対パス解決することを単体で固定する。（`resolveScheme` のコンテナ照合自体は既存テスト `:188-227` でカバー済みなので追加しない。）

**Files:**
- Test: `Tests/BuildServerIntegrationTests/XcodeSchemeTests.swift`（`testBuildTargetsSearchesAllGivenContainers` の後ろ）

- [ ] **Step 1: Write the failing test**

```swift
  func testBuildTargetsResolvesCrossProjectContainerFromProjectScheme() throws {
    // A scheme that lives in the opened MyApp.xcodeproj references a target in a project-referenced
    // Framework/Framework.xcodeproj. The container resolves relative to the scheme-owning project's dir.
    let root = try makeTempDir()
    let opened = root.appendingPathComponent("MyApp.xcodeproj", isDirectory: true)
    try writeSchemeWithContainer(
      "Cross",
      into: opened.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true),
      blueprintName: "Framework",
      container: "Framework/Framework.xcodeproj"
    )
    let result = try XCTUnwrap(XcodeScheme.buildTargets(scheme: "Cross", searchContainers: [opened]))
    XCTAssertEqual(result.first?.blueprintName, "Framework")
    XCTAssertEqual(
      result.first?.container?.standardizedFileURL.path,
      root.appendingPathComponent("Framework/Framework.xcodeproj").standardizedFileURL.path
    )
  }
```

- [ ] **Step 2: Run the test to verify it passes (no production change needed)**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeSchemeTests/testBuildTargetsResolvesCrossProjectContainerFromProjectScheme`
Expected: PASS。`resolveContainer` の既存実装が cross-project の相対パスを解決することを証明する（このタスクは本番コード変更なし）。

- [ ] **Step 3: Commit**

```bash
git add Tests/BuildServerIntegrationTests/XcodeSchemeTests.swift
git commit -m "test(BuildServerIntegration): cross-project container resolves from project scheme

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 4: フィクスチャ拡張（`referencedProjectURL` ＋ `writeSharedScheme(inProject:)`）

`appWithProjectReference` の参照先 `.xcodeproj` URL を公開し、任意の `.xcodeproj` に `(blueprintName, container)` 指定で shared scheme を書き出せるヘルパを追加する。`writeWorkspaceSharedScheme` の XML 生成を private 共通実装に集約する。

**Files:**
- Modify: `Sources/SKTestSupport/XcodeTestProject.swift`（プロパティ宣言 `:55` 付近、init `:2103-2119`、`writeWorkspaceSharedScheme` `:2419-2454`）
- Test: `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift`

- [ ] **Step 1: Write the failing test**

`XcodeBuildServerTests.swift` の末尾付近（他の `appWithProjectReference` テストの近く）に追加。Xcode 不要のフィクスチャ検証テスト:

```swift
  /// The `.appWithProjectReference` fixture exposes its project-referenced Framework.xcodeproj, and a scheme
  /// can be authored into it; the scheme parser then finds it among the search containers and resolves its
  /// container relative to that project's directory.
  func testWriteSharedSchemeInReferencedProject() throws {
    let project = try XcodeTestProject(kind: .appWithProjectReference, sourceContents: "print(\"hi\")\n")
    defer { project.keepAlive() }
    let frameworkURL = try XCTUnwrap(project.referencedProjectURL)
    try project.writeSharedScheme(
      named: "FwScheme",
      inProject: frameworkURL,
      buildTargets: [(blueprintName: "Framework", container: "Framework.xcodeproj")]
    )
    let result = try XCTUnwrap(
      XcodeScheme.buildTargets(scheme: "FwScheme", searchContainers: [project.xcodeprojURL, frameworkURL])
    )
    XCTAssertEqual(result.map(\.blueprintName), ["Framework"])
    XCTAssertEqual(
      result.first?.container?.standardizedFileURL.path,
      frameworkURL.standardizedFileURL.path
    )
  }
```

- [ ] **Step 2: Run the test to verify it fails to compile**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeBuildServerTests/testWriteSharedSchemeInReferencedProject`
Expected: コンパイルエラー（`referencedProjectURL` と `writeSharedScheme(named:inProject:buildTargets:)` が未定義）。

- [ ] **Step 3: `referencedProjectURL` プロパティを追加**

`Sources/SKTestSupport/XcodeTestProject.swift` の `workspaceURL` 宣言（`:55`）の直後に追加:

```swift
  /// The project-referenced `Framework/Framework.xcodeproj` for `.appWithProjectReference`; `nil` for all
  /// other kinds. Use as the `inProject:` destination of ``writeSharedScheme(named:inProject:buildTargets:)``
  /// when authoring a scheme that lives in the project-referenced project.
  package let referencedProjectURL: URL?
```

init の最初の `switch kind`（`:2107-2119`）の閉じ括弧の直後に代入を追加:

```swift
    if case .appWithProjectReference = kind {
      self.referencedProjectURL = root.appendingPathComponent("Framework/Framework.xcodeproj", isDirectory: true)
    } else {
      self.referencedProjectURL = nil
    }
```

- [ ] **Step 4: 共通 XML 生成を private 化し、新ヘルパを追加**

`writeWorkspaceSharedScheme`（`:2415-2454`）を以下で置換（private `writeBuildActionScheme` 抽出 ＋ `writeWorkspaceSharedScheme` の載せ替え ＋ 新 `writeSharedScheme(inProject:)`）:

```swift
  /// Write a shared `.xcscheme` named `name` containing only a Build action that references each
  /// `(blueprintName, container)` pair, into `schemesDir`. Shared private implementation of the
  /// workspace and project `writeSharedScheme` variants.
  @discardableResult
  private func writeBuildActionScheme(
    named name: String,
    intoSchemesDir schemesDir: URL,
    buildTargets: [(blueprintName: String, container: String)]
  ) throws -> URL {
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

  /// Write a workspace-level shared `.xcscheme` named `name` into `<workspaceURL>/xcshareddata/xcschemes`,
  /// whose Build action references each `(blueprintName, container)` pair. `container` is the `container:`
  /// relative path (e.g. `AppA/AppA.xcodeproj`). Requires `workspaceURL` to be set.
  @discardableResult
  package func writeWorkspaceSharedScheme(
    named name: String,
    buildTargets: [(blueprintName: String, container: String)]
  ) throws -> URL {
    struct NotAWorkspaceError: Error, CustomStringConvertible {
      var description: String {
        "writeWorkspaceSharedScheme requires workspaceURL to be non-nil (only set for workspace kinds)"
      }
    }
    guard let workspaceURL else {
      throw NotAWorkspaceError()
    }
    return try writeBuildActionScheme(
      named: name,
      intoSchemesDir: workspaceURL.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true),
      buildTargets: buildTargets
    )
  }

  /// Write a shared `.xcscheme` named `name` into `<projectURL>/xcshareddata/xcschemes`, whose Build action
  /// references each `(blueprintName, container)` pair. `container` is the `container:` relative path:
  /// `Framework.xcodeproj` when the scheme lives in that project, or `Framework/Framework.xcodeproj` to point
  /// into a project-referenced project from a scheme that lives in the opened project. Use with
  /// ``xcodeprojURL`` or ``referencedProjectURL`` to author cross-project schemes in the
  /// `.appWithProjectReference` fixture.
  @discardableResult
  package func writeSharedScheme(
    named name: String,
    inProject projectURL: URL,
    buildTargets: [(blueprintName: String, container: String)]
  ) throws -> URL {
    try writeBuildActionScheme(
      named: name,
      intoSchemesDir: projectURL.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true),
      buildTargets: buildTargets
    )
  }
```

> 注: 既存の `writeSharedScheme(named:buildTargetNames:testTargetNames:launchTargetName:)`（`:2354`）は Build/Test/Launch アクションを書く別シグネチャなので**そのまま残す**（引数ラベルが異なり多重定義の曖昧性なし）。

- [ ] **Step 5: Run the test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeBuildServerTests/testWriteSharedSchemeInReferencedProject`
Expected: PASS。

- [ ] **Step 6: Commit**

```bash
git add Sources/SKTestSupport/XcodeTestProject.swift Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift
git commit -m "test(SKTestSupport): expose referenced project URL and project scheme writer

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 5: 統合テスト — ケース1（参照先プロジェクト内の scheme でスコープ）

開いた `MyApp.xcodeproj` で、project reference 先 `Framework/Framework.xcodeproj` 内に置いた scheme を `xcode.scheme` に指定すると、スコープが `Framework`（＋クロージャ）に絞られることを実 Xcode で確認する。`schemeSearchContainers()` が `rootProjectPaths()` 経由で参照先を探索集合に含めることの end-to-end 証明。

**Files:**
- Test: `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift`（`testProjectReferencedTargetIsNotTaggedDependency` `:826` の近く）

- [ ] **Step 1: Write the failing test**

```swift
  /// A scheme that lives inside the project-referenced `Framework/Framework.xcodeproj` is discoverable when
  /// `MyApp.xcodeproj` is opened, because `schemeSearchContainers()` includes project-referenced projects.
  /// Scoping to it narrows the build server to `Framework` (and its closure), excluding `MyApp`.
  func testSchemeInProjectReferencedProjectScopesToItsTarget() async throws {
    try skipUnlessXcodeAvailable()

    let project = try XcodeTestProject(kind: .appWithProjectReference, sourceContents: "print(\"hi\")\n")
    defer { project.keepAlive() }
    let frameworkURL = try XCTUnwrap(project.referencedProjectURL)
    try project.writeSharedScheme(
      named: "FrameworkScheme",
      inProject: frameworkURL,
      buildTargets: [(blueprintName: "Framework", container: "Framework.xcodeproj")]
    )

    let buildServer = try await XcodeBuildServer(
      projectRoot: project.projectRoot,
      containerPath: project.xcodeprojURL,
      toolchainRegistry: .forTesting,
      options: SourceKitLSPOptions(xcode: SourceKitLSPOptions.XcodeOptions(scheme: "FrameworkScheme")),
      connectionToSourceKitLSP: LocalConnection(receiverName: "Dummy SourceKit-LSP")
    )
    addTeardownBlock { await buildServer.close() }

    let response = try await buildServer.buildTargets(request: WorkspaceBuildTargetsRequest())
    let names = Set(response.targets.compactMap(\.displayName))
    XCTAssertTrue(names.contains("Framework"), "expected Framework in scope, got \(names.sorted())")
    XCTAssertFalse(
      names.contains("MyApp"),
      "a scheme scoped to Framework should exclude MyApp (proves the scheme was found & scoped), got \(names.sorted())"
    )
  }
```

- [ ] **Step 2: Run the test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeBuildServerTests/testSchemeInProjectReferencedProjectScopesToItsTarget`
Expected: PASS（実 Xcode 26.4。初回のターゲットビルドで数分かかる場合あり）。失敗時は `SOURCEKIT_LSP_FORCE_NON_DARWIN_LOGGER=1` を付けて stderr ログを確認する。

- [ ] **Step 3: Commit**

```bash
git add Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift
git commit -m "test(BuildServerIntegration): scheme in project-referenced project scopes correctly

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 6: 統合テスト — ケース2（opened の scheme が参照先ターゲットを container 指定）

開いた `MyApp.xcodeproj` 内の scheme が、`container:Framework/Framework.xcodeproj` で参照先ターゲットを直接 seed する場合に、cross-project の container 解決＋照合が成立してスコープに `Framework` が入ることを実 Xcode で確認する。container 解決が誤れば `containerMatches` が false になり全ターゲットへフォールバックするため、`MyApp` 除外の主張がこの解決の正しさを区別する。

**Files:**
- Test: `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift`（Task 5 のテストの近く）

- [ ] **Step 1: Write the failing test**

```swift
  /// A scheme living in the opened `MyApp.xcodeproj` whose only Build seed references the project-referenced
  /// `Framework` target via `container:Framework/Framework.xcodeproj` scopes to `Framework`. If the
  /// cross-project container failed to resolve to Framework's PROJECT_FILE_PATH, `containerMatches` would be
  /// false, no target would match, and the build server would fall back to indexing all targets (including
  /// `MyApp`) — so asserting `MyApp` is excluded proves the cross-project reference resolved.
  func testSchemeReferencingProjectReferencedTargetScopesAcrossProjects() async throws {
    try skipUnlessXcodeAvailable()

    let project = try XcodeTestProject(kind: .appWithProjectReference, sourceContents: "print(\"hi\")\n")
    defer { project.keepAlive() }
    try project.writeSharedScheme(
      named: "CrossScheme",
      inProject: project.xcodeprojURL,
      buildTargets: [(blueprintName: "Framework", container: "Framework/Framework.xcodeproj")]
    )

    let buildServer = try await XcodeBuildServer(
      projectRoot: project.projectRoot,
      containerPath: project.xcodeprojURL,
      toolchainRegistry: .forTesting,
      options: SourceKitLSPOptions(xcode: SourceKitLSPOptions.XcodeOptions(scheme: "CrossScheme")),
      connectionToSourceKitLSP: LocalConnection(receiverName: "Dummy SourceKit-LSP")
    )
    addTeardownBlock { await buildServer.close() }

    let response = try await buildServer.buildTargets(request: WorkspaceBuildTargetsRequest())
    let names = Set(response.targets.compactMap(\.displayName))
    XCTAssertTrue(names.contains("Framework"), "expected Framework in scope, got \(names.sorted())")
    XCTAssertFalse(
      names.contains("MyApp"),
      "a correctly-resolved cross-project seed scopes to Framework only; MyApp present would mean a fallback to all targets, got \(names.sorted())"
    )
  }
```

- [ ] **Step 2: Run the test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeBuildServerTests/testSchemeReferencingProjectReferencedTargetScopesAcrossProjects`
Expected: PASS（実 Xcode 26.4）。

> 万一 `MyApp` がスコープに残って FAIL する場合: 実 Xcode が書く `ReferencedContainer` の基準が想定（scheme 所属プロジェクトのディレクトリ）と異なる可能性。`SOURCEKIT_LSP_FORCE_NON_DARWIN_LOGGER=1` でログを取り、`resolveContainer` の baseDir 基準を実測値に合わせて調整する（spec「段階2 は無改修」の唯一の見直しポイント）。

- [ ] **Step 3: Commit**

```bash
git add Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift
git commit -m "test(BuildServerIntegration): scheme references project-referenced target across projects

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 7: フォーマット・フルスイート検証

**Files:** なし（検証とフォーマットのみ）

- [ ] **Step 1: Format**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift format -ipr .`
Expected: 差分があれば適用される。

- [ ] **Step 2: フルの `BuildServerIntegrationTests` を実行**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter BuildServerIntegrationTests`
Expected: 0 失敗（既存 182 件 ＋ 本作業の新規。Task 2 で 1 件削除・1 件変換しているため純増は数件）。終了コードが 0 であることを確認（`tail` 等にパイプしない）。

- [ ] **Step 3: フォーマット差分があればコミット**

```bash
git add -A
git commit -m "style: swift format after cross-project scheme resolution

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>" || echo "no formatting changes"
```

- [ ] **Step 4: 進捗メモリを更新**

`/Users/kazukiyamamoto/.claude/projects/-Users-kazukiyamamoto-ghq-github-com-swiftlang-sourcekit-lsp/memory/xcode-build-server-project.md` に「cross-project scheme コンテナ解決（フォローアップ #D）完了」の段落を追記し、残フォローアップ一覧から本項目を除く（`BlueprintIdentifier`→GUID 照合、別 `.xcworkspace` 参照、visionOS、#5 推移参照統合テストは残す）。マージ（`finishing-a-development-branch`）後にマージコミットハッシュを記録する。

---

## Self-Review

**1. Spec coverage:**
- スコープ内「`buildTargets`→`searchContainers:` 移行」→ Task 2。
- 「`applySchemeScope` が `[containerPath] + rootProjectPaths()` を渡す（順序付き dedup）」→ Task 1（純粋ヘルパ）＋ Task 2（配線）。
- 「ケース1（参照先 scheme でスコープ）」→ Task 5（統合）＋ Task 4（フィクスチャ検証単体）。
- 「ケース2（opened の scheme が参照先ターゲットを container 指定）」→ Task 6（統合）＋ Task 3（`resolveContainer` 単体）。`resolveScheme` 照合は既存テスト `:188-227` でカバー済み（重複追加せず）。
- 「フィクスチャ `appWithProjectReference` に cross-project scheme 追加」→ Task 4/5/6。
- エッジ「scheme 名衝突は opened 優先」→ Task 1 の順序ヘルパ＋テスト。
- 「dangling container → fallbackNoKnownTargets」→ Task 6 が誤解決時のフォールバック挙動を逆向きに検証。
- 受け入れ条件「`XcodeScheme` が `XcodeWorkspace` 非依存」→ Task 2 Step 5 で `searchContainers` 削除。
- スコープ外（`BlueprintIdentifier`→GUID、別 `.xcworkspace`、visionOS、#5）→ いずれもタスク化せず（意図どおり）。

**2. Placeholder scan:** TBD/TODO・「適切に処理」等のプレースホルダなし。全ステップに実コードまたは実コマンドを記載。

**3. Type consistency:** `buildTargets(scheme:searchContainers:)`・`schemeFileURL(scheme:searchContainers:)`・`orderedSchemeSearchContainers(containerPath:rootProjects:)`・`schemeSearchContainers()`・`writeSharedScheme(named:inProject:buildTargets:)`・`writeBuildActionScheme(named:intoSchemesDir:buildTargets:)`・`referencedProjectURL` は全タスクで一貫。`SchemeBuildTarget`/`XcodeTarget`/`SourceKitLSPOptions.XcodeOptions(scheme:)` は既存定義どおり。
