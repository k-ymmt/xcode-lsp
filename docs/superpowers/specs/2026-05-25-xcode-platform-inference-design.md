# 設計: XcodeBuildServer プラットフォーム推定

作成日: 2026-05-25
関連: [XcodeBuildServer 設計](2026-05-25-xcode-build-server-design.md)

## 目的

`XcodeBuildServer` が `.xcodeproj` / `.xcworkspace` のターゲットに対して、ユーザーが
`xcode.destination` を明示しなくても**正しい実行先 (run destination) を推定**できるようにする。
現状 iOS / tvOS / watchOS のターゲットはすべて macOS にフォールバックしており、誤った
`-sdk` / `-target` で補完・インデックスが行われる。

## 背景・現状の問題

`SwiftBuildSession.targets()` (`Sources/BuildServerIntegration/SwiftBuildSession.swift:133-140`)
は各ターゲットを `XcodeTarget(guid:name:platforms: [])` として返している。`platforms` が常に
空配列のため、`runDestination(for:)` → `runDestination(forPlatform: target.platforms.first)`
は常に `default` ケースに入り `.macOS` を返す(`:310-337` の TODO)。

`config.schema.json:376` は「destination が `nil` なら各ターゲットの対応プラットフォームから推定」と
記載しているが、実態と乖離している。本作業でこの記載どおりの挙動を実装する。

## 調査で確定した事実

- `SWBTargetInfo` の公開フィールドは `guid` / `targetName` / `projectName` /
  `dynamicTargetVariantGuid` のみ。プラットフォーム情報は持たない(swift-build の
  `Sources/SwiftBuild/SWBWorkspaceInfo.swift` で確認)。
- `SWBBuildServiceSession.evaluateMacroAsStringList(_:level:buildParameters:overrides:)` で
  ビルド設定をターゲット単位 (`SWBMacroEvaluationLevel.target(guid)`) で評価できる。
  swift-build の `Tests/SwiftBuildTests/MacroEvaluationTests.swift` は、`activeRunDestination`
  を設定しない素の `SWBBuildParameters()` でターゲットレベル評価が成立することを示している
  (`EFFECTIVE_PLATFORM_NAME` 等を評価)。
- したがって `SUPPORTED_PLATFORMS` を destination 未指定で評価でき、これがターゲットの
  対応プラットフォーム集合(例: `["iphoneos", "iphonesimulator"]`)を返す。
- `SWBBuildParameters.activeRunDestination` は optional だが、未設定時に
  `generateIndexingFileSettings` が正しい per-platform 引数を返す保証は無いため、destination は
  明示的に構築する(現実装の方針を踏襲)。

## アプローチ

採用: **`SUPPORTED_PLATFORMS` をマクロ評価**(検討した代替案: `SDKROOT` 単一値評価、
`activeRunDestination` を nil にして SwiftBuild に委ねる)。

- 既存の `runDestination(forPlatform:)` の switch キー(`iphoneos` / `iphonesimulator` 等)と
  プラットフォーム名がそのまま一致する。
- 対応プラットフォームの**集合**が取れるため、シミュレータ優先などの選択ができる。
- swift-build のテストで destination 無し評価の実績がある。決定的で追加ビルド不要。

## 変更点

### 1. `SwiftBuildSession.targets()` で `platforms` を populate

各 `targetInfo` について `SUPPORTED_PLATFORMS` をターゲットレベルで評価し、
`XcodeTarget.platforms` に格納する。

```swift
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

/// Evaluate `SUPPORTED_PLATFORMS` for a target. Returns an empty array on failure so that
/// destination selection falls back to macOS rather than failing target enumeration.
private func supportedPlatforms(forTargetGUID guid: String) async -> [String] {
  var params = SWBBuildParameters()
  params.configurationName = configuration
  return (try? await session.evaluateMacroAsStringList(
    "SUPPORTED_PLATFORMS",
    level: .target(guid),
    buildParameters: params,
    overrides: [:]
  )) ?? []
}
```

- destination は未設定。`SUPPORTED_PLATFORMS` は destination 非依存。
- `configurationName` は `self.configuration` を設定。
- 評価失敗(マクロ未定義など)は当該ターゲットのみ空配列にし、列挙全体は壊さない。

### 2. destination 選択を集合ベースに

`runDestination(forPlatform:)`(単一プラットフォーム→destination)を、対応プラットフォーム
**集合**から固定優先順で選ぶ純関数 `bestRunDestination(forSupportedPlatforms:)` に置き換える。

