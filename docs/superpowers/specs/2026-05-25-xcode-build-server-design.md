# 設計: XcodeBuildServer (SourceKit-LSP × .xcodeproj × swift-build)

- 日付: 2026-05-25
- ステータス: 承認済み(実装プラン待ち)

## 目的

非 Xcode エディタ(VS Code / Neovim / Emacs など)で、`.xcodeproj` / `.xcworkspace`
ベースの iOS/macOS アプリを補完・ジャンプ・診断・インデックス付きで開発できるようにする。
Xcode IDE を開かずに作業することを想定する。

## 要件

- プロジェクトルートに `Package.swift` を必要としない。
- `.xcodeproj` / `.xcworkspace` を情報源とする。
- ビルド情報の取得に swift-build (swiftlang/swift-build, SwiftBuild エンジン) を使う。

## 前提・制約

- `.xcodeproj` を直接扱うのは SwiftBuild の `SWBBuildServiceSession.loadWorkspace(containerPath:)`。
  内部で `xcrun xcodebuild -dumpPIF` を実行して PIF へ変換するため、**マシンに Xcode が
  インストールされている必要がある**(open-source の swift-build 単体では `.pbxproj` を
  パースできない)。非 Xcode エディタで開発する利用者も Xcode 自体は導入している前提。
- 対象プラットフォームは macOS(`xcodebuild` が前提のため)。他ホストでは検出対象外。

## 調査で確定した SwiftBuild 公開 API

| 必要なもの | API |
|---|---|
| ワークスペース読込 | `SWBBuildServiceSession.loadWorkspace(containerPath:)`(`.xcodeproj`/`.xcworkspace`/`.json`/`.pif`/`Package.swift` ディレクトリを受理) |
| ターゲット列挙 | `SWBBuildServiceSession.workspaceInfo() -> SWBWorkspaceInfo` |
| スキーム情報 | `describeSchemes(input:)` / `describeProducts(input:platformName:)` |
| 依存順 | `computeDependencyClosure(targetGUIDs:...)` / `computeDependencyGraph(...)` |
| ファイル単位のコンパイル引数・出力パス | `generateIndexingFileSettings(for:targetID:filePath:outputPathOnly:delegate:) -> SWBIndexingFileSettings` |
| 引数キー | 各 `sourceFileBuildInfos` 要素の `swiftASTCommandArguments` / `clangASTCommandArguments` / `outputFilePath` / `sourceFilePath` / `LanguageDialect` |
| インデックスストアパス | `SWBBuildParameters.arenaInfo.indexDataStoreFolderPath`(`indexEnableDataStore` で有効化) |
| ターゲット準備(ビルド) | `SWBBuildRequest` を用いたビルド操作 |

`generateIndexingFileSettings(filePath: nil)` をターゲット単位で 1 回呼べば、そのターゲットの
全ソースの一覧・引数・出力パスがまとめて取得できる(`buildTargetSources` と `sourceKitOptions`
の両方を 1 回の呼び出しで賄える)。

## 依存関係

swift-build は既に swiftpm 経由で依存グラフに入っている(swiftpm が `SwiftBuild` / `SWBBuildService`
product に条件付き依存。`SWIFTCI_USE_LOCAL_DEPS` でローカルパス `../swift-build` に切替)。
sourcekit-lsp も同じパターンで `swift-build` パッケージ依存を宣言し、新規ビルドサーバーのターゲットで
`.product(name: "SwiftBuild", package: "swift-build")` および `SWBBuildService`(インプロセスで
ビルドサービスを動かすため)に依存する。

## 全体アーキテクチャ

既存の `BuiltInBuildServer` レイヤーに、`SwiftPMBuildServer` と同格の新実装 `XcodeBuildServer` を追加する。

```
DetermineBuildServer (検出: 既存BSP → ★Xcode → SwiftPM → compile_commands)
        └─ BuildServerSpec.Kind.xcode
              └─ XcodeBuildServer : BuiltInBuildServer        ← 新規
                    └─ import SwiftBuild
                          └─ SWBBuildService / SWBBuildServiceSession
                                └─ loadWorkspace(.xcodeproj/.xcworkspace)  ← 内部で xcodebuild -dumpPIF
```

スコープ: 既存ビルドサーバー(SwiftPM / compile_commands / 外部 BSP)は残したまま、
`XcodeBuildServer` を追加し、検出順で `.xcodeproj` を SwiftPM より優先する。

## コンポーネント

### 検出 (`XcodeBuildServer.searchForConfig(in:options:)`)

- ワークスペースルート直下の `*.xcworkspace`(優先)→ `*.xcodeproj` を探索。`Package.swift` は不要。
- 複数候補はフォルダ名一致 → 辞書順で決定し、警告ログを出す。`config.json` の `xcode.container` で明示指定可。
- 検出時に `xcodebuild`(`xcrun --find xcodebuild`)の存在を確認し、無ければ Xcode 検出を見送って
  SwiftPM 等にフォールバックする。
- 戻り値は `BuildServerSpec(kind: .xcode, projectRoot:, configPath: <container URL>)`。

### 検出順の変更 (`DetermineBuildServer.swift`)

挿入順: `injected → 外部BSP(.bsp/) → Xcode → SwiftPM → compilation database`。

- ユーザー方針に従い Xcode を SwiftPM より前に置く。
- 明示的な `.bsp/`(buildServer.json)は意図的なオプトインなので従来どおり最優先のまま維持する。
- `defaultWorkspaceType` オプションが指定された場合はそれを尊重する。

### `XcodeBuildServer : BuiltInBuildServer`

