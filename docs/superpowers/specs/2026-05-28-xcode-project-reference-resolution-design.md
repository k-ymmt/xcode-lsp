# Xcode project reference 経由の `.xcodeproj` をルート扱いする設計

- 日付: 2026-05-28
- 対象: `XcodeBuildServer`(`Sources/BuildServerIntegration`)
- 前提作業: 依存グラフ公開(#4/#5)、scheme コンテナ曖昧性解消(#2)、workspace
  サブディレクトリ解決(#B)。本作業はそれらで整備した「精密な root プロジェクト集合 +
  `.dependency` タグ + SwiftBuild 非依存の純粋パーサ」モデルの自然な拡張。

## 背景と問題

`XcodeBuildServer` は、開いたコンテナ(`.xcodeproj` 自身、または `.xcworkspace` の
`contents.xcworkspacedata` が宣言するメンバー `.xcodeproj`)を `rootProjectPaths()` とし、
各ターゲットの `PROJECT_FILE_PATH`(= 所有 `.xcodeproj`)がこの集合に含まれなければ
`.dependency` タグを付ける(`XcodeBuildServer.isPartOfRootProject`)。`.dependency` は
`BuildServerManager`(`isPartOfRootProject = !tags.contains(.dependency)`)でテスト探索などの
スコープから外す効果を持つ。これにより SwiftPM パッケージのソース/テストを誤探索しなくなる。

ところが `MyApp.xcodeproj` が `PBXProject.projectReferences` で別の `Framework.xcodeproj` を
**project reference** している構成では、SwiftBuild の PIF が参照先のターゲットも公開し、その
`PROJECT_FILE_PATH` は `Framework.xcodeproj` を指す。これは `rootProjectPaths()`(= 開いた
`MyApp.xcodeproj` のみ)に含まれないため、参照先ターゲットが誤って `.dependency` 扱いになる。

project reference は通常「ユーザーがローカルで開発するソース(自作 framework / ライブラリ)」を
指す。よって参照先ターゲットは**ルート扱い**(インデックス・テスト探索の対象)とすべきで、
SwiftPM パッケージ(別機構 `XC*SwiftPackage*` で表現され、`…/SourcePackages/…` 配下に解決)とは
区別される。本作業はこの誤タグを解消する。

## 確定した設計判断

- **参照先の扱い: ルート扱い(`.dependency` を付けない)。** モジュラー iOS アプリ
  (ローカル framework を project reference)で一般的な意図。サブディレクトリ解決(#B)の
  `.dependency` 誤タグ修正と同じ方向性。
- **発見手段: pbxproj 解析(権威的・加算的)。** SwiftBuild の `SWBWorkspaceInfo` は
  `targetInfos`(`guid`/`targetName`/`projectName`/`dynamicTargetVariantGuid`)のみで
  プロジェクト一覧やパスを公開しないため、project reference の有無は SwiftBuild に問い合わせ
  られない。各ルート `.xcodeproj` の `project.pbxproj` を解析して参照先を特定し、既存の精密な
  root 集合に**加算**する。SPM は project reference ではないので構造上除外される。
- **ロケーションヒューリスティック(`SourcePackages` 配下以外をルート)は不採用。** root 集合の
  定義を「SPM 以外すべて」に反転させるため既存の精密な membership モデル(scheme 曖昧性解消・
  サブディレクトリ解決が依存)への回帰リスクが大きく、パス規約にも依存する。

## スコープ

### スコープ内

- `rootProjectPaths()` を、シード(コンテナ自身 / workspace メンバー)から project reference を
  **推移的に**辿って展開する。
- 参照先ターゲットが `.dependency` タグを付与されないようにする(`isPartOfRootProject` は無改修で、
  入力の root 集合が広がることで正しくなる)。
- `.xcodeproj` 直接オープンと `.xcworkspace`(メンバーが非メンバーを参照)の両構成をカバー。

### スコープ外 / フォローアップ

- scheme の cross-project コンテナ解決(`XcodeScheme.resolveContainer` が参照先プロジェクトを
  またいで `container:` を解決する件)。本作業は `.dependency` タグに限定。
- `BlueprintIdentifier` → GUID 照合。
- workspace が別 `.xcworkspace` を参照する構成。
- visionOS(`xros`/`xrsimulator`)対応。

## アーキテクチャ

### 新規純粋型 `XcodeProject`

`Sources/BuildServerIntegration/XcodeProject.swift`。`import SwiftBuild` を持たない
(隔離契約維持)。`XcodeWorkspace` / `XcodeScheme` と並ぶ「XML/plist を解釈する純粋パーサ」。

```swift
/// 純粋関数。pbxproj をパースし、PBXProject.projectReferences が指す
/// 別 .xcodeproj への絶対 URL を解決して返す(dedupe 済み)。
package static func projectReferences(pbxprojContents: Data, projectDir: URL) -> [URL]

/// 薄い I/O ラッパ。<projectURL>/project.pbxproj を読み projectReferences を呼ぶ。
/// 読めない/不在なら []。
package static func referencedProjects(ofProjectAt projectURL: URL) -> [URL]
```

- パースは `PropertyListSerialization.propertyList(from:options:format:)`。pbxproj は旧式
  OpenStep plist(または XML/バイナリ plist)であり、いずれも**読み取り**は可能。
- `projectReferences` の解決:
  1. ルート辞書から `rootObject` ID → `objects[rootObject]`(PBXProject)を取得。
  2. PBXProject の `projectReferences` 配列(各要素は dict)→ `ProjectRef`(オブジェクト ID)。
  3. `objects[ProjectRef]`(PBXFileReference)を `resolvePath` で絶対 URL 化。
  4. 末尾が `.xcodeproj` のもののみ、`standardizedFileURL` で正規化し dedupe して返す。

### `rootProjectPaths()` の BFS 展開

`XcodeBuildServer.rootProjectPaths()`(現状 private・同期・非 throwing・`Set<URL>` を返す)を拡張:

1. シード集合を作る(現状どおり):`.xcodeproj` ならコンテナ自身、`.xcworkspace` なら
   `XcodeWorkspace.memberProjects`(不在時はトップレベルグロブにフォールバック)。
2. シードを起点に BFS:キューから `.xcodeproj` を取り出し `XcodeProject.referencedProjects` で
   直接参照先を取得、**ディスク上に存在する** `.xcodeproj` のみを、まだ visited でなければ集合と
   キューに追加。visited は `normalizedPath`(後述)で正規化したキーで管理し循環を防ぐ。
3. 展開後の集合を返す。

これにより `isPartOfRootProject` / `dependencyIdentifiers` / `resolveScheme` のコンテナ照合は
無改修で正しくなる(入力 root 集合が広がるだけ)。

### パス解決ルール(`resolvePath`)

`PBXFileReference` / `PBXGroup` は `path`(省略可)+ `sourceTree` を持ち、グループ階層に属する。
`objects` から child→parent グループマップ(各 PBXGroup/PBXVariantGroup の `children` を走査)を
作り、再帰的に解決する:

- **`<absolute>`**: `path` を絶対パスとして使用。
- **`SOURCE_ROOT`**: `projectDir`(`.xcodeproj` を含むディレクトリ)基準で `path` を結合。
- **`<group>`**: 親グループの解決パス基準で `path` を結合。親を辿って最終的に mainGroup
  (通常 `path` なし・親なし)→ `projectDir` に着地。ネストグループの `path` は順に累積。
- **`DEVELOPER_DIR` / `BUILT_PRODUCTS_DIR` / `SDKROOT` 等**: ディスク上のソースプロジェクトでは
  ないので解決対象外(`nil` を返しスキップ)。
- パス結合は `NSString.appendingPathComponent` 相当で行い、`standardizedFileURL` で `..` を正規化
  (`XcodeWorkspace.resolveLocation` と同じく RFC 相対解決の罠を避ける)。

### 正規化と比較

展開後の root パスは production では `normalizedPath`(`isPartOfRootProject` から抽出済みの共有
symlink 正規化ヘルパ)経由で `PROJECT_FILE_PATH` と比較される。解決したパス(例
`/var/.../Framework.xcodeproj`)と `PROJECT_FILE_PATH`(`/private/var/...`)が symlink 差異を
持っても両辺解決で一致する(サブディレクトリ解決 #B と同じ仕組み)。visited 集合のキーも
`normalizedPath` を用いる。

## テスト

### 単体テスト(`XcodeProjectTests`、全環境で実行・ディスク不要)

`projectReferences(pbxprojContents:projectDir:)` を網羅:

- `sourceTree = "<group>"`(mainGroup 直下、path が相対 `../Framework/Framework.xcodeproj`)。
- `sourceTree = "SOURCE_ROOT"`。
- `sourceTree = "<absolute>"`(絶対パス)。
- ネストグループ(`path` を持つグループ配下の参照)でのパス累積。
- 複数の project reference。
- 同一参照の重複 → dedupe。
- `.xcodeproj` 以外の `sourceTree`(`BUILT_PRODUCTS_DIR` 等)→ スキップ。
- project reference 無し → `[]`。
- 空 / 壊れた plist → `[]`(クラッシュしない)。

### 統合テスト(macOS + Xcode、`skipUnlessXcodeAvailable()` でゲート)

新フィクスチャ `XcodeTestProject(kind: .appWithProjectReference)`:

- `MyApp.xcodeproj`: アプリ(または実行可能)ターゲット `MyApp`。`Framework/Framework.xcodeproj`
  への project reference(`PBXFileReference` + `PBXContainerItemProxy` + `PBXReferenceProxy` +
  `ProductGroup`)を持ち、`MyApp` が `Framework` プロダクトに依存。
- `Framework/Framework.xcodeproj`: framework(またはライブラリ)ターゲット `Framework` と
  ソース 1 ファイル。
- 双方の pbxproj は手書きし、ID 衝突回避のため接頭辞を分離(既存フィクスチャの A1/B1 方式に倣う)。

テスト:

1. **`.dependency` 誤タグ修正の回帰テスト**: `MyApp.xcodeproj` を開き、`Framework` ターゲットに
   `.dependency` タグが**付かない**(root project と認識される)。旧コードで RED → 修正で GREEN。
2. 必要に応じて、`Framework` のソースがインデックス対象(`buildTargetSources`)に含まれることを確認。

### 非回帰

- 既存 `BuildServerIntegrationTests` が非回帰で通過。特に
  `XcodeTestProject(kind: .appWithPackageDependency)` の SwiftPM パッケージ `MyLib` が
  **引き続き `.dependency`** であること(SPM は project reference ではないので BFS 展開対象外)。
- scheme 未指定・`.xcodeproj` 直接オープン・workspace の挙動が project reference 無しの構成では不変。

## リスク / 検証ゲート

- **最大のリスク = フィクスチャの pbxproj 手書き。** project reference は
  `PBXFileReference`(参照先 `.xcodeproj`)+ `PBXContainerItemProxy` + `PBXReferenceProxy` +
  `ProductGroup` + proxy 経由の依存を正しく書く必要があり、これまでで最も複雑。実装時に
  **Xcode 26.4 の `xcrun xcodebuild -dumpPIF` で両ターゲットが別 GUID + 正しい `PROJECT_FILE_PATH`
  で公開されること**を検証してから先に進める(既存フィクスチャと同じ手順)。
- 上記 PIF 検証により「SwiftBuild が project-referenced ターゲットを `workspaceInfo()` に含める」
  という前提も同時に確認できる。万一含まれない場合は本設計の前提が崩れるため、その時点で再設計。

## 完了の定義 (Definition of Done)

- `XcodeProject.projectReferences` が pbxproj から project reference 先 `.xcodeproj` を解決
  (`<group>` / `SOURCE_ROOT` / `<absolute>` / ネストグループ / dedupe / 不正データ)。
- `rootProjectPaths()` がシードから project reference を推移展開し、ディスク上に存在する
  `.xcodeproj` のみを循環なく加える。
- project reference された `.xcodeproj` のターゲットに `.dependency` タグが付与されない。
- SwiftPM パッケージのターゲットは引き続き `.dependency`(回帰テストで実証)。
- `XcodeProject` は `import SwiftBuild` を持たない(隔離契約維持)。
- `XcodeProjectTests` の単体テストが全環境で通過。
- macOS + Xcode で `.dependency` 誤タグ修正の統合テストが通過。
- 既存 `BuildServerIntegrationTests` が非回帰で通過。

## 参考(実装の足場)

- `Sources/BuildServerIntegration/XcodeBuildServer.swift`: `rootProjectPaths()`(L142)、
  `isPartOfRootProject`(L333)、`normalizedPath`(L343)、`buildTargets`(L159)。
- `Sources/BuildServerIntegration/XcodeWorkspace.swift`: 純粋パーサ + 薄い I/O ラッパの先例。
- `Sources/BuildServerIntegration/SwiftBuildSession.swift`: `targets()`(L149)、
  `projectFilePath(forTargetGUID:)`(L259)。
- `Sources/SKTestSupport/XcodeTestProject.swift`: フィクスチャ authoring(手書き pbxproj
  テンプレート、`Kind` enum)。
- `Sources/BuildServerIntegration/BuildServerManager.swift:1655`: `.dependency` の消費側。
