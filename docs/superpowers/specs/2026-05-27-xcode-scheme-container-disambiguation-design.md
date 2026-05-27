# 設計: スキームの同名ターゲット曖昧性解消（`ReferencedContainer` パス照合）

作成日: 2026-05-27
関連: [XcodeBuildServer 設計](2026-05-25-xcode-build-server-design.md), [スキーム対応](2026-05-25-xcode-scheme-support-design.md), [依存グラフ公開](2026-05-27-xcode-dependency-graph-design.md)

## 目的

`xcode.scheme` でスコープする際、`.xcworkspace` 内の複数 `.xcodeproj` に**同名ターゲット**があっても、
スキームが意図したターゲットだけを起点に選べるようにする。スキーム対応 spec の「スコープ外 / フォローアップ」
で先送りした項目（`BuildableReference` の `ReferencedContainer` で project を限定する曖昧性解消）を解消する。

## 背景・現状の問題

`XcodeBuildServer.resolveScheme(named:schemeTargetNames:allTargets:)`
(`Sources/BuildServerIntegration/XcodeBuildServer.swift:358-372`) は、スキームの Build アクションが参照する
ターゲット名（`BlueprintName`）と各 `XcodeTarget.name` を**名前一致だけ**で突き合わせて起点 GUID を決める:

```swift
let nameSet = Set(names)
let guids = allTargets.filter { nameSet.contains($0.name) }.map(\.guid)
```

単一の `.xcodeproj` ではターゲット名が一意なので問題にならない（Xcode は同一プロジェクト内の同名ターゲットを禁止）。
しかし `.xcworkspace` が複数の `.xcodeproj` を束ねる場合、別プロジェクトに同名ターゲット（例: 双方に `App`）が
存在し得る。このとき名前一致だと**両方が起点に含まれ**、スキームが本来 1 プロジェクトに限定したかったスコープが
過剰に広がる。`applySchemeScope` (`:90-117`) は起点から依存クロージャを展開するため、誤った起点は
無関係なプロジェクトのターゲット群まで索引対象に引き込む。

`.xcscheme` の各 `BuildableReference` は `BlueprintName`（ターゲット名）に加えて
`ReferencedContainer`（例 `container:AppA.xcodeproj` / `container:Sub/AppA.xcodeproj`）を持ち、
**どのプロジェクトのターゲットか**を一意に示す。現状のパーサ
(`XcodeScheme.buildActionTargetNames` `:81-88`, `BuildActionDelegate` `:91-124`) はこの属性を捨てている。

## 調査で確定した事実

- **`XcodeTarget.projectFilePath`**: 依存グラフ作業で追加済み
  (`SwiftBuildSession.swift:36`, `PROJECT_FILE_PATH` 評価 `:259-274`)。各ターゲットの所属 `.xcodeproj` の
  絶対パスを保持する（評価失敗時のみ `nil`）。これが `ReferencedContainer` 照合の突き合わせ先になる。
- **`ReferencedContainer` の形式**: `container:<相対パス>` 形式。相対パスは**スキームファイルを所有する
  コンテナのディレクトリ**を基準とする。プロジェクトスキーム（`MyApp.xcodeproj/xcshareddata/xcschemes/`）では
  `container:MyApp.xcodeproj` がプロジェクトの親ディレクトリ基準、ワークスペース共有スキーム
  （`MyWS.xcworkspace/xcshareddata/xcschemes/`）では `container:AppA.xcodeproj` がワークスペースの親
  ディレクトリ基準で解決される。
- **スキームファイルのコンテナ把握**: `XcodeScheme.schemeFileURL(scheme:containerPath:projectRoot:)`
  (`:50-75`) は `searchContainers` (`:40-48`) が返す候補コンテナを順に走査して一致したファイルを返す。
  どのコンテナで一致したかを保持すれば、`ReferencedContainer` の解決基準ディレクトリ（そのコンテナの親）が
  得られる。
