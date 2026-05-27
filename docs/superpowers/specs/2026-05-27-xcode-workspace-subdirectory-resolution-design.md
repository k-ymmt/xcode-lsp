# 設計: XcodeBuildServer workspace サブディレクトリ解決

作成日: 2026-05-27
関連: [XcodeBuildServer 設計](2026-05-25-xcode-build-server-design.md) /
[scheme 対応設計](2026-05-25-xcode-scheme-support-design.md) /
[依存グラフ設計](2026-05-27-xcode-dependency-graph-design.md) /
[scheme コンテナ曖昧性解消設計](2026-05-27-xcode-scheme-container-disambiguation-design.md)

## 目的

`.xcworkspace` のメンバー `.xcodeproj` 列挙を、`projectRoot` 直下のディレクトリグロブから
**`contents.xcworkspacedata` の解析**に置き換える。サブディレクトリやフォルダグループで整理された
(= 実際のワークスペースで一般的な)メンバープロジェクトを正しく認識できるようにする。

これは精度向上であると同時に、現状の潜在バグの修正でもある(後述)。

## 背景・現状の問題

`.xcworkspace` のメンバー `.xcodeproj` を必要とする箇所が 2 つあり、いずれも
`contents.xcworkspacedata` を**一切解析せず**、`projectRoot` 直下を `*.xcodeproj` で
グロブしているだけ:

1. **`XcodeBuildServer.rootProjectPaths()`**
   (`Sources/BuildServerIntegration/XcodeBuildServer.swift:142-151`)
   — `.dependency` タグ付けの基準集合。`isPartOfRootProject(projectFilePath:rootProjectPaths:)`
   がこの集合に属さないターゲットを「依存(SwiftPM パッケージ等)」とみなす。
2. **`XcodeScheme.searchContainers(containerPath:projectRoot:)`**
   (`Sources/BuildServerIntegration/XcodeScheme.swift:75-83`)
   — scheme ファイル(`.xcscheme`)探索対象コンテナの列挙。

### 潜在バグ

サブディレクトリ構成のワークスペース(例: `group:AppA/AppA.xcodeproj`)では、`rootProjectPaths()`
のトップレベルグロブが**空集合**を返す。`isPartOfRootProject` は集合に含まれない非 nil パスを
`false`(= 依存)と判定するため、**全アプリターゲットが誤って `.dependency` タグになる**。

既存フィクスチャ `XcodeTestProject(kind: .workspaceWithDuplicateTargetNames)` は
`group:AppA/AppA.xcodeproj` / `group:AppB/AppB.xcodeproj`(サブディレクトリ参照)を使うが、
その統合テストは scheme スコープの件数しか検証せず `.dependency` タグを見ないため見逃されている。
scheme 曖昧性解消テストが通るのは、scheme ファイルが workspace 直下の `xcshareddata` にあり、
`ReferencedContainer`(`container:AppA/AppA.xcodeproj`)がサブパスを与えるためで、
`searchContainers()` / `rootProjectPaths()` のグロブには依存していないから。

## 調査で確定した事実

- `projectRoot` = `.xcworkspace`/`.xcodeproj` を**含むディレクトリ**、`containerPath` = コンテナ本体
  (`XcodeBuildServer.searchForConfig`、`BuildServerSpec(projectRoot: path, configPath: container)`)。
- `.xcworkspace/contents.xcworkspacedata` は XML。`<Workspace>` 配下に `<FileRef>` と `<Group>` が
  ネストし、各要素の `location="<kind>:<path>"` でメンバーを宣言する。
  - `group:` … 直近の親 `<Group>` の解決パス基準(トップレベルでは workspace ディレクトリ基準)。
  - `container:` … ネスト位置に関わらず常に workspace ディレクトリ基準。
  - `absolute:` … 絶対パス。
  - `self:` … workspace 自身のディレクトリ。
- `group:` / `container:` の解決基準ディレクトリは **`.xcworkspace` を含むディレクトリ**
  (= `containerPath.deletingLastPathComponent()`、通常 `projectRoot` と一致)。
  既存の `XcodeScheme.resolveContainer(_:relativeTo:)` も同じく `container.deletingLastPathComponent()`
  を baseDir に使っており整合する。
- SwiftBuild はメンバープロジェクトの列挙 API を公開しない(`workspaceInfo()` はターゲットのみ)。
  ワークスペースのメンバーシップ解釈はクライアント(本実装)の責務。

## アプローチ

採用: **`XcodeScheme` と並ぶ純粋ユーティリティ `XcodeWorkspace` を新設し、`contents.xcworkspacedata`
を `XMLParser` で完全解析(再帰 + 全 location 形式)。`rootProjectPaths()` と
`XcodeScheme.searchContainers()` の重複したトップレベルグロブを、この単一の権威ある実装に置き換える。**

両者は「workspace のメンバー `.xcodeproj` 集合」という同じ情報を必要とするため一本化する。
`XcodeWorkspace` は `import SwiftBuild` を持たない(隔離契約維持)。

