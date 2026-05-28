# Xcode cross-project scheme コンテナ解決の設計（フォローアップ #D）

- 日付: 2026-05-28
- 対象: `XcodeBuildServer`（`Sources/BuildServerIntegration`）
- 前提作業: scheme コンテナ曖昧性解消（#2）、scheme の Test/Launch アクション対応（#A）、
  workspace サブディレクトリ解決（#B）、project reference 解決（#C）。本作業は #C で
  整備した「project reference を推移展開した精密な root プロジェクト集合」を scheme ファイル
  探索にも適用する自然な拡張。
- 関連 spec: [project reference 解決](2026-05-28-xcode-project-reference-resolution-design.md),
  [scheme コンテナ曖昧性解消](2026-05-27-xcode-scheme-container-disambiguation-design.md),
  [scheme Test/Launch アクション対応](2026-05-27-xcode-scheme-test-launch-actions-design.md)

## 背景と問題

`XcodeBuildServer` は `xcode.scheme` が設定されているとき、scheme が指す Build / Test / Launch
アクションのターゲット＋その依存クロージャにインデックス対象を絞る（`applySchemeScope`）。
scheme の解決は 2 段階：

1. **scheme ファイル探索**（`XcodeScheme.searchContainers` → `schemeFileURL`）。探索対象は
   「開いたコンテナ」＋（`.xcworkspace` なら）`contents.xcworkspacedata` が宣言するメンバー
   `.xcodeproj` のみ。
2. **`ReferencedContainer` のパス解決＋ターゲット照合**（`resolveContainer` →
   `resolveScheme`/`containerMatches`）。`container:<rel>` を scheme 所属コンテナのディレクトリ
   基準で絶対 `.xcodeproj` URL へ解決し、候補ターゲットの `projectFilePath`（PROJECT_FILE_PATH）と
   突き合わせて同名ターゲットの曖昧性を解消する（#2 で導入）。

#C で `rootProjectPaths()` は `PBXProject.projectReferences` を推移的に辿って参照先 `.xcodeproj` を
root 集合に取り込むようになった（`.dependency` 誤タグの解消）。しかし scheme ファイル探索（段階 1）は
依然「開いたコンテナ＋workspace メンバー」のみで、**project reference 先は探索対象外**。その結果、
project reference を使うモジュラー構成で次の 2 ケースが正しく扱えない：

- **ケース1（探索の穴）**: scheme ファイルが参照先プロジェクト内（例
  `Framework/Framework.xcodeproj/xcshareddata/xcschemes/`）にある場合、見つからず fallback して
  全ターゲットを index してしまう。Xcode は参照元プロジェクトを開くと参照先プロジェクトの共有
  scheme も一覧に出すため、ユーザーが `xcode.scheme` にそれを設定するのは正当なシナリオ。
- **ケース2（解決の裏付け不足）**: 開いたプロジェクトの scheme が `ReferencedContainer` で
  参照先ターゲットを直接指す場合。段階 2 のパス演算・照合は既存実装で成立する見込み（参照先
  ターゲットの `projectFilePath` が参照先 `.xcodeproj` を指し、scheme 内の解決済み container も
  同じ場所を指すため `containerMatches` が成立する）だが、**統合テストによる裏付けが無い**。

## 確定した設計判断

- **探索集合の単一真実源化（案1）**: scheme ファイル探索のコンテナ集合を呼び出し側
  （`applySchemeScope`）が算出し、`[containerPath] + rootProjectPaths()` を
  `XcodeScheme.buildTargets(scheme:searchContainers:)` に渡す。#C が作った「展開済み root 集合」を
  そのまま再利用し、`.xcodeproj` 直接オープン・`.xcworkspace`・project reference を一貫して扱う。
  `XcodeScheme` から workspace メンバー算出ロジック（`XcodeWorkspace` への結合）を取り除き、
  「与えられたコンテナ群から scheme を探して解析する」純粋な役割に縮める。
  - 不採用案2（`buildTargets(...,referencedProjects:)` の加算引数）: 差分は小さいが「探索集合」の
    算出が `XcodeScheme` と `rootProjectPaths()` の 2 箇所に分散し、単一真実源にならない。
  - 不採用案3（`XcodeScheme` が自前で project reference を辿る）: `expandedRootProjects` の BFS を
    二重実装し、`XcodeScheme` を pbxproj 解析へ結合させるため却下。
