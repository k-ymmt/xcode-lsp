# Xcode scheme Test/Launch アクション対応 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `xcode.scheme` のスコープ起点(seed)を、`BuildAction` だけでなく `TestAction`(Testables)と `LaunchAction`(runnable)の `BuildableReference` にも広げ、Test アクションにしか書かれていないテストターゲットもインデックス対象にする。

**Architecture:** scheme の seed 収集を担う XMLParser デリゲートを、要素スタックの深さカウンタで「`BuildAction`/`TestAction`/`LaunchAction` のいずれかの内側にいるか」を判定する形へ拡張する。下流の `resolveScheme`(blueprintName + container 照合)・依存クロージャ展開・フォールバックは無改修で、seed の出所が増えるだけ。`skipped="YES"` のテストも収集する(スコープ=インデックス対象であり実行対象ではない)。

**Tech Stack:** Swift / Foundation `XMLParser` / SwiftPM / XCTest(`BuildServerIntegrationTests`)/ SwiftBuild(統合テストのみ、Xcode 26.4 必須)

設計 spec: `docs/superpowers/specs/2026-05-27-xcode-scheme-test-launch-actions-design.md`

> **ローカル環境メモ:** ビルド/テスト/format/dev-utils はすべて `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer` を前置する(`SWIFTCI_USE_LOCAL_DEPS=1` はこのチェックアウトでは不可)。統合テストの初回ビルドは数分かかる。

---

## File Structure

- **Modify** `Sources/BuildServerIntegration/XcodeScheme.swift`
  scheme パーサ本体。`buildActionReferences` → `schemeSeedReferences` へリネームし、デリゲートを 3 アクション対応へ拡張。
- **Modify** `Tests/BuildServerIntegrationTests/XcodeSchemeTests.swift`
  パーサの単体テスト(全環境)。リネーム追従 + Test/Launch/skipped/dedup の検証。
- **Modify** `Sources/SKTestSupport/XcodeTestProject.swift`
  フィクスチャの `writeSharedScheme` を TestAction/LaunchAction も出力できるよう拡張(後方互換)。
- **Modify** `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift`
  統合テスト(macOS + Xcode 26.4)。Test アクションにのみ載せたテストターゲットがスコープに入ることを検証。
- **Modify** `Sources/SKOptions/SourceKitLSPOptions.swift`
  `XcodeOptions.scheme` の doc コメント更新。
- **Regenerated**(手編集禁止)`config.schema.json` / `Documentation/Configuration File.md`
  `generate-config-schema` で再生成。

---

## Task 1: パーサ関数/デリゲートのリネーム(挙動不変リファクタ)

`buildActionReferences` という名前は Test/Launch も拾う新挙動とずれるため、先に挙動を変えずリネームしておく(差分を小さく保つ)。

**Files:**
- Modify: `Sources/BuildServerIntegration/XcodeScheme.swift:64,115-125,146-184`
- Modify: `Tests/BuildServerIntegrationTests/XcodeSchemeTests.swift:45,55,65,85`

- [ ] **Step 1: ソースのリネーム**

`Sources/BuildServerIntegration/XcodeScheme.swift` の `buildTargets` 内の呼び出し(64 行目付近)を変更:

```swift
    return schemeSeedReferences(xcschemeContents: data).map { reference in
```

`buildActionReferences` の宣言とその doc コメント(115-125 行目付近)を次へ置換:

```swift
  /// Extract every `BuildableReference` (name + `ReferencedContainer`) the scheme uses as a build seed:
  /// those nested under the scheme's `BuildAction`, `TestAction`, or `LaunchAction`. De-duplicated by
  /// (name, container) pair, preserving order.
  package static func schemeSeedReferences(xcschemeContents: Data) -> [SchemeBuildableReference] {
    let parser = XMLParser(data: xcschemeContents)
    let delegate = SchemeReferenceDelegate()
    parser.delegate = delegate
    parser.parse()
    var seen = Set<SchemeBuildableReference>()
    return delegate.references.filter { seen.insert($0).inserted }
  }
```

デリゲートクラス(146 行目付近)の宣言名を `BuildActionDelegate` → `SchemeReferenceDelegate` に変更(本文はこの Task では変えない):

```swift
private final class SchemeReferenceDelegate: NSObject, XMLParserDelegate {
```