- **パス正規化**: `isPartOfRootProject` (`:328-337`) が `url.resolvingSymlinksInPath().path` による
  symlink 正規化比較を内包する。同じ正規化をコンテナ照合でも使うため共有ヘルパに切り出して再利用する。
- **フィクスチャのスキーム生成**: `SKTestSupport/XcodeTestProject.writeSharedScheme(named:buildTargetNames:)`
  (`XcodeTestProject.swift:1370-1395`) は既に `ReferencedContainer="container:<xcodeproj 名>"` を出力する。
  ただしコンテナは `xcodeprojURL.lastPathComponent` 固定で、target ごとに別コンテナを指定する手段がない。

## 設計

### データモデル

`XcodeScheme.swift`（SwiftBuild 非依存を維持）に、Build アクションの 1 参照を表す型を追加する:

```swift
package struct SchemeBuildTarget: Equatable, Sendable {
  /// `BuildableReference` の `BlueprintName`（ターゲット名）。
  package var blueprintName: String
  /// `ReferencedContainer` を解決した絶対 `.xcodeproj` パス。属性が無い／`container:` 前置でない／
  /// 解析できない場合は `nil`（このとき照合は名前一致のみにフォールバックする）。
  package var container: URL?
}
```

### 純粋関数の分解（いずれも SwiftBuild 非依存・単体テスト可能）

1. **`buildActionTargets(xcschemeContents:) -> [(blueprintName: String, referencedContainer: String?)]`**
   （`buildActionTargetNames` を置換）`BuildActionDelegate` が `<BuildAction>` 内 `BuildableReference` から
   `BlueprintName` と `ReferencedContainer` の**生文字列**を同時に捕捉する。コンテナの絶対 URL 解決は
   ファイルシステム文脈（基準ディレクトリ）を要するため次段 `buildTargets` に委ね、本関数は純粋に XML 解析に専念する。
   重複は (blueprintName, referencedContainer) ペアで de-dup（順序保持）。
2. **`resolveContainer(_ referencedContainer: String?, relativeTo baseDir: URL) -> URL?`**
   `container:` 前置を剥がし、残りを `baseDir` 基準で `URL(fileURLWithPath:relativeTo:)` 解決して
   `.standardizedFileURL` を返す。`nil` / 非 `container:` 前置 / 空は `nil`。
3. **`buildTargets(scheme:containerPath:projectRoot:) -> [SchemeBuildTarget]?`**（`targetNames` を置換）
   `schemeFileURL` を**一致したコンテナ URL も返す**よう変更し、`baseDir = matchedContainer.deletingLastPathComponent()`
   を `resolveContainer` の基準に渡して `SchemeBuildTarget.container` を絶対 URL へ解決する。ファイルが
   無ければ `nil`（従来どおり）。
4. **`resolveScheme(named:schemeTargets:allTargets:) -> SchemeResolution`**
   パラメータ名を `schemeTargetNames: [String]?` → `schemeTargets: [SchemeBuildTarget]?` に変更。
   各スキーム参照について、`allTargets` のうち以下を満たすものを起点 GUID に採用する:
   - `target.name == schemeTarget.blueprintName`、かつ
   - **コンテナフィルタ**: `schemeTarget.container != nil && target.projectFilePath != nil` のときのみ、
     symlink 正規化したパスが一致すること。どちらかが `nil` のときは名前一致のみで採用（後方互換）。
   `SchemeResolution` の 3 ケース（`.seeds` / `.fallbackNotFound` / `.fallbackNoKnownTargets`）は不変。
   スキームファイルが無く同名ターゲットで救済する経路（自動生成スキーム）はコンテナ情報が無いため名前一致のまま。

### 呼び出し側

`applySchemeScope` (`:90-117`) は `XcodeScheme.targetNames(...)` → `XcodeScheme.buildTargets(...)`、
`resolveScheme(..., schemeTargetNames:)` → `resolveScheme(..., schemeTargets:)` に更新するのみ。クロージャ展開・
フォールバック・ログ出力は不変。

### パス比較ヘルパの共有

