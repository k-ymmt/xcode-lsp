# 設計: XcodeBuildServer テストターゲットのタグ付与

作成日: 2026-05-27
関連: [XcodeBuildServer 設計](2026-05-25-xcode-build-server-design.md), [プラットフォーム推定](2026-05-25-xcode-platform-inference-design.md)

## 目的

`XcodeBuildServer` がロードした `.xcodeproj` / `.xcworkspace` のテストターゲットに対し、
BSP の `BuildTarget.tags` に `.test` を付与する。これにより Xcode プロジェクトでも
SourceKit-LSP のテスト探索(テストエクスプローラ / テスト用 CodeLens)が機能するようにする。

## 背景・現状の問題

`XcodeBuildServer.buildTargets()` (`Sources/BuildServerIntegration/XcodeBuildServer.swift:140-156`)
は全ターゲットを `tags: []` で返している。一方 `SwiftPMBuildServer` は `isTestTarget` のとき
`.test` を付与する(`Sources/BuildServerIntegration/SwiftPMBuildServer.swift:601-607`)。

SourceKit-LSP のテスト探索は `.test` タグに依存している。
`BuildServerManager.sourceFilesAndDirectories()` (`:1656`) が
`let mayContainTests = target?.tags.contains(.test) ?? true` で `SourceFileInfo.mayContainTests`
を決めるため、ターゲットが非 nil かつ tags 空の Xcode ターゲットでは `mayContainTests = false`
となる。結果、両方のテスト探索経路が空になる:

- **`workspace/tests`**: `projectTestFiles()` (`:1689-1696`) が
  `guard info.isPartOfRootProject, info.mayContainTests` で絞るため、Xcode では空配列を返す。
  `TestDiscovery.swift:229-233` のフォールバック(開いている全ドキュメントを走査)は
  `projectTestFiles()` が **throw した場合のみ**働き、空配列を返す本ケースでは働かない。
- **`textDocument/tests`**: `TestDiscovery.swift:343-347` が
  `if let sourceFileInfo, !sourceFileInfo.mayContainTests { return [] }` で即時に空を返す。

つまり Xcode プロジェクトではテスト探索が全面的に動作していない。

## 調査で確定した事実

- `WorkspaceInfoResponse.WorkspaceInfo.TargetInfo` の公開フィールドは `guid` / `targetName` のみで、
  product type を持たない(swift-build `Sources/SWBProtocol/Message.swift:1097-1098`)。よって
  `session.workspaceInfo()` からは直接テスト種別を判定できない。
- ターゲットの product type 識別子はビルド設定 `PRODUCT_TYPE` に入る。
  `SWBBuildServiceSession.evaluateMacroAsString(_:level:buildParameters:overrides:)`
  (swift-build `Sources/SwiftBuild/SWBBuildServiceSession.swift:486`) でターゲットレベル
  (`SWBMacroEvaluationLevel.target(guid)`)で評価できる。これは `SUPPORTED_PLATFORMS` 評価
  (`SwiftBuildSession.swift:168-179`)と同じ仕組み・同じ呼び出し方であり実績がある。
- テストバンドルの product type 識別子は2種類。swift-build 内部の `ProjectPlanner.swift:52-53`
  も両方をテスト扱いしている:
  - `com.apple.product-type.bundle.unit-test`(ユニットテスト = XCTest / swift-testing)
  - `com.apple.product-type.bundle.ui-testing`(UI テスト)
- テスト探索のもう一つの条件 `isPartOfRootProject` は、`.dependency` タグ未設定の現状では
  常に true(`BuildServerManager.swift:1655`)。したがって `.test` タグの付与だけで探索経路は
  開通し、依存グラフ対応(別案件)は不要。

## アプローチ

採用: **`PRODUCT_TYPE` をターゲットレベルでマクロ評価**(検討した代替案: SUPPORTED_PLATFORMS と
まとめて1回で評価 / ターゲット名ヒューリスティック)。

- 既存の `supportedPlatforms(forTargetGUID:)` と同一パターンで、差分が局所的。
- 判定(識別子→真偽)を純粋関数に切り出せば `SwiftBuild` 非依存で単体テスト可能
  (`resolveScheme` (`XcodeBuildServer.swift:298`) と同じ流儀)。
- まとめ評価(代替案)はラウンドトリップを1回減らすが、マクロ評価はインプロセスで安価なため
  早すぎる最適化。名前ヒューリスティック(代替案)は命名規約依存で Xcode の意味論と乖離するため却下。

## 変更点

### 1. `XcodeTarget` に `isTestTarget` を追加 (`SwiftBuildSession.swift`)

`platforms` と同じ要領で `package var isTestTarget: Bool` を追加し、`init` を更新する。

```swift
package struct XcodeTarget: Sendable, Equatable {
  package var guid: String
  package var name: String
  package var platforms: [String]
  /// Whether this target builds a test bundle (unit-test or UI-testing product type).
  package var isTestTarget: Bool

  // `isTestTarget` defaults to `false` so existing call sites that don't care about it
  // (e.g. the `resolveScheme` unit tests in `XcodeBuildServerTests.swift`) compile unchanged.
  package init(guid: String, name: String, platforms: [String], isTestTarget: Bool = false) {
    self.guid = guid
    self.name = name
    self.platforms = platforms
    self.isTestTarget = isTestTarget
  }
}
```

