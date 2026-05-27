# 設計: XcodeBuildServer 依存グラフ公開（`.dependency` タグ + `dependencies` フィールド）

作成日: 2026-05-27
関連: [XcodeBuildServer 設計](2026-05-25-xcode-build-server-design.md), [プラットフォーム推定](2026-05-25-xcode-platform-inference-design.md), [スキーム対応](2026-05-25-xcode-scheme-support-design.md), [テストターゲットのタグ付与](2026-05-27-xcode-test-target-tagging-design.md)

## 目的

`XcodeBuildServer` がロードした `.xcodeproj` / `.xcworkspace` のターゲット間依存関係を BSP に公開する。
2 つの相補的なギャップを同時に解消する:

- **ギャップ #4**: 依存（SwiftPM パッケージ由来）ターゲットへの `BuildTarget.tags` の `.dependency` 付与。
- **ギャップ #5**: `BuildTarget.dependencies`（直接の上流依存）の充填。

これにより、(a) 依存パッケージのソース/テストがユーザーのプロジェクトの一部として誤って扱われなくなり、
(b) SourceKit-LSP がターゲットの index 準備順序を依存グラフに基づいて最適化できるようになる。

## 背景・現状の問題

`XcodeBuildServer.buildTargets()` (`Sources/BuildServerIntegration/XcodeBuildServer.swift:140-156`) は
全ターゲットを `dependencies: []`・`tags` は `.test` のみ（#4 で扱う `.dependency` は未設定）で返している。
対照的に `SwiftPMBuildServer.buildTargets()` (`:599-630`) は:

- `target.isPartOfRootPackage` が false のとき `.dependency` を付与する (`:605-607`)。
- `self.targetDependencies[targetId]` から `dependencies` を埋める (`:615`)。`targetDependencies` は
  `buildDescription.traverseModules` でモジュールグラフを辿って構築される (`:543-556`)。

この差により Xcode プロジェクトでは以下の 2 つの不具合がある。

### #4: `isPartOfRootProject` が常に true

`BuildServerManager.sourceFilesAndDirectories()` (`:1655`) は
`let isPartOfRootProject = !(target?.tags.contains(.dependency) ?? false)` で各ソースファイルの
`SourceFileInfo.isPartOfRootProject` を決める。Xcode ターゲットは `.dependency` を持たないため常に true となり:

- `projectTestFiles()` (`:1689-1696`) が `guard info.isPartOfRootProject, info.mayContainTests` で絞るため、
  **依存パッケージのテストもプロジェクトのテストとして探索対象に含まれてしまう**（テストエクスプローラ等）。
- `projectSourceFiles()` (`:1700-1716`) も `guard info.isPartOfRootProject` で絞るため、
  依存パッケージのソースがプロジェクトのソースとして混入する。

### #5: `dependencies` が空 → depth が全ターゲット 0

`BuildServerManager.targetDepthsAndDependents(for:)` (`:1442-1467`) は `buildTarget.dependencies` を辿って
各ターゲットの depth と逆依存（`dependents`）を計算する。`dependencies: []` だと全ターゲットが root（depth 0）扱いになり、
`topologicalSort(of:)` (`:1471-`) による「low-level ターゲットを先に prepare/index する」最適化が効かない。
実ビルドの依存順は SwiftBuild 内部が担うため**正しさの問題ではなく最適化**だが、index データの早期可用性に寄与する。

## 調査で確定した事実

- **`PROJECT_FILE_PATH` のターゲットレベル評価**: 既存の `supportedPlatforms(forTargetGUID:)`
  (`SwiftBuildSession.swift:174-185`) / `isTestTarget(forTargetGUID:)` (`:192-204`) と同じく
  `session.evaluateMacroAsString("PROJECT_FILE_PATH", level: .target(guid), ...)` で各ターゲットの
  所属 `.xcodeproj` の絶対パスを取得できる（run destination 非依存、configuration のみ設定すれば良い）。
- **`computeDependencyGraph`**: `SWBBuildServiceSession.computeDependencyGraph(targetGUIDs:buildParameters:includeImplicitDependencies:)`
  (swift-build `Sources/SwiftBuild/SWBBuildServiceSession.swift:387,396`) が**隣接リスト** `[SWBTargetGUID: [SWBTargetGUID]]`
  を返す。これは各ノードの**直接**後続（直接依存）であり、`includeImplicitDependencies: true` で暗黙依存も含む。
  BSP の `BuildTarget.dependencies`（"direct upstream build target dependencies"）にそのまま対応する。
  既存の `dependencyClosure(forTargetGUIDs:)` (`SwiftBuildSession.swift:156-167`) が使う `computeDependencyClosure`
  は**推移的閉包**を返す別 API である点に注意（#5 では graph 版を使う）。
