# 設計: XcodeBuildServer scheme 対応

作成日: 2026-05-25
関連: [XcodeBuildServer 設計](2026-05-25-xcode-build-server-design.md) / [プラットフォーム推定設計](2026-05-25-xcode-platform-inference-design.md)

## 目的

`xcode.scheme` 設定を実際に機能させ、指定された scheme の **Build アクションに含まれる
ターゲットとその依存クロージャ**にビルドサーバーのスコープを限定する。大規模ワークスペースで、
関係するターゲットだけを補完・インデックス・準備の対象にし、ノイズと `prepare` コストを減らす。

## 背景・現状の問題

`SourceKitLSPOptions.XcodeOptions.scheme`
(`Sources/SKOptions/SourceKitLSPOptions.swift:152-153`)は存在し、設定マージ
(`merging(base:override:)`)も通るが、`XcodeBuildServer.init`
(`Sources/BuildServerIntegration/XcodeBuildServer.swift:50-70`)が読むのは
`configuration` / `destination` / `container` のみで、`scheme` は**一切参照されない**。
doc コメントも "Optional; informational for now." のまま。

現状 `XcodeBuildServer.allTargets()` は `SwiftBuildSession.targets()` が返す
**ワークスペースの全ターゲット**をそのまま広告・インデックス対象にする。

## 調査で確定した事実

- **SwiftBuild はディスク上の scheme を列挙する公開 API を持たない。**
  - `SWBBuildServiceSession.workspaceInfo()` はターゲットのみ(`SWBTargetInfo` =
    `guid` / `targetName` / `projectName` / `dynamicTargetVariantGuid`)。scheme 情報なし。
  - `describeSchemes(input: [SWBSchemeInput])` は**クライアントが target 識別子込みの scheme 入力を
    渡す**設計(逆引きではない)。返る `SWBProductInfo.identifier` は product 識別子で target GUID
    ではない。`describeArchivableProducts` も入力に scheme が必要。
  - したがって `.xcscheme` の解釈は **クライアント(=本実装)の責務**。
- **依存クロージャは SwiftBuild で計算できる。**
  `computeDependencyClosure(targetGUIDs: [String], buildParameters:, includeImplicitDependencies: Bool) -> [String]`
  が GUID 集合を受け、依存クロージャを GUID で返す。`includeImplicitDependencies: true` で
  Xcode の暗黙依存解決に一致する。
- `.xcscheme` の `BuildAction > BuildActionEntries > BuildActionEntry > BuildableReference` は
  `BlueprintName` 属性に**ターゲット名**を持つ。これは `SWBTargetInfo.targetName`
  (= `XcodeTarget.name`)と一致する。`BlueprintIdentifier` は pbxproj オブジェクト ID で、
  SWB の GUID 形式との対応は PIF 変換依存・未検証。

## アプローチ

採用: **`.xcscheme` を自前パースし、Build アクションのターゲット名で `XcodeTarget` を照合 →
SwiftBuild の依存クロージャで拡張 → `allTargets()` をフィルタ**。

検討した代替案と却下理由:

- **SwiftBuild の `describeSchemes` / `describeArchivableProducts`**: 入力に target 識別子が必要で
  循環。返るのは product 識別子で GUID でない。ディスクの scheme を列挙しない。→ 不適。
- **`xcodebuild -list -json` 等への shell out**: プロセス起動コスト。`-list` は scheme→target の
  対応を返さない。→ 不適。

照合を**ターゲット名(`BlueprintName` ↔ `XcodeTarget.name`)**で行う理由: 既存の公開フィールド
だけで完結し、`import SwiftBuild` の隔離(`SwiftBuildSession` に閉じ込める方針)を保てる。
`BlueprintIdentifier`→GUID 照合は PIF の GUID 形式検証が必要で、本作業では採らない。

## scheme 意味論(確定事項)

- **スコープ = Build アクションのターゲット + 依存クロージャ。** scheme の Build アクションに
  明示されたターゲットを起点に、`computeDependencyClosure(includeImplicitDependencies: true)` で
  依存(暗黙依存含む)を加えた GUID 集合をスコープとする。編集中の依存フレームワークも
  インデックスされる。
- **解決失敗時のフォールバック**: 指定 scheme 名に一致する `.xcscheme` ファイルが見つからない場合、
  1. **同名ターゲット**が存在すればそれ + 依存クロージャをスコープ(Xcode の自動生成スキームを救済。
     自動生成スキームはディスクにファイルが無く、同名ターゲット 1 つをビルドするため)。
  2. それも無ければ**警告ログを出して全ターゲット**にフォールバック(scheme 未指定と同じ挙動)。
