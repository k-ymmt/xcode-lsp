# Xcode project-reference resolution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `MyApp.xcodeproj` が `PBXProject.projectReferences` で別の `.xcodeproj` を参照しているとき、参照先のターゲットを `.dependency` と誤タグせず、ルート(インデックス・テスト探索対象)として扱う。

**Architecture:** 新規の SwiftBuild 非依存・純粋型 `XcodeProject` が `project.pbxproj`(`PropertyListSerialization` でパース)から project reference 先 `.xcodeproj` を解決する。`XcodeBuildServer.rootProjectPaths()` はシード(コンテナ自身 / workspace メンバー)から project reference を BFS で推移展開し、`isPartOfRootProject` の入力 root 集合を広げる。SwiftPM パッケージは project reference ではないので構造上除外され、従来どおり `.dependency` のまま。

**Tech Stack:** Swift, Foundation (`PropertyListSerialization`), SwiftBuild(隔離越し), XCTest。ビルド/テストは `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift {build,test}`。コミット前に `DEVELOPER_DIR=… swift format -ipr .`。

**設計 spec:** `docs/superpowers/specs/2026-05-28-xcode-project-reference-resolution-design.md`

**制約:** このリポジトリへは push / PR しない(ローカルコミットのみ)。新規ファイルには Swift プロジェクトのライセンスヘッダ(`.license_header_template`)。新規ソースは既存兄弟(`XcodeWorkspace.swift` 等)に倣い `#if !NO_SWIFTPM_DEPENDENCY` でガード。

---

## File Structure

- **Create** `Sources/BuildServerIntegration/XcodeProject.swift` — `project.pbxproj` から project reference 先を解決する純粋パーサ。`XcodeWorkspace.swift` と並ぶ。`import SwiftBuild` なし。
- **Modify** `Sources/BuildServerIntegration/XcodeBuildServer.swift` — `rootProjectPaths()` を BFS 展開に変更。`expandedRootProjects(seeds:referencedProjects:)`(package static, 単体テスト可)を追加。
- **Create** `Tests/BuildServerIntegrationTests/XcodeProjectTests.swift` — `XcodeProject` の純粋パーサ単体テスト(全環境、ディスク不要。入力は XML plist として生成し OpenStep 読み取りのプラットフォーム差を回避)。
- **Modify** `Sources/SKTestSupport/XcodeTestProject.swift` — `Kind.appWithProjectReference` + App/Framework の 2 つの pbxproj テンプレート + マテリアライズ。
- **Modify** `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift` — `expandedRootProjects` の単体テスト + `.dependency` 誤タグ修正の統合テスト(macOS + Xcode ゲート)。

### なぜ単体テストは XML plist 入力か

実 `project.pbxproj` は旧式 OpenStep plist。`PropertyListSerialization` は**フォーマット自動判定で読む**ため、macOS では OpenStep も読める。一方 swift-corelibs-foundation(Linux CI)の OpenStep 読み取りは不確実。`XcodeProjectTests` は全プラットフォームで走るので、入力をテスト内で `[String: Any]` から `PropertyListSerialization.data(fromPropertyList:format:.xml)` で生成し、パース/解決ロジックだけを検証する(パーサ本体はフォーマット非依存)。実 OpenStep pbxproj の読み取りは macOS 限定の統合テスト(Task 6)で担保する。

---

## Task 1: `XcodeProject.projectReferences` の最小実装(`<group>` / `SOURCE_ROOT`)

**Files:**
- Create: `Sources/BuildServerIntegration/XcodeProject.swift`
- Test: `Tests/BuildServerIntegrationTests/XcodeProjectTests.swift`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/BuildServerIntegrationTests/XcodeProjectTests.swift` を新規作成(ライセンスヘッダ付き):

```swift
import BuildServerIntegration
import Foundation
import XCTest

final class XcodeProjectTests: XCTestCase {
  #if !NO_SWIFTPM_DEPENDENCY

  /// Serialize a pbxproj-shaped object graph as an XML plist. `PropertyListSerialization` parses by
  /// format auto-detection, so this exercises the same code path as a real OpenStep `project.pbxproj`
  /// while staying portable across platforms (OpenStep read support is not guaranteed off macOS).
  private func pbxprojData(objects: [String: Any], rootObject: String) -> Data {
    let plist: [String: Any] = [
      "archiveVersion": "1",
      "objectVersion": "56",
      "objects": objects,
      "rootObject": rootObject,
    ]
    return try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
  }

  func testResolvesGroupRelativeReferenceInMainGroup() {
    let data = pbxprojData(
      objects: [
        "PROJ": [
          "isa": "PBXProject",
          "mainGroup": "G_MAIN",
          "projectReferences": [["ProductGroup": "G_PROD", "ProjectRef": "FREF"]],
        ],
        "G_MAIN": ["isa": "PBXGroup", "children": ["FREF"], "sourceTree": "<group>"],
        "FREF": [
          "isa": "PBXFileReference",
          "path": "Framework/Framework.xcodeproj",
          "sourceTree": "<group>",
        ],
      ],
      rootObject: "PROJ"
    )
    let resolved = XcodeProject.projectReferences(
      pbxprojContents: data,
      projectDir: URL(fileURLWithPath: "/root", isDirectory: true)
    )
    XCTAssertEqual(resolved.map(\.path), ["/root/Framework/Framework.xcodeproj"])
  }