新規ファイル `Sources/BuildServerIntegration/XcodeBuildServer.swift`。

- **初期化**: `SWBBuildService`(インプロセス)→ session 作成 → `setSystemInfo`/`setUserInfo`
  → `loadWorkspace(containerPath:)`。
- **ターゲットモデル**: `workspaceInfo()` で GUID・名前・対応プラットフォームを列挙。
- **ビルドパラメータ**: 構成 = 設定 or `Debug`。`SWBArenaInfo` の `derivedDataPath` を scratch
  (例 `<projectRoot>/.build/sourcekit-lsp-xcode/`)に置き、`indexEnableDataStore = true`、
  `indexDataStoreFolderPath` を設定。
- **実行先推定**: ターゲットのプラットフォームから既定の run destination を決める
  (iOS → 汎用 iOS Simulator、macOS → macOS など)。設定で上書き可能。
- **キャッシュ**: ターゲット単位で `generateIndexingFileSettings(filePath: nil)` の結果
  (source → 引数・出力パス)を保持。file-watch イベントで無効化する。

### プロトコル実装マッピング

| `BuiltInBuildServer` メンバ | 実装 |
|---|---|
| `buildTargets` | `workspaceInfo()` のターゲット → `BuildTarget` に変換 |
| `buildTargetSources` | キャッシュ済 indexing settings の `sourceFilePath` 群 |
| `sourceKitOptions` | ファイルの所属ターゲット → `swiftASTCommandArguments`/`clangASTCommandArguments` を `FileBuildSettings` に |
| `indexStorePath` | arena の `indexDataStoreFolderPath` |
| `indexDatabasePath` | scratch 配下の IndexDatabase ディレクトリ |
| `supportsPreparationAndOutputPaths` | `true`(`outputFilePath` を提供) |
| `prepare` | `SWBBuildRequest` でターゲットビルド(index store 生成) |
| `fileWatchers` | `**/*.xcodeproj/project.pbxproj` / `**/*.xcworkspace/contents.xcworkspacedata` / `**/*.xcscheme` / `**/*.xcconfig` |
| `didChangeWatchedFiles` | ワークスペース再ロード + キャッシュ無効化 |

## 設定スキーマ

`.sourcekit-lsp/config.json`(SKOptions / `config.schema.json` に追加):

```jsonc
{
  "xcode": {
    "container": "MyApp.xcworkspace",                       // 任意: 明示指定
    "scheme": "MyApp",                                       // 任意
    "configuration": "Debug",                                // 既定 Debug
    "destination": "platform=iOS Simulator,name=iPhone 15"   // 任意: 既定は推定
  }
}
```

## データフロー

- **補完 / 診断**: editor → SourceKitLSPServer → `BuildServerManager.buildSettings`
  → `XcodeBuildServer.sourceKitOptions` →(キャッシュ or)`generateIndexingFileSettings`
  → `FileBuildSettings`。
- **インデックス**: SemanticIndex → `BuildServerManager.prepare` → `XcodeBuildServer.prepare`
  → `SWBBuildService` build(index store 有効)→ IndexStoreDB が読込。
- **初回ロード**: detect → session init → `loadWorkspace`(`xcodebuild -dumpPIF`)→ `workspaceInfo`。

## エラー処理・フォールバック

- Xcode / `xcodebuild` 不在: 検出段階で Xcode を除外し、SwiftPM 等にフォールバック。
- PIF 変換失敗(壊れた `.pbxproj` 等): 診断ログを出し、当該ファイルは fallback settings
  (既存の main-file 推定機構を再利用)。
- 引数取得失敗: `FileBuildSettings.isFallback` を立てて既存のフォールバック経路に委ねる。
- セッションクラッシュ: `SWBBuildService` 再起動 + 再ロード(SwiftPM の失敗時リトライ方針に倣う)。

## テスト

- `SKTestSupport` に最小 `.xcodeproj` フィクスチャ生成ヘルパーを追加。
- **macOS + Xcode 必須**のため、CI ではホスト条件ゲートを設け、対象外環境ではスキップする。
- 単体: 検出ロジック(`.xcworkspace` 優先・複数候補・`config` 上書き・`xcodebuild` 不在時のフォールバック)。
- 統合: 最小 iOS / macOS プロジェクトをロード → `sourceKitOptions` が妥当な `-sdk` / `-target` を返す、
  `buildTargetSources` がソースを列挙、`prepare` で index store が生成される。
- 既存 SwiftPM 検出の非回帰(`.xcodeproj` が無いケースで従来どおり SwiftPM が選ばれる)。

## 実装の段階(プラン化の起点)

1. 依存追加 + 検出 + `BuildServerSpec.Kind.xcode` 登録(必ず SwiftPM へフォールバックできる状態)
2. session 起動 + `loadWorkspace` + `workspaceInfo` でターゲット列挙
3. `sourceKitOptions` + `buildTargetSources`(`generateIndexingFileSettings`)
4. index store + `prepare`
5. 設定スキーマ + 上書き + 実行先推定
6. file watch + 再ロード
7. テスト / フィクスチャ + CI ゲート

## 未確定事項(実装時に確定)

- `SWBWorkspaceInfo` が対応プラットフォーム情報を直接持つか、`describeSchemes`/build settings 経由で
  得る必要があるか(実行先推定の入力)。
- scratch / DerivedData の最終的な配置(`<root>/.build/sourcekit-lsp-xcode/` を既定とするか、
  SourceKit-LSP の既存 index scratch 規約に合わせるか)。
- `SWBIndexingDelegate` の最小実装(`EmptyBuildOperationDelegate` 相当)で十分か。