既存の `XcodeTarget` 構築箇所は実プロデューサの `targets()`(変更対象)と
`XcodeBuildServerTests.swift` の `resolveScheme` テスト9箇所のみ。後者は `isTestTarget` に
無関心なため、デフォルト値により無変更でコンパイルできる。

### 2. `targets()` で product type を評価して populate (`SwiftBuildSession.swift`)

`supportedPlatforms(forTargetGUID:)` に倣い、各ターゲットの `PRODUCT_TYPE` を評価して
`isTestTarget` を設定する。

```swift
package func targets() async throws -> [XcodeTarget] {
  let info = try await session.workspaceInfo()
  var result: [XcodeTarget] = []
  for targetInfo in info.targetInfos {
    let platforms = await supportedPlatforms(forTargetGUID: targetInfo.guid)
    let isTest = await isTestTarget(forTargetGUID: targetInfo.guid)
    result.append(
      XcodeTarget(guid: targetInfo.guid, name: targetInfo.targetName, platforms: platforms, isTestTarget: isTest)
    )
  }
  return result
}

/// Evaluate `PRODUCT_TYPE` for a target and classify it as a test bundle or not.
///
/// `PRODUCT_TYPE` does not depend on the active run destination, so this evaluates with build
/// parameters that set only the configuration. Returns `false` on failure so that an unevaluable
/// target is treated as a non-test target rather than failing target enumeration.
private func isTestTarget(forTargetGUID guid: String) async -> Bool {
  var params = SWBBuildParameters()
  params.configurationName = configuration
  let identifier = await orLog("Evaluating PRODUCT_TYPE for target \(guid)") {
    try await session.evaluateMacroAsString(
      "PRODUCT_TYPE",
      level: .target(guid),
      buildParameters: params,
      overrides: [:]
    )
  }
  return Self.isTestProductType(identifier ?? "")
}

/// Whether a `PRODUCT_TYPE` identifier denotes a test bundle.
///
/// `package` (not `private`) so it is unit-testable; it touches no `SwiftBuild` types.
package static func isTestProductType(_ identifier: String) -> Bool {
  identifier == "com.apple.product-type.bundle.unit-test"
    || identifier == "com.apple.product-type.bundle.ui-testing"
}
```

- destination は未設定。`PRODUCT_TYPE` は destination 非依存。
- `configurationName` のみ `self.configuration` を設定(platforms 評価と同じ)。
- 評価失敗は当該ターゲットを非テスト扱いにし、列挙全体は壊さない(`orLog` でログのみ)。

### 3. `buildTargets()` でタグに反映 (`XcodeBuildServer.swift:146`)

```swift
return BuildTarget(
  id: try BuildTargetIdentifier.createXcode(targetGUID: target.guid),
  displayName: target.name,
  tags: target.isTestTarget ? [.test] : [],
  ...
)
```

## テスト

### 単体テスト(Xcode 不要・全環境)

`isTestProductType(_:)` は静的純関数なので全環境で実行可能。

| 入力(`PRODUCT_TYPE`) | 期待 |
|------|------|
| `com.apple.product-type.bundle.unit-test` | `true` |
| `com.apple.product-type.bundle.ui-testing` | `true` |
| `com.apple.product-type.application` | `false` |
| `com.apple.product-type.framework` | `false` |
| `""`(評価失敗時) | `false` |

### フィクスチャ(`SKTestSupport`)

既存の `XcodeTestProject` 系フィクスチャに、アプリ(または framework)ターゲットと
ユニットテストターゲットを併せ持つバリアントを追加する。`project.pbxproj` は既存フィクスチャと
同じ手順(`xcodebuild -list` / `-dumpPIF` / `plutil -lint`、Xcode 26.4)で検証する。
テストターゲットの product type は `com.apple.product-type.bundle.unit-test`。

### 統合テスト(macOS + Xcode、既存のホスト条件ゲートを踏襲)

- 上記フィクスチャをロード → `XcodeBuildServer.buildTargets()` のレスポンスで、テストターゲットの
  `BuildTarget.tags` に `.test` が含まれ、非テストターゲットには含まれないことを検証。
  実 SwiftBuild に対する `PRODUCT_TYPE` 評価の end-to-end 証明であり、本バグの直接的な回帰テスト。

## スコープ外 / フォローアップ

- **`.dependency` タグ / 依存グラフ公開**(ギャップ #4, #5): `isPartOfRootProject` は現状 true 固定で
  テスト探索には影響しないため本作業では対象外。別案件。
- **実際のテスト構文・意味解析**(XCTest / swift-testing の関数検出): 既存の syntactic /
  semantic 機構が担う。タグ付与で探索経路が開通すれば動くため、本作業では変更しない。

## 完了の定義 (Definition of Done)

- `SwiftBuildSession.targets()` が各ターゲットの `isTestTarget` を `PRODUCT_TYPE` 評価で返す。
- `XcodeBuildServer.buildTargets()` がテストターゲットに `.test` タグを付与する。
- `isTestProductType(_:)` の単体テストが全環境で通過する。
- macOS + Xcode 環境で、テストターゲットを含むフィクスチャをロードしたとき
  テストターゲットにのみ `.test` が付くことを検証する統合テストが通過する。
- 既存の `BuildServerIntegrationTests` が非回帰で通過する。