  func testResolvesSourceRootReference() {
    let data = pbxprojData(
      objects: [
        "PROJ": [
          "isa": "PBXProject",
          "mainGroup": "G_MAIN",
          "projectReferences": [["ProductGroup": "G_PROD", "ProjectRef": "FREF"]],
        ],
        "G_MAIN": ["isa": "PBXGroup", "children": ["FREF"], "sourceTree": "<group>"],
        "FREF": [
          "isa": "PBXFileReference",
          "path": "Framework/Framework.xcodeproj",
          "sourceTree": "SOURCE_ROOT",
        ],
      ],
      rootObject: "PROJ"
    )
    let resolved = XcodeProject.projectReferences(
      pbxprojContents: data,
      projectDir: URL(fileURLWithPath: "/root", isDirectory: true)
    )
    XCTAssertEqual(resolved.map(\.path), ["/root/Framework/Framework.xcodeproj"])
  }
  #endif
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeProjectTests`
Expected: コンパイルエラー(`XcodeProject` が未定義)。

- [ ] **Step 3: `XcodeProject.swift` を最小実装**

`Sources/BuildServerIntegration/XcodeProject.swift` を新規作成(ライセンスヘッダ付き):

```swift
#if !NO_SWIFTPM_DEPENDENCY
package import Foundation

/// Parses an Xcode `.xcodeproj`'s `project.pbxproj` to enumerate the other `.xcodeproj`s it references
/// via `PBXProject.projectReferences`. SwiftBuild does not expose which projects are project-referenced
/// (vs. SwiftPM packages), so the build server reads it from disk itself. This type has no
/// `import SwiftBuild` dependency.
package enum XcodeProject {
  /// The other `.xcodeproj`s referenced by `projectURL`'s `PBXProject.projectReferences`, fully resolved.
  /// Reads `<projectURL>/project.pbxproj`; returns `[]` if it is absent or unreadable.
  package static func referencedProjects(ofProjectAt projectURL: URL) -> [URL] {
    let pbxprojURL = projectURL.appendingPathComponent("project.pbxproj", isDirectory: false)
    guard let data = try? Data(contentsOf: pbxprojURL) else {
      return []
    }
    return projectReferences(pbxprojContents: data, projectDir: projectURL.deletingLastPathComponent())
  }

  /// Parse a `project.pbxproj` and return the `.xcodeproj`s referenced via `PBXProject.projectReferences`,
  /// each resolved to an absolute URL relative to `projectDir` (the directory containing the `.xcodeproj`).
  /// De-duplicated by resolved path, preserving order. Returns `[]` for malformed data or no references.
  ///
  /// `PropertyListSerialization` reads OpenStep, XML, and binary plists by auto-detecting the format, so
  /// real (OpenStep) `project.pbxproj` files parse here on platforms whose Foundation supports it (macOS).
  package static func projectReferences(pbxprojContents: Data, projectDir: URL) -> [URL] {
    guard
      let plist = try? PropertyListSerialization.propertyList(from: pbxprojContents, options: [], format: nil),
      let root = plist as? [String: Any],
      let objects = root["objects"] as? [String: Any],
      let rootObjectID = root["rootObject"] as? String,
      let project = objects[rootObjectID] as? [String: Any],
      let references = project["projectReferences"] as? [[String: Any]]
    else {
      return []
    }
    var resolved: [URL] = []
    var seen = Set<String>()
    for reference in references {
      guard
        let projectRefID = reference["ProjectRef"] as? String,
        let url = resolvePath(objectID: projectRefID, objects: objects, projectDir: projectDir),
        url.pathExtension == "xcodeproj",
        seen.insert(url.path).inserted
      else {
        continue
      }
      resolved.append(url)
    }
    return resolved
  }

  /// Resolve a PBXFileReference/PBXGroup object's on-disk URL by combining its `path` with the base
  /// directory implied by its `sourceTree` and enclosing groups. Returns `nil` for source trees that do
  /// not denote an on-disk source location (`BUILT_PRODUCTS_DIR`, `DEVELOPER_DIR`, `SDKROOT`, etc.).
  /// `visited` guards against pathological group cycles in malformed input.
  private static func resolvePath(
    objectID: String,
    objects: [String: Any],
    projectDir: URL,
    visited: Set<String> = []
  ) -> URL? {
    guard !visited.contains(objectID), let object = objects[objectID] as? [String: Any] else {
      return nil
    }
    let path = object["path"] as? String
    let base: URL
    switch object["sourceTree"] as? String {
    case "<absolute>":
      guard let path, !path.isEmpty else { return nil }
      return URL(fileURLWithPath: path).standardizedFileURL
    case "SOURCE_ROOT":
      base = projectDir
    case "<group>":
      base = parentGroupBase(
        ofObjectID: objectID,
        objects: objects,
        projectDir: projectDir,
        visited: visited.union([objectID])
      )
    default:
      // BUILT_PRODUCTS_DIR / DEVELOPER_DIR / SDKROOT / unknown: not an on-disk source project reference.
      return nil
    }
    guard let path, !path.isEmpty else {
      return base.standardizedFileURL
    }
    return URL(fileURLWithPath: (base.path as NSString).appendingPathComponent(path)).standardizedFileURL
  }

  /// The resolved base directory for a `<group>`-relative object: the resolved path of the PBXGroup that
  /// lists it as a child, or `projectDir` if no group does (e.g. it sits in the main group, which itself
  /// resolves to `projectDir`).
  private static func parentGroupBase(
    ofObjectID objectID: String,
    objects: [String: Any],
    projectDir: URL,
    visited: Set<String>
  ) -> URL {
    for (groupID, value) in objects {
      guard
        let group = value as? [String: Any],
        let isa = group["isa"] as? String,
        isa == "PBXGroup" || isa == "PBXVariantGroup",
        let children = group["children"] as? [String],
        children.contains(objectID)
      else {
        continue
      }
      return resolvePath(objectID: groupID, objects: objects, projectDir: projectDir, visited: visited)
        ?? projectDir
    }
    return projectDir
  }
}
#endif
```

- [ ] **Step 4: テストが通ることを確認**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeProjectTests`
Expected: PASS(2 件)。

- [ ] **Step 5: フォーマットしてコミット**

```bash
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift format -ipr .
git add Sources/BuildServerIntegration/XcodeProject.swift Tests/BuildServerIntegrationTests/XcodeProjectTests.swift
git commit -m "feat(BuildServerIntegration): XcodeProject.projectReferences parser

Task: project reference 経由の別 .xcodeproj をルート扱い(設計 spec 2026-05-28)。
pbxproj の PBXProject.projectReferences から参照先 .xcodeproj を解決する純粋パーサ。

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 2: パス解決のエッジケースを網羅

**Files:**
- Test: `Tests/BuildServerIntegrationTests/XcodeProjectTests.swift`(追記)
- Modify(必要時): `Sources/BuildServerIntegration/XcodeProject.swift`

- [ ] **Step 1: 失敗しうるテストを追記**

`XcodeProjectTests` の `#if !NO_SWIFTPM_DEPENDENCY` ブロック内、`testResolvesSourceRootReference()` の後に追記:

```swift
func testResolvesAbsoluteReference() {
  let data = pbxprojData(
    objects: [
      "PROJ": [
        "isa": "PBXProject", "mainGroup": "G_MAIN",
        "projectReferences": [["ProductGroup": "G_PROD", "ProjectRef": "FREF"]],
      ],
      "G_MAIN": ["isa": "PBXGroup", "children": ["FREF"], "sourceTree": "<group>"],
      "FREF": ["isa": "PBXFileReference", "path": "/elsewhere/Lib.xcodeproj", "sourceTree": "<absolute>"],
    ],
    rootObject: "PROJ"
  )
  let resolved = XcodeProject.projectReferences(
    pbxprojContents: data, projectDir: URL(fileURLWithPath: "/root", isDirectory: true)
  )
  XCTAssertEqual(resolved.map(\.path), ["/elsewhere/Lib.xcodeproj"])
}

func testAccumulatesNestedGroupPaths() {
  // FREF lives in G_SUB ("Sub"), itself a child of the main group → /root/Sub/Lib.xcodeproj.
  let data = pbxprojData(
    objects: [
      "PROJ": [
        "isa": "PBXProject", "mainGroup": "G_MAIN",
        "projectReferences": [["ProductGroup": "G_PROD", "ProjectRef": "FREF"]],
      ],
      "G_MAIN": ["isa": "PBXGroup", "children": ["G_SUB"], "sourceTree": "<group>"],
      "G_SUB": ["isa": "PBXGroup", "children": ["FREF"], "path": "Sub", "sourceTree": "<group>"],
      "FREF": ["isa": "PBXFileReference", "path": "Lib.xcodeproj", "sourceTree": "<group>"],
    ],
    rootObject: "PROJ"
  )
  let resolved = XcodeProject.projectReferences(
    pbxprojContents: data, projectDir: URL(fileURLWithPath: "/root", isDirectory: true)
  )
  XCTAssertEqual(resolved.map(\.path), ["/root/Sub/Lib.xcodeproj"])
}

func testReturnsMultipleReferencesDeduplicated() {
  let data = pbxprojData(
    objects: [
      "PROJ": [
        "isa": "PBXProject", "mainGroup": "G_MAIN",
        "projectReferences": [
          ["ProductGroup": "G1", "ProjectRef": "FREF_A"],
          ["ProductGroup": "G2", "ProjectRef": "FREF_B"],
          ["ProductGroup": "G3", "ProjectRef": "FREF_A_DUP"],
        ],
      ],
      "G_MAIN": ["isa": "PBXGroup", "children": ["FREF_A", "FREF_B", "FREF_A_DUP"], "sourceTree": "<group>"],
      "FREF_A": ["isa": "PBXFileReference", "path": "A/A.xcodeproj", "sourceTree": "<group>"],
      "FREF_B": ["isa": "PBXFileReference", "path": "B/B.xcodeproj", "sourceTree": "<group>"],
      "FREF_A_DUP": ["isa": "PBXFileReference", "path": "A/A.xcodeproj", "sourceTree": "<group>"],
    ],
    rootObject: "PROJ"
  )
  let resolved = XcodeProject.projectReferences(
    pbxprojContents: data, projectDir: URL(fileURLWithPath: "/root", isDirectory: true)
  )
  XCTAssertEqual(resolved.map(\.path), ["/root/A/A.xcodeproj", "/root/B/B.xcodeproj"])
}

func testSkipsNonXcodeprojReferences() {
  let data = pbxprojData(
    objects: [
      "PROJ": [
        "isa": "PBXProject", "mainGroup": "G_MAIN",
        "projectReferences": [["ProductGroup": "G", "ProjectRef": "FREF"]],
      ],
      "G_MAIN": ["isa": "PBXGroup", "children": ["FREF"], "sourceTree": "<group>"],
      "FREF": ["isa": "PBXFileReference", "path": "notes.txt", "sourceTree": "<group>"],
    ],
    rootObject: "PROJ"
  )
  XCTAssertEqual(
    XcodeProject.projectReferences(pbxprojContents: data, projectDir: URL(fileURLWithPath: "/root")),
    []
  )
}

func testSkipsNonDiskSourceTrees() {
  let data = pbxprojData(
    objects: [
      "PROJ": [
        "isa": "PBXProject", "mainGroup": "G_MAIN",
        "projectReferences": [["ProductGroup": "G", "ProjectRef": "FREF"]],
      ],
      "G_MAIN": ["isa": "PBXGroup", "children": ["FREF"], "sourceTree": "<group>"],
      "FREF": ["isa": "PBXFileReference", "path": "Built.xcodeproj", "sourceTree": "BUILT_PRODUCTS_DIR"],
    ],
    rootObject: "PROJ"
  )
  XCTAssertEqual(
    XcodeProject.projectReferences(pbxprojContents: data, projectDir: URL(fileURLWithPath: "/root")),
    []
  )
}

func testReturnsEmptyWhenNoProjectReferences() {
  let data = pbxprojData(
    objects: ["PROJ": ["isa": "PBXProject", "mainGroup": "G_MAIN"], "G_MAIN": ["isa": "PBXGroup", "children": [], "sourceTree": "<group>"]],
    rootObject: "PROJ"
  )
  XCTAssertEqual(
    XcodeProject.projectReferences(pbxprojContents: data, projectDir: URL(fileURLWithPath: "/root")),
    []
  )
}

func testReturnsEmptyForMalformedData() {
  let data = Data("this is not a plist".utf8)
  XCTAssertEqual(
    XcodeProject.projectReferences(pbxprojContents: data, projectDir: URL(fileURLWithPath: "/root")),
    []
  )
}
```

- [ ] **Step 2: テストを実行**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeProjectTests`
Expected: 全 9 件 PASS(Task 1 実装で網羅済みのはず)。もし `testAccumulatesNestedGroupPaths` 等が失敗したら `resolvePath`/`parentGroupBase` を見直して修正。

- [ ] **Step 3: コミット**

```bash
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift format -ipr .
git add Tests/BuildServerIntegrationTests/XcodeProjectTests.swift Sources/BuildServerIntegration/XcodeProject.swift
git commit -m "test(BuildServerIntegration): XcodeProject path resolution edge cases

Task: project reference 解決の <absolute>/ネストグループ/dedupe/非xcodeproj/不正データ網羅。

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 3: `referencedProjects(ofProjectAt:)` の I/O ラッパをテスト

**Files:**
- Test: `Tests/BuildServerIntegrationTests/XcodeProjectTests.swift`(追記)

`referencedProjects` は Task 1 で実装済み。ここではディスク I/O 経路をテストする(XML plist で書くので全プラットフォーム可)。

- [ ] **Step 1: 失敗しうるテストを追記**

`XcodeProjectTests` に追記:

```swift
func testReferencedProjectsReadsFromDisk() throws {
  let tmp = FileManager.default.temporaryDirectory
    .appendingPathComponent("XcodeProjectTests-\(UUID().uuidString)", isDirectory: true)
  let appXcodeproj = tmp.appendingPathComponent("MyApp.xcodeproj", isDirectory: true)
  try FileManager.default.createDirectory(at: appXcodeproj, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: tmp) }

  let data = pbxprojData(
    objects: [
      "PROJ": [
        "isa": "PBXProject", "mainGroup": "G_MAIN",
        "projectReferences": [["ProductGroup": "G", "ProjectRef": "FREF"]],
      ],
      "G_MAIN": ["isa": "PBXGroup", "children": ["FREF"], "sourceTree": "<group>"],
      "FREF": ["isa": "PBXFileReference", "path": "Framework/Framework.xcodeproj", "sourceTree": "<group>"],
    ],
    rootObject: "PROJ"
  )
  try data.write(to: appXcodeproj.appendingPathComponent("project.pbxproj", isDirectory: false))

  let resolved = XcodeProject.referencedProjects(ofProjectAt: appXcodeproj)
  XCTAssertEqual(
    resolved.map { $0.standardizedFileURL.path },
    [tmp.appendingPathComponent("Framework/Framework.xcodeproj").standardizedFileURL.path]
  )
}

func testReferencedProjectsReturnsEmptyWhenPbxprojAbsent() {
  let missing = FileManager.default.temporaryDirectory
    .appendingPathComponent("does-not-exist-\(UUID().uuidString).xcodeproj", isDirectory: true)
  XCTAssertEqual(XcodeProject.referencedProjects(ofProjectAt: missing), [])
}
```

- [ ] **Step 2: テストを実行**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeProjectTests`
Expected: 全 11 件 PASS。

- [ ] **Step 3: コミット**

```bash
git add Tests/BuildServerIntegrationTests/XcodeProjectTests.swift
git commit -m "test(BuildServerIntegration): XcodeProject.referencedProjects disk I/O

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 4: `rootProjectPaths()` を BFS 推移展開に変更

**Files:**
- Modify: `Sources/BuildServerIntegration/XcodeBuildServer.swift`(`rootProjectPaths()` 周辺 L142、`expandedRootProjects` を追加)
- Test: `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift`(`isPartOfRootProject` テスト群の後に追記)

- [ ] **Step 1: 失敗するテスト(BFS 単体)を書く**

`Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift` の `testNonMemberProjectIsNotPartOfRootProjectAmongMultipleRoots()`(L288–295)の直後に追記:

```swift
// MARK: - expandedRootProjects

func testExpandsTransitiveProjectReferences() {
  let a = URL(fileURLWithPath: "/proj/A.xcodeproj")
  let b = URL(fileURLWithPath: "/proj/B.xcodeproj")
  let c = URL(fileURLWithPath: "/proj/C.xcodeproj")
  let refs: [String: [URL]] = ["/proj/A.xcodeproj": [b], "/proj/B.xcodeproj": [c]]
  let expanded = XcodeBuildServer.expandedRootProjects(seeds: [a]) { refs[$0.path] ?? [] }
  XCTAssertEqual(Set(expanded.map(\.path)), ["/proj/A.xcodeproj", "/proj/B.xcodeproj", "/proj/C.xcodeproj"])
}

func testExpandedRootProjectsBreaksCycles() {
  let a = URL(fileURLWithPath: "/proj/A.xcodeproj")
  let b = URL(fileURLWithPath: "/proj/B.xcodeproj")
  let refs: [String: [URL]] = ["/proj/A.xcodeproj": [b], "/proj/B.xcodeproj": [a]]
  let expanded = XcodeBuildServer.expandedRootProjects(seeds: [a]) { refs[$0.path] ?? [] }
  XCTAssertEqual(Set(expanded.map(\.path)), ["/proj/A.xcodeproj", "/proj/B.xcodeproj"])
}

func testExpandedRootProjectsDedupesAcrossSeeds() {
  let a = URL(fileURLWithPath: "/proj/A.xcodeproj")
  let b = URL(fileURLWithPath: "/proj/B.xcodeproj")
  let refs: [String: [URL]] = ["/proj/A.xcodeproj": [b]]
  let expanded = XcodeBuildServer.expandedRootProjects(seeds: [a, b]) { refs[$0.path] ?? [] }
  XCTAssertEqual(Set(expanded.map(\.path)), ["/proj/A.xcodeproj", "/proj/B.xcodeproj"])
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeBuildServerTests/testExpandsTransitiveProjectReferences`
Expected: コンパイルエラー(`expandedRootProjects` 未定義)。

- [ ] **Step 3: `expandedRootProjects` を実装**

`Sources/BuildServerIntegration/XcodeBuildServer.swift` の `normalizedPath(_:)`(L343–345)の直後に追加:

```swift
/// Expand a seed set of `.xcodeproj` paths by transitively following project references, so that the
/// project the user opened — and every other `.xcodeproj` it project-references (directly or
/// transitively) — counts as part of the root project. `referencedProjects` returns the direct project
/// references of one `.xcodeproj` (resolved, and in production existence-filtered). Cycles and duplicate
/// seeds are handled by tracking visited projects via `normalizedPath`.
package static func expandedRootProjects(
  seeds: Set<URL>,
  referencedProjects: (URL) -> [URL]
) -> Set<URL> {
  var byKey: [String: URL] = [:]
  var queue: [URL] = []
  for seed in seeds where byKey[normalizedPath(seed)] == nil {
    byKey[normalizedPath(seed)] = seed
    queue.append(seed)
  }
  while let current = queue.popLast() {
    for referenced in referencedProjects(current) {
      let key = normalizedPath(referenced)
      if byKey[key] == nil {
        byKey[key] = referenced
        queue.append(referenced)
      }
    }
  }
  return Set(byKey.values)
}
```

- [ ] **Step 4: テストが通ることを確認**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeBuildServerTests/testExpandsTransitiveProjectReferences XcodeBuildServerTests/testExpandedRootProjectsBreaksCycles XcodeBuildServerTests/testExpandedRootProjectsDedupesAcrossSeeds`
Expected: 3 件 PASS。

- [ ] **Step 5: `rootProjectPaths()` を BFS 展開で配線**

`Sources/BuildServerIntegration/XcodeBuildServer.swift` の `rootProjectPaths()`(L142–155)を以下に置換:

```swift
  /// The set of `.xcodeproj` paths considered part of the project the user opened: the container itself
  /// for an `.xcodeproj` (or the member `.xcodeproj`s of an `.xcworkspace`), plus every `.xcodeproj` they
  /// reach transitively through `PBXProject.projectReferences`. A target whose owning project is outside
  /// this set (e.g. a SwiftPM package, which is not a project reference) is tagged `.dependency`.
  private func rootProjectPaths() -> Set<URL> {
    let seeds: Set<URL>
    if containerPath.pathExtension == "xcworkspace" {
      if let members = XcodeWorkspace.memberProjects(workspaceURL: containerPath) {
        seeds = Set(members)
      } else {
        // Fallback when contents.xcworkspacedata is absent/unreadable: previous top-level scan behavior.
        let entries =
          orLog("Enumerating member projects under \(projectRoot.path)") {
            try FileManager.default.contentsOfDirectory(at: projectRoot, includingPropertiesForKeys: nil)
          } ?? []
        seeds = Set(entries.filter { $0.pathExtension == "xcodeproj" })
      }
    } else {
      seeds = [containerPath]
    }
    return Self.expandedRootProjects(seeds: seeds) { projectURL in
      XcodeProject.referencedProjects(ofProjectAt: projectURL).filter {
        FileManager.default.fileExists(atPath: $0.path)
      }
    }
  }
```

- [ ] **Step 6: ビルドして既存単体テストが非回帰なことを確認**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift build --target BuildServerIntegration`
Expected: ビルド成功。

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeBuildServerTests/testRootProjectTargetIsPartOfRootProject XcodeBuildServerTests/testPackageDependencyTargetIsNotPartOfRootProject`
Expected: PASS(`isPartOfRootProject` の挙動は不変)。

- [ ] **Step 7: フォーマットしてコミット**

```bash
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift format -ipr .
git add Sources/BuildServerIntegration/XcodeBuildServer.swift Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift
git commit -m "feat(BuildServerIntegration): rootProjectPaths follows project references

Task: rootProjectPaths() がシードから PBXProject.projectReferences を BFS 推移展開し、
project reference 先 .xcodeproj をルート集合に加える。expandedRootProjects は循環/重複を
normalizedPath で吸収。SPM は project reference ではないので展開対象外。

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 5: `.appWithProjectReference` フィクスチャを追加

**Files:**
- Modify: `Sources/SKTestSupport/XcodeTestProject.swift`(`Kind` enum、2 つの pbxproj テンプレート、マテリアライズ)

> **重要(リスク・検証ゲート):** project-reference 構成の pbxproj 手書きはこれまでで最も複雑(`PBXFileReference` + `PBXContainerItemProxy` + `PBXReferenceProxy` + `ProductGroup` + `projectReferences`)。**Xcode 26.4 が真の正本**。下記テンプレートは出発点であり、Step 5 の `xcodebuild -dumpPIF` / `plutil -lint` で**両ターゲットが別 GUID + 正しい `PROJECT_FILE_PATH` で公開されること**を確認できるまで調整する。検証で参照先ターゲットが PIF に現れない場合は、App ターゲットに `PBXTargetDependency`(下記注記)を追加し、Frameworks ビルドフェーズに `PBXReferenceProxy` をリンクする。

レイアウト: `<root>/MyApp.xcodeproj`(target `MyApp`、tool)が `<root>/Framework/Framework.xcodeproj`(target `Framework`、framework)を project reference する。`<root>/main.swift` と `<root>/Framework/Framework.swift`。

- [ ] **Step 1: `Kind` に `appWithProjectReference` を追加**

`Sources/SKTestSupport/XcodeTestProject.swift` の `Kind` enum(L76 `case workspaceWithNestedProject` の後)に追加:

```swift
    /// A macOS command-line tool `MyApp` (with `main.swift`) whose `MyApp.xcodeproj` project-references a
    /// separate `Framework/Framework.xcodeproj` (target `Framework`, a framework, with `Framework.swift`).
    /// Exercises that a project-referenced `.xcodeproj`'s targets are treated as root (not `.dependency`).
    case appWithProjectReference
```

そして型レベルのドキュメントコメント(L15–34)末尾にも 1 文追記:

```swift
/// `.appWithProjectReference` produces a `MyApp.xcodeproj` (target `MyApp`) that project-references a
/// separate `Framework/Framework.xcodeproj` (target `Framework`).
```

- [ ] **Step 2: 2 つの pbxproj テンプレートを追加**

`Sources/SKTestSupport/XcodeTestProject.swift` の既存テンプレート群の末尾(`duplicateTargetAppBTemplate` 等の後、`package init` の前)に、`// swift-format-ignore` 付き `static let` を 2 つ追加。タブは `\t` エスケープで表現する(`duplicateTargetAppATemplate` と同じ流儀)。

**(a) `frameworkOnlyPbxprojTemplate`** — 単一 framework ターゲット `Framework` の `.xcodeproj`。`appWithFrameworkPbxprojTemplate` の Framework ターゲット(productType `com.apple.product-type.framework`、`B100…A2` を product reference、`B100…E1` を target、`PRODUCT_NAME = "$(TARGET_NAME:c99extidentifier)"`)を単独プロジェクトとして再構成する。`PBXProject`(`B100…B0`)・mainGroup(`B100…D1`、children = `Framework.swift` + Products)・Products group(`B100…D2`、children = `B100…A2`)・Sources フェーズ(`B100…C2`、`Framework.swift in Sources`)・`XCConfigurationList`/`XCBuildConfiguration` を備える。`targets = ( B100…E1 /* Framework */, )`、`rootObject = B100…B0`。

**(b) `appWithProjectReferencePbxprojTemplate`** — `pbxprojTemplate`(macOS tool `MyApp`、A1-prefix)をベースに、以下の project-reference オブジェクト(A2-prefix で ID 衝突回避)を追加する:

- PBXFileReference section に:
  ```
  A200000000000000000000R1 /* Framework.xcodeproj */ = {isa = PBXFileReference; lastKnownFileType = "wrapper.pb-project"; name = Framework.xcodeproj; path = "Framework/Framework.xcodeproj"; sourceTree = "<group>"; };
  ```
- PBXReferenceProxy section(新設)に:
  ```
  A200000000000000000000P1 /* Framework.framework */ = {isa = PBXReferenceProxy; fileType = wrapper.framework; path = Framework.framework; remoteRef = A200000000000000000000X1 /* PBXContainerItemProxy */; sourceTree = BUILT_PRODUCTS_DIR; };
  ```
- PBXContainerItemProxy section(新設)に(`remoteGlobalIDString` は frameworkOnlyPbxprojTemplate の product reference ID `B100000000000000000000A2`):
  ```
  A200000000000000000000X1 /* PBXContainerItemProxy */ = {isa = PBXContainerItemProxy; containerPortal = A200000000000000000000R1 /* Framework.xcodeproj */; proxyType = 2; remoteGlobalIDString = B100000000000000000000A2; remoteInfo = Framework; };
  ```
- PBXGroup section に Products proxy group:
  ```
  A200000000000000000000G1 /* Products */ = {isa = PBXGroup; children = ( A200000000000000000000P1 /* Framework.framework */, ); name = Products; sourceTree = "<group>"; };
  ```
- main group(`A100000000000000000000D1`)の `children` に `A200000000000000000000R1 /* Framework.xcodeproj */` と `A200000000000000000000G1 /* Products */` を追加(これにより parser の `parentGroupBase` が file ref を main group 配下と認識 → `projectDir` 基準で解決)。
- PBXProject(`A100000000000000000000B0`)に追加:
  ```
  projectReferences = (
      {
          ProductGroup = A200000000000000000000G1 /* Products */;
          ProjectRef = A200000000000000000000R1 /* Framework.xcodeproj */;
      },
  );
  ```

> **注記(依存が必要だった場合のフォールバック):** Step 5 の PIF 検証で `Framework` ターゲットが現れない場合のみ、(1) `PBXContainerItemProxy`(proxyType=1, `remoteGlobalIDString = B100000000000000000000E1`)+ `PBXTargetDependency` を追加し `MyApp` ターゲットの `dependencies` に積む、(2) `A200000000000000000000P1` を `MyApp` の Frameworks ビルドフェーズ(`A100000000000000000000C1`)の `files` に `PBXBuildFile` 経由でリンクする。

- [ ] **Step 3: マテリアライズを追加**

`Sources/SKTestSupport/XcodeTestProject.swift` の `package init` 内、`if case .workspaceWithNestedProject = kind { … }` ブロック(L1815–1858)の後に追加:

```swift
    if case .appWithProjectReference = kind {
      // Root project: MyApp.xcodeproj (target MyApp, A1/A2 ids) with main.swift at the project root.
      try fileManager.createDirectory(at: xcodeprojURL, withIntermediateDirectories: true)
      try Self.appWithProjectReferencePbxprojTemplate.write(
        to: xcodeprojURL.appendingPathComponent("project.pbxproj", isDirectory: false),
        atomically: true,
        encoding: .utf8
      )
      try sourceContents.write(to: sourceFileURL, atomically: true, encoding: .utf8)

      // Project-referenced project: Framework/Framework.xcodeproj (target Framework, B1 ids).
      let fwProjDir = root.appendingPathComponent("Framework", isDirectory: true)
      let fwXcodeproj = fwProjDir.appendingPathComponent("Framework.xcodeproj", isDirectory: true)
      try fileManager.createDirectory(at: fwXcodeproj, withIntermediateDirectories: true)
      try Self.frameworkOnlyPbxprojTemplate.write(
        to: fwXcodeproj.appendingPathComponent("project.pbxproj", isDirectory: false),
        atomically: true,
        encoding: .utf8
      )
      try "public func frameworkEntry() {}\n".write(
        to: fwProjDir.appendingPathComponent("Framework.swift", isDirectory: false),
        atomically: true,
        encoding: .utf8
      )
    }
```

`appWithProjectReference` は `xcodeprojURL = MyApp.xcodeproj`(`init` の `default` arm)と `sourceFileURL = main.swift`(L1685 のリストに `appWithProjectReference` を追加)を使う。**`init` 冒頭の 2 つの `switch kind`**(L1684–1698 のソースパス選択)で `.macOSCommandLineTool, .iOSApp, …` を列挙している arm に `.appWithProjectReference` を追加して `main.swift` を project root にする。`xcodeprojURL`/`workspaceURL` は `default` arm(L1676–1678)が `MyApp.xcodeproj` / `nil` を返すのでそのまま。

- [ ] **Step 4: ビルドして SKTestSupport がコンパイルできることを確認**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift build --target SKTestSupport`
Expected: ビルド成功(switch 網羅漏れがあればここで判明 → 追加した arm を修正)。

- [ ] **Step 5: フィクスチャを実 Xcode で検証(ゲート)**

`SOURCEKIT_LSP_KEEP_TEST_SCRATCH_DIR=1` を付けて Task 6 の統合テストを一度走らせるか、または手動で `XcodeTestProject(kind: .appWithProjectReference, sourceContents: "print(\"hi\")\n")` を生成してスクラッチ dir のパスをログから取得し、生成された `MyApp.xcodeproj` に対して:

```bash
# <scratch> は生成された XcodeTestProject-XXXX ディレクトリ
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer \
  plutil -lint "<scratch>/MyApp.xcodeproj/project.pbxproj" "<scratch>/Framework/Framework.xcodeproj/project.pbxproj"
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer \
  xcrun xcodebuild -dumpPIF "<scratch>/MyApp.xcodeproj" 2>/dev/null | grep -E '"(name|projectDirectory|path)"' | head -40
```

Expected: `plutil -lint` が両方 `OK`。`-dumpPIF` 出力に `MyApp` と `Framework` の両ターゲットが現れ、`Framework` の所属プロジェクトが `Framework/Framework.xcodeproj` を指す。現れない場合は Step 2 の注記フォールバック(target dependency + proxy リンク)を適用して再検証。

- [ ] **Step 6: フォーマットしてコミット**

```bash
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift format -ipr .
git add Sources/SKTestSupport/XcodeTestProject.swift
git commit -m "test(SKTestSupport): appWithProjectReference fixture

Task: project reference 構成のフィクスチャ。MyApp.xcodeproj が Framework/Framework.xcodeproj
を project reference。Xcode 26.4 の plutil -lint / xcodebuild -dumpPIF で検証済み。

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 6: 統合テスト — 参照先ターゲットが `.dependency` にならない

**Files:**
- Modify: `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift`(`testPackageDependencyTargetIsTaggedDependency`(L760–793)の後に追記)

- [ ] **Step 1: 統合テストを書く**

```swift
  /// The opened `MyApp.xcodeproj` project-references `Framework/Framework.xcodeproj`. SwiftBuild surfaces
  /// the `Framework` target, and because `rootProjectPaths()` follows the project reference, that target
  /// is treated as root and NOT tagged `.dependency`. Before following project references, `Framework`'s
  /// PROJECT_FILE_PATH fell outside the root set and was mis-tagged — this is the regression test for it.
  func testProjectReferencedTargetIsNotTaggedDependency() async throws {
    try skipUnlessXcodeAvailable()

    let project = try XcodeTestProject(kind: .appWithProjectReference, sourceContents: "print(\"hi\")\n")
    defer { project.keepAlive() }

    // The fixture's pbxproj is real OpenStep; confirm the parser resolves the reference off disk (macOS).
    let referenced = XcodeProject.referencedProjects(ofProjectAt: project.xcodeprojURL)
    XCTAssertEqual(
      referenced.map { $0.standardizedFileURL.lastPathComponent },
      ["Framework.xcodeproj"],
      "expected MyApp.xcodeproj to project-reference Framework.xcodeproj, got \(referenced)"
    )

    let buildServer = try await XcodeBuildServer(
      projectRoot: project.projectRoot,
      containerPath: project.xcodeprojURL,
      toolchainRegistry: .forTesting,
      options: SourceKitLSPOptions(),
      connectionToSourceKitLSP: LocalConnection(receiverName: "Dummy SourceKit-LSP")
    )
    addTeardownBlock { await buildServer.close() }

    let response = try await buildServer.buildTargets(request: WorkspaceBuildTargetsRequest())
    let names = response.targets.map { $0.displayName ?? "?" }
    let frameworkTarget = try XCTUnwrap(
      response.targets.first { $0.displayName == "Framework" },
      "expected a project-referenced Framework target, got \(names)"
    )
    XCTAssertFalse(
      frameworkTarget.tags.contains(.dependency),
      "expected project-referenced Framework to NOT be tagged .dependency, got \(frameworkTarget.tags)"
    )
  }
```

- [ ] **Step 2: テストが通ることを確認(RED→GREEN の確認)**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeBuildServerTests/testProjectReferencedTargetIsNotTaggedDependency`
Expected: PASS。

RED の証明(任意・推奨): Task 4 の `rootProjectPaths()` 配線を一時的に stash(`git stash push -- Sources/BuildServerIntegration/XcodeBuildServer.swift` ではなく、`expandedRootProjects` 呼び出しを `Set(seeds 相当)` に戻す)とこのテストが FAIL することを確認 → 戻す。

- [ ] **Step 3: コミット**

```bash
git add Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift
git commit -m "test(BuildServerIntegration): project-referenced target not tagged .dependency

Task: MyApp.xcodeproj が project reference する Framework のターゲットが .dependency に
ならないことの統合テスト(実 SwiftBuild + Xcode 26.4)。RED→GREEN を確認。

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 7: 回帰・フォーマット・DoD 確認

**Files:**
- Modify(任意): `docs/superpowers/specs/2026-05-28-xcode-project-reference-resolution-design.md`(DoD チェック)

- [ ] **Step 1: SPM パッケージが引き続き `.dependency` であることを確認(最重要回帰)**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter XcodeBuildServerTests/testPackageDependencyTargetIsTaggedDependency`
Expected: PASS(`MyLib` が `.dependency`、`MyApp` は非 `.dependency`)。project reference 展開は SPM を含めないことの証明。

- [ ] **Step 2: BuildServerIntegrationTests 全体を実行(非回帰)**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter BuildServerIntegrationTests 2>&1 | tail -30`

> 注意([[verify-test-exit-code]]): `| tail` は終了コードを隠す。必ず別途 `echo "exit: ${PIPESTATUS[0]}"`(zsh は `${pipestatus[1]}`)で終了コードを確認するか、`tail` なしで再実行する。

Expected: 0 失敗。既存 138(XCTest)+ 29(Swift Testing)に本作業の追加分が乗る。

- [ ] **Step 3: フォーマット lint(変更なしであること)**

Run: `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift format lint --strict Sources/BuildServerIntegration/XcodeProject.swift Sources/BuildServerIntegration/XcodeBuildServer.swift Sources/SKTestSupport/XcodeTestProject.swift Tests/BuildServerIntegrationTests/XcodeProjectTests.swift Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift`
Expected: 出力なし(lint 通過)。

- [ ] **Step 4: 最終コミット(必要時)**

フォーマット差分が残っていれば:

```bash
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift format -ipr .
git add -A
git commit -m "style: swift format for Xcode project-reference resolution

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

完了後、`finishing-a-development-branch` でローカルマージ方針を確認(push / PR はしない — [[no-push-no-pr-sourcekit-lsp]])。

---

## Definition of Done(spec より)

- [ ] `XcodeProject.projectReferences` が pbxproj から project reference 先を解決(`<group>`/`SOURCE_ROOT`/`<absolute>`/ネストグループ/dedupe/不正データ)。
- [ ] `rootProjectPaths()` がシードから project reference を推移展開し、存在する `.xcodeproj` のみを循環なく加える。
- [ ] project reference された `.xcodeproj` のターゲットに `.dependency` タグが付かない(統合テストで実証)。
- [ ] SwiftPM パッケージは引き続き `.dependency`(`testPackageDependencyTargetIsTaggedDependency` 回帰)。
- [ ] `XcodeProject` は `import SwiftBuild` を持たない。
- [ ] `XcodeProjectTests` が全環境で通過。
- [ ] 既存 `BuildServerIntegrationTests` が非回帰で通過。