- **`WorkspaceInfoResponse.WorkspaceInfo.TargetInfo`** は `guid` / `targetName` / `projectName` を公開する
  (swift-build `Sources/SWBProtocol/Message.swift:1097-1099`)。`projectName` は所属判定の補助になり得るが、
  名前衝突を避けるため本作業では絶対パス (`PROJECT_FILE_PATH`) を一次信号とする。
- **`.dependency` の意味論**: BSP の定義は「the project the user opened のターゲットではなく、例えば SwiftPM 依存をビルドする
  ターゲット」(`BuildServerProtocol/.../BuildTarget.swift`)。`SwiftPMBuildServer` でも `!isPartOfRootPackage`
  ＝パッケージ依存のターゲットに限って付与している。よって「所属プロジェクトが、ユーザーが開いたコンテナ
  （または workspace のメンバープロジェクト）でない」ターゲットを `.dependency` とするのが忠実。
- **隔離契約**: `XcodeTarget` は SwiftBuild 型を漏らさない値型として設計されている
  (`SwiftBuildSession.swift:26-42`)。分類ロジックは `isTestProductType(_:)` (`:404`) / `resolveScheme(...)`
  (`XcodeBuildServer.swift:298`) と同様、`import SwiftBuild` 非依存の純粋関数に切り出して単体テスト可能にする。

## アプローチ

### #4: `.dependency` タグ（所属プロジェクト判定）

1. `SwiftBuildSession` に per-target の `PROJECT_FILE_PATH` 評価を追加し、`XcodeTarget` に生の
   `projectFilePath: URL?` を持たせる（`platforms` / `isTestTarget` と同じく `targets()` 内で充填）。
2. `XcodeBuildServer` がルートプロジェクト集合を構築する:
   - コンテナが `.xcodeproj` → `{containerPath}`。
   - コンテナが `.xcworkspace` → メンバー `.xcodeproj`（`XcodeScheme.searchContainers(containerPath:projectRoot:)`
     相当のロジック。初回はトップレベル走査で prior scheme 挙動を踏襲）。
3. 純粋関数 `isPartOfRootProject(projectFilePath:rootProjectPaths:) -> Bool`（package static, SwiftBuild 非依存）で
   分類。所属プロジェクトがルート集合外（典型的には `…/SourcePackages/…` 配下の SPM パッケージ）なら
   `buildTargets()` で `.dependency` を付与する。

採用理由: `PROJECT_FILE_PATH` 評価は既存の 2 つのマクロ評価と差分が局所的。絶対パス比較は `projectName` の
名前衝突に強い。分類を純粋関数に切り出せば SwiftBuild 非依存で網羅的に単体テストできる。

検討した代替案:
- **`projectName` ベース分類**: 追加のマクロ評価が不要（`workspaceInfo` で取得済み）だが、ルートプロジェクト名の
  確定（コンテナ basename ≠ プロジェクト名のことがある）と名前衝突で脆い。却下。
- **`projectIsPackage` フラグ**: 最も正確だがビルドメッセージ（`targetStarted`）でしか得られず、ターゲット列挙時には
  使えない。却下。

### #5: `dependencies` フィールド（直接依存エッジ）

1. `SwiftBuildSession.dependencyGraph(forTargetGUIDs:) -> [String: [String]]` を追加し、
   `session.computeDependencyGraph(targetGUIDs:buildParameters:includeImplicitDependencies: true)` をラップする
   （`SWBTargetGUID` ↔ `String` 変換は内部に閉じ、隔離契約を維持）。スコープ済みターゲットの全 GUID を渡して**1回**で取得。
2. `buildTargets()` で各ターゲットの `dependencies` を「直接依存 GUID **∩ スコープ内ターゲット集合**」で埋め、
   `BuildTargetIdentifier.createXcode(targetGUID:)` にマップする（応答に含まれない GUID を参照しないよう交差を取る）。
   スキームでスコープ済みの場合も `allTargets()` の集合と整合する。

採用理由: 隣接リスト API は直接依存を 1 往復で返し、BSP の `dependencies` 定義と一致する。
per-target の推移閉包呼び（N 往復・推移エッジ）より正確かつ効率的。

## 変更点