> 注: この時点ではデリゲート本文は旧ロジック(`inBuildAction` ベース、BuildAction のみ収集)のまま。挙動は変わらない。

- [ ] **Step 2: テストの呼び出し名を追従**

`Tests/BuildServerIntegrationTests/XcodeSchemeTests.swift` の 45 / 55 / 65 / 85 行目にある `XcodeScheme.buildActionReferences(` を `XcodeScheme.schemeSeedReferences(` に置換(4 箇所)。テストの期待値・メソッド名は変えない(`testIgnoresBuildableReferencesOutsideBuildAction` は Task 2 で扱う)。

- [ ] **Step 3: テストを実行して緑(挙動不変)を確認**

Run:
```sh
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeSchemeTests
```
Expected: PASS(`testIgnoresBuildableReferencesOutsideBuildAction` を含む既存テストが全て通る。挙動は不変)

- [ ] **Step 4: format & commit**

```sh
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift format -ipr Sources/BuildServerIntegration/XcodeScheme.swift Tests/BuildServerIntegrationTests/XcodeSchemeTests.swift
git add Sources/BuildServerIntegration/XcodeScheme.swift Tests/BuildServerIntegrationTests/XcodeSchemeTests.swift
git commit -m "refactor(BuildServerIntegration): rename buildActionReferences -> schemeSeedReferences

Pure rename ahead of broadening scheme seed collection to Test/Launch
actions. buildActionReferences/BuildActionDelegate -> schemeSeedReferences/
SchemeReferenceDelegate. No behavior change.

Task context: XcodeBuildServer follow-up 'scheme の Test/Run 対応'.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 2: Test/Launch アクションの参照を収集(挙動変更・TDD)

**Files:**
- Modify: `Tests/BuildServerIntegrationTests/XcodeSchemeTests.swift:73-88`(`testIgnoresBuildableReferencesOutsideBuildAction` を置換)
- Modify: `Sources/BuildServerIntegration/XcodeScheme.swift:146-184`(`SchemeReferenceDelegate` 本文)

- [ ] **Step 1: 失敗するテストを書く**

`Tests/BuildServerIntegrationTests/XcodeSchemeTests.swift` の `testIgnoresBuildableReferencesOutsideBuildAction`(73-88 行目)を**丸ごと削除**し、次のテストに置き換える:

```swift
  func testCollectsBuildTestAndLaunchActionReferences() {
    // Build action: App. Test action: AppTests (skipped=NO) and AppUITests (skipped=YES). Launch action:
    // App (duplicate of the build-action App -> deduped). Skipped testables are still collected because
    // scope is about indexing, not running.
    let extraActions = """
           <TestAction buildConfiguration="Debug">
              <Testables>
                 <TestableReference skipped="NO">
                    <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="AppTests" BuildableName="AppTests.xctest" BlueprintName="AppTests" ReferencedContainer="container:MyApp.xcodeproj"></BuildableReference>
                 </TestableReference>
                 <TestableReference skipped="YES">
                    <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="AppUITests" BuildableName="AppUITests.xctest" BlueprintName="AppUITests" ReferencedContainer="container:MyApp.xcodeproj"></BuildableReference>
                 </TestableReference>
              </Testables>
           </TestAction>
           <LaunchAction buildConfiguration="Debug">
              <BuildableProductRunnable runnableDebuggingMode="0">
                 <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="App" BuildableName="App.app" BlueprintName="App" ReferencedContainer="container:MyApp.xcodeproj"></BuildableReference>
              </BuildableProductRunnable>
           </LaunchAction>
      """
    let data = scheme(buildEntries: entry(blueprintName: "App"), extraActions: extraActions)
    XCTAssertEqual(
      XcodeScheme.schemeSeedReferences(xcschemeContents: data),
      [
        XcodeScheme.SchemeBuildableReference(blueprintName: "App", referencedContainer: "container:MyApp.xcodeproj"),
        XcodeScheme.SchemeBuildableReference(blueprintName: "AppTests", referencedContainer: "container:MyApp.xcodeproj"),
        XcodeScheme.SchemeBuildableReference(blueprintName: "AppUITests", referencedContainer: "container:MyApp.xcodeproj"),
      ]
    )
  }