```swift
static func bestRunDestination(forSupportedPlatforms supported: [String]) -> SWBRunDestinationInfo {
  let set = Set(supported)
  // 優先順: macOS(ホストネイティブ・常に利用可) → 各ファミリはシミュレータ優先 → デバイス。
  let order: [(platform: String, destination: SWBRunDestinationInfo)] = [
    ("macosx", .macOS),
    ("iphonesimulator", .iOSSimulator),
    ("appletvsimulator", .tvOSSimulator),
    ("watchsimulator", .watchOSSimulator),
    ("iphoneos", .iOS),
    ("appletvos", .tvOS),
    ("watchos", .watchOS),
  ]
  for entry in order where set.contains(entry.platform) {
    return entry.destination
  }
  return .macOS  // 不明時の従来フォールバック
}
```

`runDestination(for:)` は override 優先のまま、未指定時に
`Self.bestRunDestination(forSupportedPlatforms: target.platforms)` を呼ぶ。

#### 選択方針

- **クロスファミリ**: macOS が対応集合にあれば最優先。ホストネイティブで常に利用可能・
  シミュレータランタイム不要のため最も安全。iOS 専用ターゲットなら `macosx` は集合に無く、
  `iphonesimulator` が選ばれる。
- **同一ファミリ内**: シミュレータ優先(コード署名・デバイス provisioning 不要で、ヘッドレスな
  インデックス・補完に適する)。デバイスは対応するシミュレータが無い場合のみ。

## テスト

### 単体テスト(Xcode 不要)

`bestRunDestination(forSupportedPlatforms:)` は静的純関数なので全環境で実行可能。返る
`SWBRunDestinationInfo` の `platform` / `sdk` を検証する。

| 入力 | 期待 destination の platform |
|------|------------------------------|
| `["macosx"]` | `macosx` |
| `["iphoneos", "iphonesimulator"]` | `iphonesimulator` |
| `["iphoneos"]` | `iphoneos` |
| `["appletvos", "appletvsimulator"]` | `appletvsimulator` |
| `["watchos", "watchsimulator"]` | `watchsimulator` |
| `["macosx", "iphoneos", "iphonesimulator"]` | `macosx`(クロスファミリ規則) |
| `[]` | `macosx`(フォールバック) |

### 統合テスト(macOS + Xcode、既存のホスト条件ゲートを踏襲)

- **既存 macOS フィクスチャ**: `targets()` が返す `platforms` に `macosx` が含まれること。
  実 SwiftBuild に対して `SUPPORTED_PLATFORMS` 評価が機能することの end-to-end 証明。
- **新規 iOS フィクスチャ**: `XcodeTestProject` に iOS アプリターゲット
  (`com.apple.product-type.application`, `SDKROOT = iphoneos`)の検証済み `project.pbxproj`
  バリアントを追加。`xcodebuild -list` / `-dumpPIF` / `plutil -lint`(Xcode 26.4)で検証する。
  この iOS ターゲットを `destination` 未指定でロード → `indexingFiles` が返す Swift 引数に
  iOS シミュレータの `-sdk`(`.../iPhoneSimulator*.sdk`)または `-target arm64-apple-ios*-simulator`
  が含まれること。これがバグ(iOS が macOS にフォールバック)の直接的な回帰テスト。

## スコープ外 / フォローアップ

- **visionOS** (`xros` / `xrsimulator`): 現状コードも未対応。SDK / プラットフォーム命名の確認が
  必要なため本作業では対象外。`bestRunDestination` の優先順テーブルと
  `SWBRunDestinationInfo` 便宜 destination への追加で対応可能なフォローアップ。
- `config.schema.json` の destination 説明文(「各ターゲットの対応プラットフォームから推定」)は
  本変更で実態と一致するため修正不要。

## 完了の定義 (Definition of Done)

- `SwiftBuildSession.targets()` が各ターゲットの実際の対応プラットフォームを `platforms` に返す。
- `xcode.destination` 未指定時、iOS / tvOS / watchOS ターゲットがそれぞれのシミュレータ
  destination に解決される(macOS フォールバックしない)。macOS ターゲットは引き続き macOS。
- `xcode.destination` 明示指定は従来どおり最優先で尊重される。
- `bestRunDestination(forSupportedPlatforms:)` の単体テストが全環境で通過する。
- macOS + Xcode 環境で、iOS フィクスチャが iOS シミュレータの `-sdk` / `-target` を生成する
  統合テストが通過する。
- 既存の `BuildServerIntegrationTests`(93 件)が非回帰で通過する。
- `SwiftBuildSession.swift:333` の TODO が解消される。