- `Sources/BuildServerIntegration/SwiftBuildSession.swift`
  - `XcodeTarget` に `projectFilePath: URL?` を追加。
  - `targets()` で per-target の `PROJECT_FILE_PATH` を評価して `projectFilePath` を充填する
    `projectFilePath(forTargetGUID:)` を追加。
  - `dependencyGraph(forTargetGUIDs:) -> [String: [String]]` を追加（`computeDependencyGraph` ラップ）。
- `Sources/BuildServerIntegration/XcodeBuildServer.swift`
  - `buildTargets()` で (a) ルートプロジェクト集合を構築し `.dependency` を付与、
    (b) `dependencyGraph` を 1 回取得して `dependencies` を埋める。
  - 純粋関数 `isPartOfRootProject(projectFilePath:rootProjectPaths:)`（package static）を追加。
  - `.xcworkspace` のメンバープロジェクト列挙ロジック（`XcodeScheme.searchContainers` の共有/再利用）。
- `Sources/SKTestSupport/XcodeTestProject.swift`（または相当のフィクスチャ）
  - SPM パッケージ依存を持つ新フィクスチャ種別を追加（#4 の end-to-end 検証用）。
- `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift`
  - 単体・統合テストを追加。

## テスト

### 単体テスト（SwiftBuild 非依存、全環境）

- `isPartOfRootProject(projectFilePath:rootProjectPaths:)`:
  - ルート集合内のパス → true。
  - `…/SourcePackages/checkouts/…` 配下のパッケージパス → false（`.dependency`）。
  - `.xcworkspace` メンバープロジェクトのパス → true。
  - `projectFilePath == nil`（評価失敗）→ 保守的に true（root 扱い、誤って探索から除外しない）。
- `dependencies` 交差ロジック（依存グラフ応答 × スコープ集合）が、スコープ外 GUID を落とすこと。

### 統合テスト（macOS + Xcode、既存のホスト条件ゲートを踏襲）

- **#5**: 既存の複数ターゲット系フィクスチャ（app + unit-test など）をロードし、
  `buildTargets()` のレスポンスで app→framework / test→app などの `dependencies` エッジが
  期待どおり張られることを検証。実 SwiftBuild の `computeDependencyGraph` の end-to-end 証明。
- **#4**: **SPM パッケージ依存を持つ新フィクスチャ**をロードし、パッケージ由来ターゲットにのみ `.dependency`
  が付き、ルートプロジェクトのターゲットには付かないことを検証。本ギャップの直接的な回帰テスト。
  - フィクスチャ構築（`Package.swift` + プロジェクトのパッケージ参照 + `xcodebuild -resolvePackageDependencies`、
    Xcode 26.4 で `xcodebuild -list` / `-dumpPIF` / `plutil -lint` により検証）が**本作業の主な工数/リスク**。

### 非回帰

- 既存の `BuildServerIntegrationTests` が非回帰で通過する（特に既存の `.test` タグ・スキーム・プラットフォーム推定）。

## スコープ外 / フォローアップ

- **project reference 経由の別 `.xcodeproj`**: ルート `.xcodeproj` が project reference で参照する別プロジェクトの
  フレームワークターゲットは、本作業では SPM パッケージに絞るため `.dependency` 判定の対象としない（root 集合外なら
  結果的に `.dependency` になり得るが、専用の検証はしない）。
- **`contents.xcworkspacedata` のサブディレクトリ参照解決**: 初回はトップレベル走査（prior scheme 挙動踏襲）。
  サブディレクトリに配置されたメンバープロジェクトの厳密解決はフォローアップ。
- **`.dependency` の推移的伝播**: `.dependency` はターゲット単位の所属判定であり、依存の依存への伝播は行わない
  （所属プロジェクトで一意に決まる）。

## 完了の定義 (Definition of Done)

- `SwiftBuildSession` が各ターゲットの `projectFilePath` を `PROJECT_FILE_PATH` 評価で返す。
- `SwiftBuildSession.dependencyGraph(forTargetGUIDs:)` が直接依存の隣接リストを返す。
- `XcodeBuildServer.buildTargets()` が (a) パッケージ由来ターゲットに `.dependency` を付与し、
  (b) 各ターゲットの `dependencies` を直接依存（スコープ内交差）で埋める。
- `isPartOfRootProject(...)` の単体テストが全環境で通過する。
- macOS + Xcode 環境で、#4（パッケージ依存フィクスチャの `.dependency` 付与）と
  #5（`dependencies` エッジ）を検証する統合テストが通過する。
- 既存の `BuildServerIntegrationTests` が非回帰で通過する。