```

> このテストは同時に次を検証する: TestAction の Testables を収集 / `skipped="YES"` も収集 / LaunchAction の App が BuildAction の App と (name, container) で重複排除される / 文書順(Build → Test → Launch)が保たれる。

- [ ] **Step 2: テストを実行して失敗を確認**

Run:
```sh
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeSchemeTests/testCollectsBuildTestAndLaunchActionReferences
```
Expected: FAIL(現状のデリゲートは `BuildAction` のみ収集するため、結果は `[App]` のみで `AppTests`/`AppUITests` が欠落)

- [ ] **Step 3: デリゲートを 3 アクション対応へ実装**

`Sources/BuildServerIntegration/XcodeScheme.swift` の `private final class SchemeReferenceDelegate ... }`(146-184 行目相当、Task 1 でリネーム済み)を**丸ごと**次に置換:

```swift
private final class SchemeReferenceDelegate: NSObject, XMLParserDelegate {
  var references: [XcodeScheme.SchemeBuildableReference] = []
  /// How many currently-open ancestor elements are a build/test/launch action. A `BuildableReference`
  /// counts as a build seed when this is > 0. The three actions are siblings (never nested) in a scheme,
  /// but a counter handles arbitrary nesting robustly and ignores references outside these actions.
  private var seedActionDepth = 0

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String]
  ) {
    switch elementName {
    case "BuildAction", "TestAction", "LaunchAction":
      seedActionDepth += 1
    case "BuildableReference":
      if seedActionDepth > 0, let name = attributeDict["BlueprintName"] {
        references.append(
          XcodeScheme.SchemeBuildableReference(
            blueprintName: name,
            referencedContainer: attributeDict["ReferencedContainer"]
          )
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
    switch elementName {
    case "BuildAction", "TestAction", "LaunchAction":
      seedActionDepth -= 1
    default:
      break
    }
  }
}
```

- [ ] **Step 4: テストを実行して緑を確認**

Run:
```sh
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeSchemeTests
```
Expected: PASS(新テスト + 既存の build-action 系テスト・dedup テスト・`buildTargets` 系テストが全て通る)

- [ ] **Step 5: format & commit**

```sh
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift format -ipr Sources/BuildServerIntegration/XcodeScheme.swift Tests/BuildServerIntegrationTests/XcodeSchemeTests.swift
git add Sources/BuildServerIntegration/XcodeScheme.swift Tests/BuildServerIntegrationTests/XcodeSchemeTests.swift
git commit -m "feat(BuildServerIntegration): collect Test/Launch action scheme seeds

SchemeReferenceDelegate now collects every BuildableReference nested under
a BuildAction, TestAction, or LaunchAction (via an ancestor depth counter),
so test bundles referenced only in a scheme's Test action (and the launch
runnable) become scope seeds. Skipped testables are included: scope is about
indexing, not running. Duplicates across actions are de-duplicated.

Task context: XcodeBuildServer follow-up 'scheme の Test/Run 対応'.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 3: フィクスチャ拡張 + 統合テスト(macOS + Xcode 26.4)

テストターゲットを **BuildAction には載せず TestAction の Testables にだけ**書いた scheme を作り、`xcode.scheme` 指定でそのテストターゲットがスコープに入ることを検証する。`MyAppTests` は `MyApp` の依存クロージャには現れない(テストがアプリに依存する向きで、逆ではない)ため、Test アクションの seed 収集が無ければスコープに入らない = 本機能の核心を突く。

**Files:**
- Modify: `Sources/SKTestSupport/XcodeTestProject.swift:1816-1847`(`writeSharedScheme` を拡張)
- Modify: `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift`(`testUnknownSchemeFallsBackToAllTargets` の直後に統合テスト追加)

- [ ] **Step 1: `writeSharedScheme` を TestAction/LaunchAction 出力対応へ拡張**

`Sources/SKTestSupport/XcodeTestProject.swift` の `writeSharedScheme(named:buildTargetNames:)`(1816-1847 行目、doc コメント含む)を**丸ごと**次へ置換(既存呼び出しは `buildTargetNames` のみで後方互換):

```swift
  /// Write a minimal shared `.xcscheme` named `name` into `<xcodeprojURL>/xcshareddata/xcschemes`.
  /// `buildTargetNames` populate the Build action; `testTargetNames` populate the Test action's
  /// `Testables`; `launchTargetName` (if any) populates the Launch action's runnable. Returns the
  /// written scheme file URL.
  ///
  /// Only the `BlueprintName` / `ReferencedContainer` attributes are meaningful to SourceKit-LSP's scheme
  /// parser; the other attributes are filled with the target name as a stand-in.
  @discardableResult
  package func writeSharedScheme(
    named name: String,
    buildTargetNames: [String],
    testTargetNames: [String] = [],
    launchTargetName: String? = nil
  ) throws -> URL {
    let schemesDir = xcodeprojURL.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true)
    try fileManager.createDirectory(at: schemesDir, withIntermediateDirectories: true)
    let container = xcodeprojURL.lastPathComponent
    func buildableReference(_ target: String) -> String {
      "<BuildableReference BuildableIdentifier=\"primary\" BlueprintIdentifier=\"\(target)\" BuildableName=\"\(target)\" BlueprintName=\"\(target)\" ReferencedContainer=\"container:\(container)\"></BuildableReference>"
    }
    let entryLines: [String] = buildTargetNames.flatMap { target -> [String] in
      [
        "         <BuildActionEntry buildForTesting=\"YES\" buildForRunning=\"YES\" buildForProfiling=\"YES\" buildForArchiving=\"YES\" buildForAnalyzing=\"YES\">",
        "            \(buildableReference(target))",
        "         </BuildActionEntry>",
      ]
    }
    var lines: [String] =
      [
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
        "<Scheme LastUpgradeVersion=\"1500\" version=\"1.7\">",
        "   <BuildAction parallelizeBuildables=\"YES\" buildImplicitDependencies=\"YES\">",
        "      <BuildActionEntries>",
      ] + entryLines + [
        "      </BuildActionEntries>",
        "   </BuildAction>",
      ]
    if !testTargetNames.isEmpty {
      let testableLines: [String] = testTargetNames.flatMap { target -> [String] in
        [
          "         <TestableReference skipped=\"NO\">",
          "            \(buildableReference(target))",
          "         </TestableReference>",
        ]
      }
      lines +=
        [
          "   <TestAction buildConfiguration=\"Debug\">",
          "      <Testables>",
        ] + testableLines + [
          "      </Testables>",
          "   </TestAction>",
        ]
    }
    if let launchTargetName {
      lines += [
        "   <LaunchAction buildConfiguration=\"Debug\">",
        "      <BuildableProductRunnable runnableDebuggingMode=\"0\">",
        "         \(buildableReference(launchTargetName))",
        "      </BuildableProductRunnable>",
        "   </LaunchAction>",
      ]
    }
    lines.append("</Scheme>")
    let url = schemesDir.appendingPathComponent("\(name).xcscheme", isDirectory: false)
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    return url
  }
```

- [ ] **Step 2: 統合テストを追加**

`Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift` の `testUnknownSchemeFallsBackToAllTargets`(462 行目で閉じる)の直後に追加:

```swift
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
```

- [ ] **Step 3: 統合テストを実行して緑を確認**

Run(初回ビルドは数分):
```sh
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeBuildServerTests/testSchemeScopesToTestActionTestables
```
Expected: PASS(`MyAppTests` と `MyApp` が両方スコープに含まれる)

> TDD ノート: Task 2 の単体テストが本機能の red→green ドライバ。本統合テストは end-to-end の検証(期待 PASS)。挙動が Test アクション seed に依存することを確かめたければ、Task 2 のデリゲート変更を一時退避すると本テストが落ちる(Xcode ビルドが重いため任意)。

- [ ] **Step 4: format & commit**

```sh
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift format -ipr Sources/SKTestSupport/XcodeTestProject.swift Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift
git add Sources/SKTestSupport/XcodeTestProject.swift Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift
git commit -m "test(BuildServerIntegration): scheme Test-action testable scoping

Extend writeSharedScheme to emit TestAction/LaunchAction, and add an
integration test (.appWithUnitTestTarget) asserting that a test target
referenced only in a scheme's Test action is scoped in, even though it is
not in MyApp's dependency closure.

Task context: XcodeBuildServer follow-up 'scheme の Test/Run 対応'.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 4: `scheme` doc コメント更新 + config schema 再生成

**Files:**
- Modify: `Sources/SKOptions/SourceKitLSPOptions.swift:152-154`
- Regenerated: `config.schema.json`, `Documentation/Configuration File.md`

- [ ] **Step 1: doc コメントを更新**

`Sources/SKOptions/SourceKitLSPOptions.swift` の `scheme` の doc コメント(152-154 行目)を置換:

```swift
    /// The Xcode scheme whose Build / Test / Launch action targets (plus their dependency closure) the
    /// build server is scoped to. If `nil`, all targets in the project/workspace are used. If the named
    /// scheme has no `.xcscheme` file but a same-named target exists, that target is used; otherwise all
    /// targets are used.
    public var scheme: String?
```

- [ ] **Step 2: config schema / ドキュメントを再生成**

Run:
```sh
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer ./sourcekit-lsp-dev-utils generate-config-schema
```
Expected: `config.schema.json` と `Documentation/Configuration File.md` の `scheme` 説明が新しい文面に更新される(両ファイルは "DO NOT EDIT" バナー付き=手編集禁止)。

- [ ] **Step 3: 差分が想定どおりか確認**

Run:
```sh
git status --short && git diff --stat
```
Expected: 変更は `Sources/SKOptions/SourceKitLSPOptions.swift` / `config.schema.json` / `Documentation/Configuration File.md` の 3 ファイルのみ。`scheme` の説明文だけが変わっていること(無関係な大量差分が出ていないこと)を `git diff config.schema.json` で確認。

- [ ] **Step 4: commit**

```sh
git add "Sources/SKOptions/SourceKitLSPOptions.swift" "config.schema.json" "Documentation/Configuration File.md"
git commit -m "docs(SKOptions): scheme scopes Build/Test/Launch actions

Update the xcode.scheme doc comment to reflect that scope seeds now come
from the Build, Test, and Launch actions, and regenerate config.schema.json
and Documentation/Configuration File.md.

Task context: XcodeBuildServer follow-up 'scheme の Test/Run 対応'.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 5: 最終検証(format + 全 BuildServerIntegrationTests)

**Files:** なし(検証のみ)

- [ ] **Step 1: 全体フォーマットの確認**

Run:
```sh
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift format lint --strict --recursive Sources/BuildServerIntegration Sources/SKTestSupport Sources/SKOptions Tests/BuildServerIntegrationTests
```
Expected: 出力なし(lint 違反ゼロ)。違反があれば `swift format -ipr <file>` で修正してから再実行。

- [ ] **Step 2: BuildServerIntegrationTests を全実行**

Run(Xcode 統合テスト含む。数分):
```sh
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter BuildServerIntegrationTests
```
Expected: PASS(0 failures)。直近の基準は 118 件 + Swift Testing 29 件。新規単体テスト 1 件・統合テスト 1 件が増える。

- [ ] **Step 3: 完了確認**

`git log --oneline -4` で Task 1〜4 の 4 コミットが並んでいることを確認。作業ツリーがクリーン(`git status --short` が `.claude/` / `CLAUDE.md` のみ)であることを確認。

---

## Self-Review(作成者チェック結果)

- **Spec coverage:**
  - 収集ルール(3 アクションの子孫 `BuildableReference`)→ Task 2。
  - `skipped="YES"` 収集 → Task 2 の `AppUITests` 検証。
  - 重複排除(アクション跨ぎ)→ Task 2 の LaunchAction `App` dedup 検証。
  - `resolveScheme`/フォールバック無改修 → 全 Task で改修対象外(明記)。
  - リネーム → Task 1。
  - 統合テスト(TestAction のみのテストターゲット)→ Task 3。
  - 非回帰(BuildAction のみ / scheme 未指定)→ Task 5 の全テスト実行で既存テストがカバー。
  - doc コメント + 生成物再生成 → Task 4。
- **Placeholder scan:** TBD/TODO/曖昧指示なし。各コードステップは実コードを含む。
- **Type consistency:** `schemeSeedReferences` / `SchemeReferenceDelegate` / `writeSharedScheme(named:buildTargetNames:testTargetNames:launchTargetName:)` は全 Task で一貫。`SchemeBuildableReference(blueprintName:referencedContainer:)` は既存シグネチャに一致。