`isPartOfRootProject` 内のローカル関数 `normalized(_:)` を、ファイルスコープ（または型の `package static`）の
共有ヘルパに切り出し、`resolveScheme` のコンテナ照合と共用する。挙動（`resolvingSymlinksInPath().path`）は不変。

## フィクスチャ

同名ターゲットの曖昧性は単一 `.xcodeproj` では再現できないため、複数プロジェクトの `.xcworkspace` フィクスチャを
新規追加する。フォローアップ #5（`xcworkspacedata` のサブディレクトリ参照解決）を踏まないよう、2 つの
`.xcodeproj` を **projectRoot 直下の兄弟**として配置する。

```
<root>/
  MyWorkspace.xcworkspace/
    contents.xcworkspacedata              # AppA.xcodeproj, AppB.xcodeproj をトップレベル参照
    xcshareddata/xcschemes/App.xcscheme   # BuildableReference: BlueprintName=App, container:AppA.xcodeproj
  AppA.xcodeproj/project.pbxproj          # ターゲット "App"
  AppB.xcodeproj/project.pbxproj          # ターゲット "App"（同名）
```

- 新 `Kind`: `.workspaceWithDuplicateTargetNames`。
- pbxproj / `contents.xcworkspacedata` は既存フィクスチャ同様、Xcode 26.4 でハンドメイド検証
  （`xcodebuild -list` / `-dumpPIF` / `plutil -lint`）した内容を埋め込む。
- ワークスペース共有スキーム `App.xcscheme` は `BlueprintName=App` かつ `container:AppA.xcodeproj` を 1 件だけ
  参照する（`AppB` は参照しない）。`writeSharedScheme` をコンテナを明示指定できる variant に拡張するか、
  ワークスペースレベルスキーム書き出し用の専用ヘルパを追加する。
- 統合テストはターゲット列挙のスコープのみを検証するため**ビルドは不要**。両ターゲットの製品名が同一でも
  `workspaceInfo()` は GUID で区別するため問題ない。

## 完了の定義 (Definition of Done)

- `XcodeScheme.buildActionTargets(xcschemeContents:)` が各 `BuildableReference` の `BlueprintName` と
  `ReferencedContainer` を返す。
- `XcodeScheme.resolveContainer(_:relativeTo:)` が `container:<rel>` を絶対 `.xcodeproj` URL に解決し、
  無効入力で `nil` を返す（単体テスト全環境通過）。
- `XcodeScheme.buildTargets(scheme:containerPath:projectRoot:)` がスキームファイルの所属コンテナを基準に
  `SchemeBuildTarget.container` を絶対 URL へ解決する。
- `XcodeBuildServer.resolveScheme(named:schemeTargets:allTargets:)` が、両側にパス情報があるときコンテナで
  起点を絞り、欠落時は名前一致にフォールバックする（単体テストで同名 2 ターゲットの片方のみ選択・各フォールバックを検証）。
- macOS + Xcode 環境で、重複名ワークスペースフィクスチャを `xcode.scheme = "App"` でロードしたとき、
  `buildTargets()` が AppA のターゲットのみを含み AppB を含まないことを検証する統合テストが通過する。
- 既存の `BuildServerIntegrationTests` が非回帰で通過する（特に既存スキームスコープ・依存グラフ・
  プラットフォーム推定・`.test` タグ）。
- `applySchemeScope` のフォールバック／ログ挙動が不変であること。

## スコープ外 / フォローアップ

- **`BlueprintIdentifier` → GUID 照合**: より厳密だが PIF の GUID 形式検証が必要。引き続きフォローアップ。
- **スキームの Test/Run アクション固有ターゲット**: 本作業は Build アクションのみ対象（別案件）。
- **`contents.xcworkspacedata` のサブディレクトリ参照解決**（フォローアップ #5）: 本フィクスチャは
  プロジェクトを projectRoot 直下に置くため踏まない。サブディレクトリ配置メンバーの厳密解決は引き続き別案件。
- **visionOS** (`xros` / `xrsimulator`): 依然未対応（別案件）。