- **段階 2 は無改修**: `resolveContainer` / `resolveScheme` / `containerMatches` /
  `SchemeBuildTarget` は変更しない。ケース2 のデリバラブルは「既存ロジックが参照先プロジェクトを
  跨いで正しく動くことを統合テストで証明する」こと。万一実 Xcode の `ReferencedContainer` 基準が
  想定と異なれば見直すが、基準（scheme 所属コンテナのディレクトリ）は元々正しい。
- **scheme 名衝突は opened 優先**: 開いたコンテナを探索順の先頭に置く。shared→user の優先は不変。

## スコープ

### スコープ内

- `XcodeScheme.buildTargets` / `schemeFileURL` を、呼び出し側が渡す `searchContainers: [URL]`
  ベースに変更する。`XcodeScheme` 内のメンバー探索ロジックを削除。
- `applySchemeScope` が `[containerPath] + rootProjectPaths()`（順序付き dedup、`containerPath`
  先頭）を算出して渡す。
- ケース1（参照先プロジェクト内の scheme ファイルでスコープ）とケース2（opened の scheme が参照先
  ターゲットを container 指定）の双方を、単体テスト＋実 Xcode 統合テストで担保する。
- フィクスチャ `appWithProjectReference` に cross-project scheme を追加。

### スコープ外 / フォローアップ（持ち越し）

- `BlueprintIdentifier` → GUID 照合（現状は name + container 照合）。
- workspace が別 `.xcworkspace` を参照する構成。
- visionOS（`xros` / `xrsimulator`）対応。
- #5 の推移参照 A→B→C / workspace メンバーが非メンバーを参照する `.dependency` タグの SwiftBuild
  統合テスト（本フィクスチャは 2 段の project reference）。

## アーキテクチャ

### `XcodeScheme.swift`（SwiftBuild 非依存を維持）

```swift
/// scheme `.xcscheme` を `searchContainers` の各コンテナから探し（shared→user、与えられた順）、
/// 見つかったコンテナのディレクトリを基準に各 BuildableReference の container を絶対 URL へ解決。
/// 見つからなければ nil（呼び出し側が fallback を決める）。
package static func buildTargets(scheme: String, searchContainers: [URL]) -> [SchemeBuildTarget]?

// schemeFileURL も (scheme:searchContainers:) シグネチャへ。
// 既存の private searchContainers(containerPath:projectRoot:) と projectRoot 引数は削除。
// XcodeWorkspace への依存も解消（メンバー算出は呼び出し側 rootProjectPaths() が担う）。
```

`schemeSeedReferences` / `SchemeReferenceDelegate` / `resolveContainer` /
`SchemeBuildableReference` / `SchemeBuildTarget` は不変。

### `XcodeBuildServer.swift`

```swift
private func applySchemeScope(to all: [XcodeTarget]) async throws -> [XcodeTarget] {
  guard let scheme else { return all }
  let searchContainers = schemeSearchContainers()   // [containerPath] + rootProjectPaths(), 順序付き dedup
  let schemeTargets = XcodeScheme.buildTargets(scheme: scheme, searchContainers: searchContainers)
  switch Self.resolveScheme(named: scheme, schemeTargets: schemeTargets, allTargets: all) { ... }  // 不変
}

/// scheme ファイルを探すコンテナ群。開いたコンテナを先頭に、続けて #C で project reference を
/// 推移展開した root プロジェクト集合（パスでソート）。normalizedPath で重複吸収。
private func schemeSearchContainers() -> [URL]
```

`rootProjectPaths()`（既存）・`resolveScheme` / `containerMatches` / `normalizedPath`（既存）は無改修。

### フィクスチャ `XcodeTestProject.swift`

`appWithProjectReference`（`MyApp.xcodeproj` → `Framework/Framework.xcodeproj`、双方手書き pbxproj）
は既に存在。これに cross-project scheme を 2 つ足す：