検討した代替案と却下理由:

- **各所にインラインでパーサを書く**: 重複・テスト困難。→ 却下。
- **`target.projectFilePath` が DerivedData の `SourcePackages` 配下かで依存判定**: メンバーシップ
  という既存設計の判定基準を変える。今回のスコープ(xcworkspacedata 解析)から外れる。→ 却下。

## 解決の意味論(確定事項)

- **対応範囲: 完全解決(再帰 + 全 location 形式)。** `<Workspace>` 配下を再帰的に辿り、
  各 `location` を kind 別に解決:
  - `group:` → 現在(直近の親 `<Group>`)のベース URL 基準。
  - `container:` → workspace ディレクトリ基準(ネスト位置を無視)。
  - `absolute:` → 絶対パス。
  - `self:` → ベース URL そのもの(`.xcodeproj` ではないため収集対象外、`<Group>` のベースとして使用)。
  - 未知の kind → 無視。
  - `<Group location=...>` 開始で解決ディレクトリを push、終了で pop(接頭辞累積)。
  - `<FileRef location=...>` を解決し、`.xcodeproj` 拡張子のものだけ収集。重複は dedupe。
  - 正規化は `.standardizedFileURL`(`.`/`..` を解決、symlink は解決しない)。symlink 正規化は
    比較時の `XcodeBuildServer.normalizedPath` に委ねる(`XcodeScheme.resolveContainer` と同方針)。
- **projectRoot 外のメンバー**: `container:../Shared/Lib.xcodeproj` や `absolute:` で projectRoot
  外を参照するメンバーも正しく root 扱い(従来のグロブでは表現不可だった)。
- **フォールバック**: `contents.xcworkspacedata` が不在/解析不能なら `nil` を返し、呼び出し側が
  従来のトップレベルグロブにフォールバック。→ **成功時は厳密に改善、失敗時は非回帰**。
- **非対応**: workspace が別 `.xcworkspace` を参照するケース(稀)。`.xcodeproj` 以外は無視。

## 全体構成

```
XcodeWorkspace.memberProjects(workspaceURL:) -> [URL]?   ← 単一の権威ある列挙点
  ├─ contents.xcworkspacedata を読む
  │    └─ projectReferences(xcworkspacedataContents:baseDir:)（純パーサ）で全解決
  └─ ファイル不在/解析不能 → nil（呼び出し側がフォールバック）

XcodeBuildServer.rootProjectPaths()
  └─ workspace: memberProjects() ?? トップレベルグロブ（フォールバック）

XcodeScheme.searchContainers(containerPath:projectRoot:)
  └─ workspace: [containerPath] + (memberProjects() ?? トップレベルグロブ)
```

## 変更点

### 1. 新規 `Sources/BuildServerIntegration/XcodeWorkspace.swift`

```swift
package enum XcodeWorkspace {
  /// workspace の contents.xcworkspacedata が宣言するメンバー .xcodeproj を、完全解決して返す
  /// (group:/container:/self:/absolute: + ネスト <Group> 接頭辞)。ファイル不在/解析不能なら nil
  /// (呼び出し側がトップレベル走査にフォールバック)。
  package static func memberProjects(workspaceURL: URL) -> [URL]?

  /// 純パーサ: xcworkspacedata XML から .xcodeproj で終わる FileRef を baseDir 基準で全解決。
  package static func projectReferences(xcworkspacedataContents: Data, baseDir: URL) -> [URL]
}
```

- `memberProjects` は `workspaceURL.appendingPathComponent("contents.xcworkspacedata")` を読み、
  `baseDir = workspaceURL.deletingLastPathComponent()` で `projectReferences` を呼ぶ。読めなければ `nil`。
- パースは `Foundation.XMLParser`(追加依存なし、`#if canImport(FoundationXML)` を踏襲)。
  デリゲートはベース URL スタックを保持(初期値 = `baseDir`)。`<Group>` で push、終了で pop。
- location 解決ヘルパ `resolveLocation(_ raw:String, currentBase:URL, workspaceDir:URL) -> URL?`:
  最初の `:` で kind/path を分割し、上記意味論で解決して `.standardizedFileURL`。
- `import SwiftBuild` を持たない。

### 2. `XcodeBuildServer.rootProjectPaths()` の置き換え

```swift
private func rootProjectPaths() -> Set<URL> {
  if containerPath.pathExtension == "xcworkspace" {
    if let members = XcodeWorkspace.memberProjects(workspaceURL: containerPath) {
      return Set(members)
    }
    // フォールバック: 従来のトップレベル走査（解析失敗時のみ）
    let entries =
      orLog("Enumerating member projects under \(projectRoot.path)") {
        try FileManager.default.contentsOfDirectory(at: projectRoot, includingPropertiesForKeys: nil)
      } ?? []
    return Set(entries.filter { $0.pathExtension == "xcodeproj" })
  }
  return [containerPath]
}
```

