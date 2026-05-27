# 設計: XcodeBuildServer scheme の Test/Launch アクション対応

作成日: 2026-05-27
関連: [scheme 対応設計](2026-05-25-xcode-scheme-support-design.md) / [scheme 同名ターゲット曖昧性解消設計](2026-05-27-xcode-scheme-container-disambiguation-design.md)

## 目的

`xcode.scheme` のスコープ起点(seed)を、現状の **Build アクション**だけでなく **Test アクション
(Testables)** と **Launch アクション(BuildableProductRunnable)** の `BuildableReference` にも
広げる。これにより、テストターゲットが Build アクションに載っておらず Test アクションの Testables
にのみ書かれているスキームでも、そのテストターゲット(と依存クロージャ)が補完・インデックス・
prepare の対象に含まれるようになる。非 Xcode エディタでのテスト開発体験を改善するのが狙い。

## 背景・現状の問題

scheme スコープは「seed ターゲット集合 → SwiftBuild の依存クロージャで拡張 → `allTargets()` を
フィルタ」という流れ(`Sources/BuildServerIntegration/XcodeBuildServer.swift:88-118`
`applySchemeScope`)。seed の収集は `XcodeScheme.buildTargets(scheme:containerPath:projectRoot:)`
(`Sources/BuildServerIntegration/XcodeScheme.swift:57-70`)が担い、その内部の
`buildActionReferences(xcschemeContents:)`(同 118-125)+ `BuildActionDelegate`(同 146-184)が
**`BuildAction` 要素内の `BuildableReference` だけ**を拾う。`TestAction` / `LaunchAction` 内の
`BuildableReference` は無視される。

典型的な Xcode 自動生成スキームでは、テストバンドルが `buildForTesting="YES"` で BuildAction にも
列挙されるため、その場合は既にスコープに入る。本作業が対象とするのは:

- テストターゲットが **Test アクションの `Testables` にのみ**書かれ、BuildAction には無いスキーム。
- Launch アクションの runnable 固有のターゲット(通常はアプリで BuildAction にもあるが、
  BuildAction が最小化されている curated scheme では Launch にしかないことがある)。

## 調査で確定した事実

`.xcscheme` の関連要素(Xcode の scheme XML、`version="1.7"` 系):

```xml
<Scheme ...>
  <BuildAction ...>
    <BuildActionEntries>
      <BuildActionEntry buildForTesting="YES" buildForRunning="YES" ...>
        <BuildableReference BlueprintName="App" ReferencedContainer="container:App.xcodeproj" .../>
      </BuildActionEntry>
    </BuildActionEntries>
  </BuildAction>
  <TestAction ...>
    <Testables>
      <TestableReference skipped="NO">
        <BuildableReference BlueprintName="AppTests" ReferencedContainer="container:App.xcodeproj" .../>
      </TestableReference>
    </Testables>
    <MacroExpansion>
      <BuildableReference BlueprintName="App" .../>   <!-- env 用、通常アプリ -->
    </MacroExpansion>
  </TestAction>
  <LaunchAction ...>
    <BuildableProductRunnable runnableDebuggingMode="0">
      <BuildableReference BlueprintName="App" ReferencedContainer="container:App.xcodeproj" .../>
    </BuildableProductRunnable>
  </LaunchAction>
</Scheme>
```

- `TestAction` / `LaunchAction` 内の `BuildableReference` も `BuildAction` と同じく `BlueprintName`
  (= ターゲット名 = `XcodeTarget.name`)と `ReferencedContainer`(`container:` 相対パス)を持つ。
  → 既存のコンテナ解決(`resolveContainer`)・照合(`resolveScheme` の blueprintName + container)が
  そのまま適用できる。
- `TestableReference` は `skipped="YES|NO"` 属性を持つ。これは**テスト実行から除外**するフラグであり、
  ビルド/インデックスの対象可否ではない。

## アプローチ

採用: **既存の XMLParser デリゲートを拡張し、`BuildAction` / `TestAction` / `LaunchAction` の
いずれかを祖先に持つ `BuildableReference` をすべて seed 参照として収集する。**

検討した代替案と却下理由:

- **アクションごとにバケット分け(`{ build, test, launch }`)して呼び出し側に選ばせる**:
  将来「config でアクション選択」を入れるなら柔軟だが、今回は常に Build+Test+Launch 固定で seed の
  平坦リストで十分。過剰な一般化(YAGNI)。→ 不採用。
- **SwiftBuild の `describeSchemes` / `describeArchivableProducts`**: scheme 対応設計時に却下済み
  (入力に target 識別子が必要で循環、ディスク上の scheme を列挙しない)。→ 不可。

### 収集ルール(確定事項)

XMLParser のデリゲートで要素名のスタックを保持し、**祖先に `BuildAction` / `TestAction` /
`LaunchAction` のいずれかがある状態で出現した `BuildableReference`** を収集する。

- `TestAction > Testables > TestableReference > BuildableReference`(テストバンドル)を収集。
- `LaunchAction > BuildableProductRunnable > BuildableReference`(runnable)を収集。
- `TestAction` / `LaunchAction` の `MacroExpansion > BuildableReference`(env 用ターゲット、通常は
  アプリ)も結果的に含まれるが、scheme の意図の一部であり、(blueprintName, container) の重複排除で
  既存参照と統合されるため無害。要素の直上の親まで厳密に判定する複雑さを避け、シンプルな
  「3 アクションの子孫なら収集」ルールを採る。

### `skipped="YES"` のテストの扱い(確定事項)

**`skipped` に関係なく収集する。** スコープ = インデックス/補完の対象であって実行対象ではない。
スキップ設定のテストもユーザーは編集・補完したいので、`skipped="YES"` の `TestableReference` 配下の
`BuildableReference` も seed に含める。これは上記収集ルールから自然に導かれる(`skipped` 属性を
一切参照しない)。

### 変更しない部分

- `XcodeBuildServer.resolveScheme(named:schemeTargets:allTargets:)`
  (`XcodeBuildServer.swift:363-384`): blueprintName + container での照合は seed の出所(どのアクション
  由来か)に依存しないため無改修。`containerMatches` による #2 のコンテナ曖昧性解消も自動適用。
- `applySchemeScope`(seed → `dependencyClosure(forTargetGUIDs:)` → `allTargets` フィルタ)、
  および `.fallbackNotFound` / `.fallbackNoKnownTargets` のフォールバック判定。
- `SchemeBuildTarget` / `SchemeBuildableReference` の構造、コンテナ解決 `resolveContainer`、
  scheme ファイル探索 `schemeFileURL`(shared → user、workspace のメンバ .xcodeproj 探索)。

### 命名の更新

実態に合わせて以下をリネームする:

- `XcodeScheme.buildActionReferences(xcschemeContents:)` → `schemeSeedReferences(xcschemeContents:)`
- `private final class BuildActionDelegate` → `SchemeReferenceDelegate`
- 公開エントリ `XcodeScheme.buildTargets(scheme:containerPath:projectRoot:)` は呼び出し名の互換を保つ
  ため**名前は維持**し、doc コメントを「Build + Test + Launch アクションのターゲットを seed として
  返す」に更新する(返り値の意味だけが拡張される)。

`buildActionReferences` を直接呼ぶ単体テストは `Tests/BuildServerIntegrationTests/XcodeSchemeTests.swift`
に 4 箇所あり、新名へ追従させる(`resolveScheme` ベースのテストは無改修)。

### 設定 doc / スキーマの更新

`Sources/SKOptions/SourceKitLSPOptions.swift` の `XcodeOptions.scheme` の doc コメントを、スコープが
「Build アクション」だけでなく「Build / Test / Launch アクションのターゲット + 依存クロージャ」である
ことを反映するよう更新。続けて以下を実行して生成物を再生成する(手編集禁止):

```
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer ./sourcekit-lsp-dev-utils generate-config-schema
```

これにより `config.schema.json` と `Documentation/Configuration File.md` が更新される。

## テスト

### 単体テスト(全環境、Xcode 不要)

`schemeSeedReferences(xcschemeContents:)` に対して:

- BuildAction(App)+ TestAction Testables(`AppTests` と、`skipped="YES"` の `AppUITests`)+
  LaunchAction runnable(App)を含む scheme XML を渡し、収集結果が
  `App` / `AppTests` / `AppUITests` を含むこと(`skipped` でも `AppUITests` が含まれること)を検証。
- 同一ターゲット(App が BuildAction と LaunchAction の双方に出現)が (name, container) で
  重複排除され 1 件になることを検証。
- 3 アクションの**外**にある `BuildableReference`(例: ルート直下に置いた不正な参照)が無視される
  ことを検証(パーサの頑健性)。
- `ReferencedContainer` が Test/Launch の参照でも `resolveContainer` で絶対 .xcodeproj に解決される
  ことを `buildTargets` 経由で検証(オンディスクの scheme ファイルを使う既存パターンに倣う)。

`resolveScheme`(無改修)に対しては、seed の唯一の出所が Test アクション由来である(BuildAction に
無いターゲット名のみ)ケースで `.seeds` が返ることを 1 件追加。

### 統合テスト(macOS + Xcode 26.4、`skipUnlessXcodeAvailable()`)

- **テストターゲットが BuildAction に無く TestAction Testables にのみ**書かれた scheme フィクスチャを
  用意し、`xcode.scheme` 指定でそのテストターゲットがスコープに入ることを検証(従来は入らなかった
  =回帰防止の核心)。
- 既存挙動の非回帰: テストターゲットが BuildAction にも載っている通常スキームで、スコープ結果が
  従来と同一であること。

`Sources/SKTestSupport/XcodeTestProject.swift` の `writeSharedScheme(named:buildTargetNames:)` を、
TestAction の Testables と LaunchAction の runnable も出力できるよう拡張する(後方互換を保つため
既存シグネチャは残し、テストターゲット/ launch ターゲットを受け取るオーバーロードまたは
デフォルト引数付き拡張を追加)。フィクスチャは既存の `XcodeTestProject.Kind.appWithUnitTestTarget`
(macOS コマンドラインツール `MyApp` + ユニットテストバンドル `MyAppTests`)を再利用し、
`MyAppTests` を BuildAction には載せず TestAction の Testables にのみ書いた scheme を生成する。

### 非回帰

- TestAction / LaunchAction を持たない scheme(BuildAction のみ)の挙動が不変。
- scheme 未指定時の全ターゲット返却が不変。
- 既存 `BuildServerIntegrationTests`(直近 118 件)が非回帰で通過。

## スコープ外 / フォローアップ

- **`BlueprintIdentifier`→GUID 照合**(scheme 対応設計から継続のフォローアップ): 引き続き
  blueprintName(ターゲット名)照合のまま。
- **`skipped` / `buildForTesting` 等による絞り込み**: 本作業では意図的に過剰収集(インデックス目的)。
- **config によるアクション選択**(Build/Test/Launch のどれを scope に使うか設定で切替): YAGNI。
- **project reference 経由の別 .xcodeproj** / **`contents.xcworkspacedata` サブディレクトリ参照解決** /
  **visionOS**: 他フォローアップとして据え置き。

## 完了の定義 (Definition of Done)

- `xcode.scheme` 指定時、scheme の Build / Test(Testables)/ Launch(runnable)各アクションの
  `BuildableReference` が seed となり、その依存クロージャに `buildTargets` / `buildTargetSources` /
  `prepare` / `sourceKitOptions` のスコープが限定される。
- テストターゲットが TestAction の Testables にのみ書かれたスキームで、当該テストターゲットが
  スコープに含まれる(統合テストで検証)。
- `skipped="YES"` の TestableReference 配下のターゲットも収集される。
- 同一ターゲットが複数アクションに現れても重複排除される。
- BuildAction のみのスキーム、および scheme 未指定時の挙動が不変(非回帰テストで検証)。
- パーサ / コンテナ解決の単体テストが全環境で通過し、統合テストが macOS + Xcode で通過。
- `XcodeOptions.scheme` の doc コメント更新に伴い `config.schema.json` /
  `Documentation/Configuration File.md` が再生成される。
- 既存 `BuildServerIntegrationTests` が非回帰で通過。