- **ケース1**: `Framework/Framework.xcodeproj/xcshareddata/xcschemes/<name>.xcscheme`、Build アクションで
  `Framework` ターゲットを `container:Framework.xcodeproj` で参照。
- **ケース2**: `MyApp.xcodeproj/xcshareddata/xcschemes/<name>.xcscheme`、Build アクションで `Framework`
  ターゲットを `container:Framework/Framework.xcodeproj` で参照。

新ヘルパ（既存 `writeSharedScheme(named:buildTargetNames:...)` の ~10 呼び出し点を温存するため拡張ではなく追加）:

```swift
/// 任意の宛先 .xcodeproj の xcshareddata/xcschemes に shared scheme を書き出す。各 BuildableReference の
/// container を明示指定できる（writeWorkspaceSharedScheme の project 版）。XML 生成は両者で共通 private 化。
@discardableResult
package func writeSharedScheme(
  named name: String,
  inProject projectURL: URL,
  buildTargets: [(blueprintName: String, container: String)]
) throws -> URL
```

参照先 `.xcodeproj` の URL はフィクスチャからアクセサで公開（例 `referencedProjectURL: URL?`、
`.appWithProjectReference` 以外は `nil`）。

## エラー処理 / エッジケース

- **scheme 名衝突**（opened と参照先に同名 scheme）: 探索順先頭の opened を採用。
- **参照先が disk に不在**: `rootProjectPaths()` が existence-filter 済みのため探索集合に入らない。
- **dangling container**（scheme の `container:` が未ロードのプロジェクトを指す）: どのターゲットにも
  一致せず、全参照が外れた場合は `.fallbackNoKnownTargets`（全ターゲット index）に保守的フォールバック。
- **後方互換**: container 情報の無い scheme / target は名前一致のみ（`containerMatches` の nil 許容）で不変。
  project reference の無い構成・scheme 未指定では挙動不変。

## テスト計画

### 単体テスト（`XcodeSchemeTests` / `XcodeBuildServerTests`、全環境）

- `buildTargets(scheme:searchContainers:)` が **非オープンコンテナ**にある scheme を発見し、見つかった
  コンテナのディレクトリ基準で参照を解決する（ケース1 の探索）。
- 探索順: opened コンテナが参照先より先に走査される（同名 scheme で opened を採用）。shared→user 不変。
- `resolveContainer` の cross-project パス演算（`container:Framework/Framework.xcodeproj` を MyApp dir
  基準で解決）。
- `resolveScheme` + `containerMatches`: 参照先ターゲットを指す container が参照先ターゲットを選び、
  opened 側の同名ターゲットを選ばない（cross-project 風味の曖昧性解消）。

### 統合テスト（`XcodeBuildServerTests`、`skipUnlessXcodeAvailable()` ゲート、実 Xcode 26.4）

- **ケース1**: `appWithProjectReference` を開き `xcode.scheme = <Framework 側 scheme>` → スコープが
  `Framework` ターゲット（＋クロージャ）に絞られ Framework ソースが入る。
- **ケース2**: 同フィクスチャを開き `xcode.scheme = <MyApp 側で Framework を container 指定する scheme>`
  → スコープに `Framework` ターゲットが入る（cross-project container 参照が解決されている証明）。

`appWithProjectReference` の PIF は `Framework` ターゲットを公開済み（#C の統合テストで確認済み）。

## 受け入れ条件

- `XcodeScheme.buildTargets(scheme:searchContainers:)` へ移行し、`applySchemeScope` が
  `[containerPath] + rootProjectPaths()` を渡す。`XcodeScheme` は `XcodeWorkspace` に依存しない。
- ケース1・ケース2 の単体＋統合テストが green。
- `BuildServerIntegrationTests` 全通過（既存 182 件＋新規、0 失敗）。
- `import SwiftBuild` 隔離契約（`XcodeScheme` / `XcodeProject` / `XcodeWorkspace` は SwiftBuild 非依存）不変。
- scheme 未指定・project reference 無し構成の挙動不変。