### 3. `XcodeScheme.searchContainers()` の置き換え

```swift
private static func searchContainers(containerPath: URL, projectRoot: URL) -> [URL] {
  var containers = [containerPath]
  if containerPath.pathExtension == "xcworkspace" {
    let members =
      XcodeWorkspace.memberProjects(workspaceURL: containerPath)
      ?? ((try? FileManager.default.contentsOfDirectory(at: projectRoot, includingPropertiesForKeys: nil))?
        .filter { $0.pathExtension == "xcodeproj" } ?? [])
    containers.append(contentsOf: members.sorted { $0.path < $1.path })
  }
  return containers
}
```

doc コメントを「メンバーは `contents.xcworkspacedata` から解決(失敗時はトップレベル走査)」に更新。

### 4. テストフィクスチャ追加

`Sources/SKTestSupport/XcodeTestProject.swift` に `kind: .workspaceWithNestedProject` を追加:
- workspace 直下に App プロジェクト、サブディレクトリ(例 `Modules/MyLib/MyLib.xcodeproj`)に
  framework プロジェクトを配置。
- `contents.xcworkspacedata` で App は直下参照、MyLib は **ネスト `<Group location="group:Modules">`
  + `group:MyLib/MyLib.xcodeproj`** で参照(接頭辞累積の実地検証)。
- pbxproj は ID 衝突回避のため prefix を分ける(既存 `workspaceWithDuplicateTargetNames` に倣う)。

## テスト

### 単体テスト(Xcode 不要・全環境) — `Tests/BuildServerIntegrationTests/XcodeWorkspaceTests.swift`(新規)

`projectReferences(xcworkspacedataContents:baseDir:)`:
- **フラット FileRef**: `group:AppA/AppA.xcodeproj` 等 → baseDir 基準のサブパスで解決。
- **ネスト `<Group>`**: `<Group location="group:Modules"><FileRef location="group:MyLib/MyLib.xcodeproj"/></Group>`
  → `<baseDir>/Modules/MyLib/MyLib.xcodeproj`(接頭辞累積の証明)。
- **`container:`**: ネスト `<Group>` 内の `container:Top.xcodeproj` が group 接頭辞を無視し
  workspace ディレクトリ基準で解決。
- **`absolute:`**: 絶対パスをそのまま。
- **`self:` / 非 `.xcodeproj` FileRef**(`group:Package.swift` 等)→ 収集対象外。
- **dedupe**: 同一参照の重複除去。
- **不正データ**: 空/壊れた XML → `[]`。

`memberProjects(workspaceURL:)`(temp ディレクトリ): ファイル存在時は解決結果、不在時は `nil`。

### 統合テスト(macOS + Xcode、既存ホスト条件ゲート `skipUnlessXcodeAvailable()` 踏襲)

`XcodeTestProject(kind: .workspaceWithNestedProject)` を用いて:
1. **`.dependency` 誤タグ修正の回帰テスト**: サブディレクトリの MyLib ターゲットに `.dependency`
   タグが**付かない**(root project と認識される)。潜在バグ修正の直接証明。
2. **scheme 探索**: サブディレクトリプロジェクト内の共有 scheme が `searchContainers` 経由で
   発見されることを確認。

### 非回帰

- 既存 `BuildServerIntegrationTests`(148件)が非回帰で通過。特に `workspaceWithDuplicateTargetNames`
  の scheme 曖昧性解消が、グロブではなくパース済みメンバーシップ経由でも通ること。
- scheme 未指定・`.xcodeproj` 直接オープン時の挙動が不変。

## 完了の定義 (Definition of Done)

- `.xcworkspace` のメンバー `.xcodeproj` 列挙が `contents.xcworkspacedata` の解析に基づく
  (サブディレクトリ / ネスト `<Group>` / `container:` / `absolute:` を解決)。
- サブディレクトリ構成のワークスペースで、メンバープロジェクトのターゲットに `.dependency` タグが
  誤付与されない(潜在バグ修正)。
- サブディレクトリプロジェクト内の `.xcscheme` が scheme 探索対象に含まれる。
- `contents.xcworkspacedata` が不在/解析不能なら従来のトップレベルグロブにフォールバックし非回帰。
- `XcodeWorkspace` は `import SwiftBuild` を持たない(隔離契約維持)。
- `projectReferences` の location 解決・ネスト・dedupe・不正データの単体テストが全環境で通過。
- macOS + Xcode で `.dependency` タグと scheme 探索の統合テストが通過。
- 既存 `BuildServerIntegrationTests` が非回帰で通過。

## スコープ外 / フォローアップ

- `BlueprintIdentifier` → GUID 照合(scheme ターゲット照合の厳密化、PIF の GUID 形式検証が必要)。
- project reference(別 `.xcodeproj` を project reference する構成)経由のターゲット解決。
- workspace が別 `.xcworkspace` を参照する構成。
- visionOS(`xros`/`xrsimulator`)プラットフォーム対応。