- **scheme 未指定**(`scheme == nil`): 従来どおり全ターゲット。挙動は不変。

## 全体構成

```
XcodeBuildServer.allTargets()                       ← 唯一のフィルタ点（キャッシュ）
  ├─ scheme 未指定 → session.targets()（全ターゲット・現状どおり）
  └─ scheme 指定:
       1. XcodeScheme.targetNames(scheme:containerPath:projectRoot:) -> [String]?
            - <container> 配下を探索（共有優先 → ユーザー）。.xcworkspace はメンバー project も。
            - 見つからなければ nil
       2. names → GUID 照合（allTargets の name と一致するもの）
       3. names が nil（ファイル不在）→ 同名ターゲットへフォールバック → 無ければ警告 + 全ターゲット
       4. session.dependencyClosure(forTargetGUIDs:) で依存拡張
       5. クロージャ GUID 集合で全ターゲットをフィルタ
```

`buildTargets` / `buildTargetSources` / `prepare` / `sourceKitOptions` は
すべて `allTargets()`(または GUID ルックアップ)を経由するため、フィルタ点が 1 箇所で
全経路にスコープが効く。GUID がスコープ外のターゲットに対する `indexingFiles(forTargetGUID:)`
は `allTargets().first(where:)` が空を返すため、自然に空結果となり整合する。

## 変更点

### 1. 新規 `Sources/BuildServerIntegration/XcodeScheme.swift`

scheme ファイルの探索と XML パースを担う純粋なユーティリティ(`import SwiftBuild` を持たない)。

```swift
package enum XcodeScheme {
  /// 指定 scheme 名の `.xcscheme` を探索し、Build アクションのターゲット名を返す。
  /// 該当ファイルが見つからなければ `nil`（呼び出し側がフォールバックを判断）。
  package static func targetNames(
    scheme: String,
    containerPath: URL,
    projectRoot: URL
  ) -> [String]?

  /// `.xcscheme` の XML 文字列から Build アクションのターゲット名（BlueprintName）を抽出する純関数。
  package static func buildActionTargetNames(xcschemeContents: Data) -> [String]
}
```

- **探索順**: 共有 `<...>/xcshareddata/xcschemes/<name>.xcscheme` を優先 →
  ユーザー `<...>/xcuserdata/*.xcuserdatad/xcschemes/<name>.xcscheme`。
  - `.xcodeproj` コンテナ: コンテナ直下の上記パス。
  - `.xcworkspace` コンテナ: ワークスペース自身の `xcshareddata`/`xcuserdata` に加え、
    `projectRoot` 配下の各 `.xcodeproj` の上記パスも探索。最初に一致したものを採用。
- **XML パース**: `Foundation.XMLParser`(追加依存なし)。
  `BuildAction > BuildActionEntries > BuildActionEntry > BuildableReference` の
  `BlueprintName` 属性を収集。`BuildActionEntry` の `buildForXXX` フラグは見ない
  (Build アクションに含まれる = インデックス対象とみなす)。重複名は dedupe。

### 2. `SwiftBuildSession` に依存クロージャ計算を追加

```swift
/// 与えた GUID 集合の依存クロージャ（暗黙依存含む）を GUID で返す。
package func dependencyClosure(forTargetGUIDs guids: [String]) async throws -> [String] {
  guard !guids.isEmpty else { return [] }
  var params = SWBBuildParameters()
  params.configurationName = configuration
  return try await session.computeDependencyClosure(
    targetGUIDs: guids,
    buildParameters: params,
    includeImplicitDependencies: true
  )
}
```

- build params は `configuration` のみ設定(クロージャは run destination 非依存で十分)。
- `import SwiftBuild` はこのファイル内に閉じたまま。

### 3. `XcodeBuildServer` の scheme フィルタ統合

- `init` で `self.scheme = options.xcodeOrDefault.scheme` を保持。
- `allTargets()` を拡張:

```swift
private func allTargets() async throws -> [XcodeTarget] {
  if let cachedTargets { return cachedTargets }
  let all = try await session.targets()
  let scoped = try await applySchemeScope(to: all)
  self.cachedTargets = scoped
  return scoped
}

private func applySchemeScope(to all: [XcodeTarget]) async throws -> [XcodeTarget] {
  guard let scheme else { return all }   // scheme 未指定 → 全ターゲット

  // 1. scheme ファイル解決
  let names = XcodeScheme.targetNames(scheme: scheme, containerPath: containerPath, projectRoot: projectRoot)

  // 2/3. 起点ターゲット GUID を決める（ファイル一致 → 同名ターゲット → 全ターゲット）
  let seedGUIDs: [String]
  if let names {
    seedGUIDs = all.filter { names.contains($0.name) }.map(\.guid)
  } else if let sameNamed = all.first(where: { $0.name == scheme }) {
    seedGUIDs = [sameNamed.guid]   // 自動生成スキーム救済
  } else {
    logger.log("Xcode scheme '\(scheme)' not found; indexing all targets")
    return all
  }
  guard !seedGUIDs.isEmpty else {
    logger.log("Xcode scheme '\(scheme)' resolved to no known targets; indexing all targets")
    return all
  }

  // 4. 依存クロージャで拡張
  let closure = Set(try await session.dependencyClosure(forTargetGUIDs: seedGUIDs))
  let scoped = all.filter { closure.contains($0.guid) }
  return scoped.isEmpty ? all : scoped
}
```

- `invalidateCaches()` は既存どおり `cachedTargets = nil` で、再ロード時にスコープも再計算される。

### 4. 設定 doc の更新

- `SourceKitLSPOptions.swift` の `scheme` コメントを更新(スコープ挙動を記述、"informational for now" を削除)。
- `config.schema.json`(生成物なら生成元)の `xcode.scheme` 説明を同様に更新。

## テスト

### 単体テスト(Xcode 不要・全環境)

- **XML パース** `buildActionTargetNames(xcschemeContents:)`:
  - 複数 `BuildActionEntry` → 全 `BlueprintName` を返す。
  - 空の `BuildAction` → 空配列。
  - 重複名 → dedupe。
- **ファイル探索** `targetNames(scheme:containerPath:projectRoot:)`:
  - temp ディレクトリに共有/ユーザー scheme を配置 → 共有優先。
  - 不在 → `nil`。
- **解決ロジック**(フォールバック分岐): scheme 名一致あり → 起点集合 / ファイル不在 + 同名ターゲット
  あり → 当該ターゲット / どちらも無し → 全ターゲット。純関数として切り出し検証可能なら切り出す。

### 統合テスト(macOS + Xcode、既存ホスト条件ゲートを踏襲)

- `SKTestSupport` の `XcodeTestProject` に **2 ターゲット + 一方をビルドする共有 scheme** の
  フィクスチャを追加(検証済み `project.pbxproj` + `xcshareddata/xcschemes/<name>.xcscheme`)。
- scheme 指定 → `buildTargets` が **scheme ターゲット + 依存のみ**を返し、対象外ターゲットが
  除外されることを確認。
- **依存クロージャ**検証: App → Framework 依存を持つフィクスチャで、scheme=App 指定時に
  Framework も含まれること。
- scheme 名がファイル・同名ターゲットいずれにも一致しない → 全ターゲットにフォールバック。

### 非回帰

- scheme 未指定で全ターゲットが返る既存挙動が不変。
- 既存 `BuildServerIntegrationTests` が非回帰で通過。

## スコープ外 / フォローアップ

- **同名ターゲットの曖昧性**(複数 project に同名ターゲット): 本作業では名前一致で全て起点に含める。
  `BuildableReference` の `ReferencedContainer` で project を限定する曖昧性解消はフォローアップ。
- **scheme の Test/Run アクション固有のターゲット**(テストターゲット等)は本作業では扱わない
  (Build アクションのみ)。
- **`BlueprintIdentifier`→GUID 照合**: より厳密だが PIF の GUID 形式検証が必要。フォローアップ。

## 完了の定義 (Definition of Done)

- `xcode.scheme` 指定時、`buildTargets` / `buildTargetSources` / `prepare` / `sourceKitOptions` が
  scheme の Build ターゲット + 依存クロージャに限定される。
- 指定 scheme の `.xcscheme` が無く同名ターゲットがある場合、そのターゲット + 依存にスコープされる
  (自動生成スキュームの救済)。
- scheme が一切解決できない場合、警告ログを出して全ターゲットにフォールバックする。
- `scheme` 未指定時の挙動は不変。
- `XcodeScheme` の XML パース・ファイル探索・フォールバック判定の単体テストが全環境で通過。
- macOS + Xcode で、scheme スコープと依存クロージャの統合テストが通過。
- 既存 `BuildServerIntegrationTests` が非回帰で通過。
- `scheme` の doc コメント / `config.schema.json` の説明が実態に更新される。
