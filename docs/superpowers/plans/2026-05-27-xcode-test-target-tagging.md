# Xcode Test-Target Tagging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `XcodeBuildServer` tag test targets with `BuildTargetTag.test` so SourceKit-LSP test discovery (`workspace/tests`, `textDocument/tests`) works for Xcode projects.

**Architecture:** `SwiftBuildSession.targets()` evaluates each target's `PRODUCT_TYPE` build setting (same macro-evaluation pattern already used for `SUPPORTED_PLATFORMS`) and stores an `isTestTarget` flag on `XcodeTarget`. `XcodeBuildServer.buildTargets()` maps that flag onto `BuildTarget.tags`. A pure classifier `isTestProductType(_:)` does the unit-test / UI-testing identifier check and is unit-tested in isolation.

**Tech Stack:** Swift, SwiftBuild (SWBBuildServiceSession), BuildServerProtocol, XCTest. Build/test via `DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test`.

**Spec:** `docs/superpowers/specs/2026-05-27-xcode-test-target-tagging-design.md`

---

## File Structure

- `Sources/BuildServerIntegration/SwiftBuildSession.swift` — add `XcodeTarget.isTestTarget`, the pure `isTestProductType(_:)` classifier, the `isTestTarget(forTargetGUID:)` macro-evaluation helper, and wire it into `targets()`.
- `Sources/BuildServerIntegration/XcodeBuildServer.swift` — emit `.test` tag from `buildTargets()`.
- `Sources/SKTestSupport/XcodeTestProject.swift` — add a `.appWithUnitTestTarget` fixture `Kind` + validated `project.pbxproj` template.
- `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift` — unit tests for `isTestProductType(_:)` and an end-to-end integration test asserting the `.test` tag.

All four files already exist; every change is a modification. All new tests live inside the existing `#if !NO_SWIFTPM_DEPENDENCY` block (lines 29–440 of the test file).

---

## Task 1: Pure `isTestProductType(_:)` classifier

**Files:**
- Modify: `Sources/BuildServerIntegration/SwiftBuildSession.swift` (add a `package static func` on `SwiftBuildSession`)
- Test: `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift` (new unit tests)

- [ ] **Step 1: Write the failing unit tests**

Add this block to `XcodeBuildServerTests.swift` immediately after the `// MARK: - resolveScheme decision logic` tests (after `testResolveSchemeNoKnownTargetsWhenFileNamesDoNotMatch`, around line 181), still inside the `#if !NO_SWIFTPM_DEPENDENCY` block:

```swift
  // MARK: - isTestProductType classification

  func testUnitTestProductTypeIsTest() {
    XCTAssertTrue(SwiftBuildSession.isTestProductType("com.apple.product-type.bundle.unit-test"))
  }

  func testUITestingProductTypeIsTest() {
    XCTAssertTrue(SwiftBuildSession.isTestProductType("com.apple.product-type.bundle.ui-testing"))
  }

  func testApplicationProductTypeIsNotTest() {
    XCTAssertFalse(SwiftBuildSession.isTestProductType("com.apple.product-type.application"))
  }

  func testFrameworkProductTypeIsNotTest() {
    XCTAssertFalse(SwiftBuildSession.isTestProductType("com.apple.product-type.framework"))
  }

  func testEmptyProductTypeIsNotTest() {
    XCTAssertFalse(SwiftBuildSession.isTestProductType(""))
  }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer \
  swift test --filter "XcodeBuildServerTests/testUnitTestProductTypeIsTest"
```
Expected: compile failure — `type 'SwiftBuildSession' has no member 'isTestProductType'`.

- [ ] **Step 3: Add the classifier**

In `Sources/BuildServerIntegration/SwiftBuildSession.swift`, inside the `SwiftBuildSession` actor in the `// MARK: Helpers` section (after the `private func makeBuildRequest` declaration is fine; placement is not significant), add:

```swift
  /// Whether a `PRODUCT_TYPE` identifier denotes a test bundle (unit-test or UI-testing).
  ///
  /// `package` (not `private`) so it is unit-testable from `BuildServerIntegrationTests`; it
  /// touches no `SwiftBuild` types.
  package static func isTestProductType(_ identifier: String) -> Bool {
    identifier == "com.apple.product-type.bundle.unit-test"
      || identifier == "com.apple.product-type.bundle.ui-testing"
  }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer \
  swift test --filter "XcodeBuildServerTests/test.*ProductType"
```
Expected: 5 tests pass.

- [ ] **Step 5: Lint the changed files**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer \
  swift format lint --strict \
  Sources/BuildServerIntegration/SwiftBuildSession.swift \
  Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift
```
Expected: no output (clean).

- [ ] **Step 6: Commit**

```bash
git add Sources/BuildServerIntegration/SwiftBuildSession.swift \
        Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift
git commit -m "$(cat <<'EOF'
feat(BuildServerIntegration): isTestProductType classifier

Pure classifier mapping a PRODUCT_TYPE identifier (unit-test / ui-testing)
to a test-bundle bool, unit-tested in isolation. Used next to tag Xcode
test targets so SourceKit-LSP test discovery works for Xcode projects.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `.appWithUnitTestTarget` test fixture

**Files:**
- Modify: `Sources/SKTestSupport/XcodeTestProject.swift`

This task adds a fixture project with two targets: a macOS command-line tool `MyApp` (non-test) and a unit-test bundle `MyAppTests` (`com.apple.product-type.bundle.unit-test`). It is test infrastructure, so its "test" is the Xcode-tooling verification gate in Step 4 rather than an XCTest case.

- [ ] **Step 1: Add the `Kind` case and update doc comments**

In the class doc comment (around line 18–20), extend the kinds description by appending this sentence to the existing paragraph:

```
/// `.appWithUnitTestTarget` produces two targets: a macOS command-line tool `MyApp` (with `main.swift`)
/// and a unit-test bundle `MyAppTests` (`com.apple.product-type.bundle.unit-test`, with
/// `MyAppTests/MyAppTests.swift`).
```

In the `Kind` enum (after the `case appWithFrameworkDependency` line, ~line 48), add:

```swift
    /// A macOS project with a command-line tool `MyApp` and a unit-test bundle `MyAppTests`
    /// (`com.apple.product-type.bundle.unit-test`). Used to verify test-target tagging.
    case appWithUnitTestTarget
```

- [ ] **Step 2: Add the validated `project.pbxproj` template**

Add this static property to `XcodeTestProject` immediately after `appWithFrameworkPbxprojTemplate` (after its closing `"""` near line 738). The `MyApp` objects are copied verbatim from the verified `pbxprojTemplate`; the `C1…` objects add the unit-test bundle.

> **Verification gate (do this before relying on the template):** Materialize the template to a scratch project and confirm all three checks pass:
> ```bash
> mkdir -p /tmp/skxc/MyApp.xcodeproj
> # paste the template body (between the triple quotes) into this file:
> $EDITOR /tmp/skxc/MyApp.xcodeproj/project.pbxproj
> plutil -lint /tmp/skxc/MyApp.xcodeproj/project.pbxproj
> DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer xcodebuild -list -project /tmp/skxc/MyApp.xcodeproj
> DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer xcodebuild -dumpPIF -project /tmp/skxc/MyApp.xcodeproj >/dev/null && echo "PIF OK"
> ```
> Expected: `plutil` prints `OK`; `-list` shows targets `MyApp` and `MyAppTests`; `-dumpPIF` prints `PIF OK`. If `-dumpPIF` reports a missing build setting on the test bundle, add exactly what it names to the `C1…F4`/`C1…F5` configs (do not add a `TEST_HOST`/`BUNDLE_LOADER` — this is an unhosted logic-test bundle) and re-run until all three pass. Then freeze the exact bytes that passed as the template.

```swift
  /// The validated `project.pbxproj` template for a macOS project named `MyApp` with two targets: a
  /// command-line tool `MyApp` (`com.apple.product-type.tool`, source `main.swift`) and an unhosted
  /// unit-test bundle `MyAppTests` (`com.apple.product-type.bundle.unit-test`, source
  /// `MyAppTests/MyAppTests.swift`).
  ///
  /// This content is byte-identical to a `project.pbxproj` that was verified with
  /// `xcodebuild -list`, `xcodebuild -dumpPIF`, and `plutil -lint` using Xcode 26.4 (objectVersion 56).
  ///
  /// - Important: The leading indentation of the lines below uses tabs, matching what Xcode writes. The closing
  ///   delimiter of the multi-line string literal is placed at column zero so that Swift does not strip the leading
  ///   tabs from the embedded content.
  // swift-format-ignore
  package static let appWithUnitTestPbxprojTemplate: String = """
// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 56;
	objects = {

/* Begin PBXBuildFile section */
		A100000000000000000000B1 /* main.swift in Sources */ = {isa = PBXBuildFile; fileRef = A100000000000000000000A1 /* main.swift */; };
		C100000000000000000000B1 /* MyAppTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = C100000000000000000000A1 /* MyAppTests.swift */; };
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
		A100000000000000000000A1 /* main.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = main.swift; sourceTree = "<group>"; };
		A100000000000000000000A2 /* MyApp */ = {isa = PBXFileReference; explicitFileType = "compiled.mach-o.executable"; includeInIndex = 0; path = MyApp; sourceTree = BUILT_PRODUCTS_DIR; };
		C100000000000000000000A1 /* MyAppTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MyAppTests.swift; sourceTree = "<group>"; };
		C100000000000000000000A2 /* MyAppTests.xctest */ = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = MyAppTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
		A100000000000000000000C1 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
		C100000000000000000000C1 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		A100000000000000000000D1 = {
			isa = PBXGroup;
			children = (
				A100000000000000000000A1 /* main.swift */,
				C100000000000000000000D3 /* MyAppTests */,
				A100000000000000000000D2 /* Products */,
			);
			sourceTree = "<group>";
		};
		A100000000000000000000D2 /* Products */ = {
			isa = PBXGroup;
			children = (
				A100000000000000000000A2 /* MyApp */,
				C100000000000000000000A2 /* MyAppTests.xctest */,
			);
			name = Products;
			sourceTree = "<group>";
		};
		C100000000000000000000D3 /* MyAppTests */ = {
			isa = PBXGroup;
			children = (
				C100000000000000000000A1 /* MyAppTests.swift */,
			);
			path = MyAppTests;
			sourceTree = "<group>";
		};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		A100000000000000000000E1 /* MyApp */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = A100000000000000000000F1 /* Build configuration list for PBXNativeTarget "MyApp" */;
			buildPhases = (
				A100000000000000000000C2 /* Sources */,
				A100000000000000000000C1 /* Frameworks */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = MyApp;
			productName = MyApp;
			productReference = A100000000000000000000A2 /* MyApp */;
			productType = "com.apple.product-type.tool";
		};
		C100000000000000000000E1 /* MyAppTests */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = C100000000000000000000F1 /* Build configuration list for PBXNativeTarget "MyAppTests" */;
			buildPhases = (
				C100000000000000000000C2 /* Sources */,
				C100000000000000000000C1 /* Frameworks */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = MyAppTests;
			productName = MyAppTests;
			productReference = C100000000000000000000A2 /* MyAppTests.xctest */;
			productType = "com.apple.product-type.bundle.unit-test";
		};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		A100000000000000000000B0 /* Project object */ = {
			isa = PBXProject;
			attributes = {
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 2640;
				LastUpgradeCheck = 2640;
				TargetAttributes = {
					A100000000000000000000E1 = {
						CreatedOnToolsVersion = 26.4;
					};
					C100000000000000000000E1 = {
						CreatedOnToolsVersion = 26.4;
					};
				};
			};
			buildConfigurationList = A100000000000000000000F0 /* Build configuration list for PBXProject "MyApp" */;
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = A100000000000000000000D1;
			productRefGroup = A100000000000000000000D2 /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				A100000000000000000000E1 /* MyApp */,
				C100000000000000000000E1 /* MyAppTests */,
			);
		};
/* End PBXProject section */

/* Begin PBXSourcesBuildPhase section */
		A100000000000000000000C2 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				A100000000000000000000B1 /* main.swift in Sources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
		C100000000000000000000C2 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				C100000000000000000000B1 /* MyAppTests.swift in Sources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		A100000000000000000000F2 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_OBJC_ARC = YES;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				GCC_NO_COMMON_BLOCKS = YES;
				MACOSX_DEPLOYMENT_TARGET = 13.0;
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = macosx;
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
				SWIFT_VERSION = 5.0;
			};
			name = Debug;
		};
		A100000000000000000000F3 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_OBJC_ARC = YES;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				GCC_NO_COMMON_BLOCKS = YES;
				MACOSX_DEPLOYMENT_TARGET = 13.0;
				SDKROOT = macosx;
				SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_VERSION = 5.0;
			};
			name = Release;
		};
		A100000000000000000000F4 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_VERSION = 5.0;
			};
			name = Debug;
		};
		A100000000000000000000F5 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_VERSION = 5.0;
			};
			name = Release;
		};
		C100000000000000000000F4 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				GENERATE_INFOPLIST_FILE = YES;
				PRODUCT_BUNDLE_IDENTIFIER = com.example.MyAppTests;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_VERSION = 5.0;
			};
			name = Debug;
		};
		C100000000000000000000F5 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				GENERATE_INFOPLIST_FILE = YES;
				PRODUCT_BUNDLE_IDENTIFIER = com.example.MyAppTests;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_VERSION = 5.0;
			};
			name = Release;
		};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		A100000000000000000000F0 /* Build configuration list for PBXProject "MyApp" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				A100000000000000000000F2 /* Debug */,
				A100000000000000000000F3 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
		A100000000000000000000F1 /* Build configuration list for PBXNativeTarget "MyApp" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				A100000000000000000000F4 /* Debug */,
				A100000000000000000000F5 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
		C100000000000000000000F1 /* Build configuration list for PBXNativeTarget "MyAppTests" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				C100000000000000000000F4 /* Debug */,
				C100000000000000000000F5 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
/* End XCConfigurationList section */
	};
	rootObject = A100000000000000000000B0 /* Project object */;
}

"""
```

- [ ] **Step 3: Wire the new kind into `init`**

In `init(kind:sourceContents:fileManager:)`:

In the `sourceFileURL` switch (~line 767), add `.appWithUnitTestTarget` to the root-`main.swift` branch:
```swift
    case .macOSCommandLineTool, .iOSApp, .appWithUnitTestTarget:
      self.sourceFileURL = root.appendingPathComponent("main.swift", isDirectory: false)
```

In the template switch (~line 779), add:
```swift
    case .appWithUnitTestTarget: template = Self.appWithUnitTestPbxprojTemplate
```

After the existing `if case .appWithFrameworkDependency = kind { … }` block (~line 806), add the test-source writer:
```swift
    if case .appWithUnitTestTarget = kind {
      let testSourceURL =
        root
        .appendingPathComponent("MyAppTests", isDirectory: true)
        .appendingPathComponent("MyAppTests.swift", isDirectory: false)
      try fileManager.createDirectory(
        at: testSourceURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try "import XCTest\n\nfinal class MyAppTests: XCTestCase {\n  func testExample() throws {}\n}\n"
        .write(to: testSourceURL, atomically: true, encoding: .utf8)
    }
```

- [ ] **Step 4: Verify the fixture builds and dumps**

After completing the verification gate in Step 2, confirm the package still compiles:
```bash
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift build --target SKTestSupport
```
Expected: build succeeds.

- [ ] **Step 5: Lint**

```bash
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer \
  swift format lint --strict Sources/SKTestSupport/XcodeTestProject.swift
```
Expected: no output. (The `// swift-format-ignore` on the template suppresses formatting of the embedded pbxproj.)

- [ ] **Step 6: Commit**

```bash
git add Sources/SKTestSupport/XcodeTestProject.swift
git commit -m "$(cat <<'EOF'
test(SKTestSupport): appWithUnitTestTarget Xcode fixture

Adds a fixture with a macOS tool target and an unhosted unit-test bundle
(com.apple.product-type.bundle.unit-test), verified with xcodebuild -list,
-dumpPIF and plutil -lint (Xcode 26.4). Used to test test-target tagging.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Failing integration test for the `.test` tag

**Files:**
- Test: `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift`

This test goes through `XcodeBuildServer.buildTargets()`, which already compiles. It fails (red) today because `buildTargets()` returns `tags: []` for every target. Task 4 makes it pass.

- [ ] **Step 1: Write the failing integration test**

Add this test to `XcodeBuildServerTests.swift` after `testIOSTargetInfersSimulatorDestination` (before the final `#endif` at line 440), inside the existing `#if !NO_SWIFTPM_DEPENDENCY` block:

```swift
  /// Test 5: a unit-test target is tagged `.test` while a non-test target is not. This is what
  /// drives `mayContainTests`, and therefore SourceKit-LSP test discovery, for Xcode projects.
  func testTestTargetIsTaggedAsTest() async throws {
    try skipUnlessXcodeAvailable()

    let project = try XcodeTestProject(kind: .appWithUnitTestTarget, sourceContents: "print(\"hi\")\n")
    defer { project.keepAlive() }

    let buildServer = try await XcodeBuildServer(
      projectRoot: project.projectRoot,
      containerPath: project.xcodeprojURL,
      toolchainRegistry: .forTesting,
      options: SourceKitLSPOptions(),
      connectionToSourceKitLSP: LocalConnection(receiverName: "Dummy SourceKit-LSP")
    )
    addTeardownBlock { await buildServer.close() }

    let response = try await buildServer.buildTargets(request: WorkspaceBuildTargetsRequest())
    let testTarget = try XCTUnwrap(
      response.targets.first { $0.displayName == "MyAppTests" },
      "expected a MyAppTests target, got: \(response.targets.map(\.displayName))"
    )
    let appTarget = try XCTUnwrap(
      response.targets.first { $0.displayName == "MyApp" },
      "expected a MyApp target, got: \(response.targets.map(\.displayName))"
    )
    XCTAssertTrue(
      testTarget.tags.contains(.test),
      "expected MyAppTests to be tagged .test, got tags: \(testTarget.tags)"
    )
    XCTAssertFalse(
      appTarget.tags.contains(.test),
      "expected MyApp (non-test) to have no .test tag, got tags: \(appTarget.tags)"
    )
  }
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer \
  swift test --filter "XcodeBuildServerTests/testTestTargetIsTaggedAsTest"
```
Expected: the test runs (Xcode present) and FAILS on `XCTAssertTrue(testTarget.tags.contains(.test))` — `buildTargets()` currently emits `tags: []`. (If `xcodebuild` is unavailable the test is skipped; in that case rely on Task 1's unit tests and proceed — the assertion logic is still correct.)

- [ ] **Step 3: Commit the failing test**

```bash
git add Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift
git commit -m "$(cat <<'EOF'
test(BuildServerIntegration): assert .test tag on Xcode test target (red)

Failing integration test: a unit-test target must be tagged .test and a
non-test target must not. Drives mayContainTests / test discovery. Made to
pass in the following commit.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Tag test targets in `XcodeBuildServer`

**Files:**
- Modify: `Sources/BuildServerIntegration/SwiftBuildSession.swift` (`XcodeTarget` field, `isTestTarget(forTargetGUID:)`, `targets()` wiring)
- Modify: `Sources/BuildServerIntegration/XcodeBuildServer.swift:146` (emit `.test` tag)

- [ ] **Step 1: Add `isTestTarget` to `XcodeTarget`**

In `Sources/BuildServerIntegration/SwiftBuildSession.swift`, replace the `XcodeTarget` struct (lines 26–37) with:

```swift
package struct XcodeTarget: Sendable, Equatable {
  package var guid: String
  package var name: String
  /// Supported platform names (e.g. "macosx", "iphonesimulator"). Empty if unknown.
  package var platforms: [String]
  /// Whether this target builds a test bundle (unit-test or UI-testing product type).
  package var isTestTarget: Bool

  // `isTestTarget` defaults to `false` so existing call sites that don't care about it (e.g. the
  // `resolveScheme` unit tests in `XcodeBuildServerTests.swift`) compile unchanged.
  package init(guid: String, name: String, platforms: [String], isTestTarget: Bool = false) {
    self.guid = guid
    self.name = name
    self.platforms = platforms
    self.isTestTarget = isTestTarget
  }
}
```

- [ ] **Step 2: Add the `isTestTarget(forTargetGUID:)` helper and wire `targets()`**

In the same file, replace `targets()` (lines 133–143) with:

```swift
  /// All targets in the loaded workspace.
  package func targets() async throws -> [XcodeTarget] {
    let info = try await session.workspaceInfo()
    var result: [XcodeTarget] = []
    for targetInfo in info.targetInfos {
      let platforms = await supportedPlatforms(forTargetGUID: targetInfo.guid)
      let isTest = await isTestTarget(forTargetGUID: targetInfo.guid)
      result.append(
        XcodeTarget(guid: targetInfo.guid, name: targetInfo.targetName, platforms: platforms, isTestTarget: isTest)
      )
    }
    return result
  }
```

Immediately after the `supportedPlatforms(forTargetGUID:)` method (ends at line 179), add:

```swift
  /// Evaluate the target's `PRODUCT_TYPE` build setting and classify it as a test bundle or not.
  ///
  /// `PRODUCT_TYPE` does not depend on the active run destination, so this evaluates with build
  /// parameters that set only the configuration. Returns `false` on failure so that an unevaluable
  /// target is treated as a non-test target rather than failing target enumeration.
  private func isTestTarget(forTargetGUID guid: String) async -> Bool {
    var params = SWBBuildParameters()
    params.configurationName = configuration
    let identifier = await orLog("Evaluating PRODUCT_TYPE for target \(guid)") {
      try await session.evaluateMacroAsString(
        "PRODUCT_TYPE",
        level: .target(guid),
        buildParameters: params,
        overrides: [:]
      )
    }
    return Self.isTestProductType(identifier ?? "")
  }
```

- [ ] **Step 3: Emit the `.test` tag in `XcodeBuildServer.buildTargets()`**

In `Sources/BuildServerIntegration/XcodeBuildServer.swift`, in `buildTargets()` (line 146), change:

```swift
        tags: [],
```
to:
```swift
        tags: target.isTestTarget ? [.test] : [],
```

- [ ] **Step 4: Run the integration test to verify it passes**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer \
  swift test --filter "XcodeBuildServerTests/testTestTargetIsTaggedAsTest"
```
Expected: PASS. (Skipped only if `xcodebuild` is unavailable.)

- [ ] **Step 5: Run the full BuildServerIntegration suite for non-regression**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer \
  swift test --filter "XcodeBuildServerTests"
```
Expected: all tests pass (existing `resolveScheme` / `preferredPlatform` / integration tests unchanged; `isTestProductType` + new integration test pass).

- [ ] **Step 6: Lint the changed files**

```bash
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer \
  swift format lint --strict \
  Sources/BuildServerIntegration/SwiftBuildSession.swift \
  Sources/BuildServerIntegration/XcodeBuildServer.swift
```
Expected: no output.

- [ ] **Step 7: Commit**

```bash
git add Sources/BuildServerIntegration/SwiftBuildSession.swift \
        Sources/BuildServerIntegration/XcodeBuildServer.swift
git commit -m "$(cat <<'EOF'
feat(BuildServerIntegration): tag Xcode test targets with .test

SwiftBuildSession.targets() evaluates each target's PRODUCT_TYPE and stores
isTestTarget on XcodeTarget; XcodeBuildServer.buildTargets() maps it to the
BuildTarget .test tag. This makes mayContainTests true for Xcode test
targets so workspace/tests and textDocument/tests discover their tests.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Definition of Done

- `SwiftBuildSession.isTestProductType(_:)` unit tests pass in every environment.
- `SwiftBuildSession.targets()` populates `XcodeTarget.isTestTarget` from `PRODUCT_TYPE`.
- `XcodeBuildServer.buildTargets()` tags test targets `.test` and leaves non-test targets untagged.
- The `testTestTargetIsTaggedAsTest` integration test passes on macOS with Xcode 26.4.
- The existing `XcodeBuildServerTests` suite passes with no regressions.
- `swift format lint --strict` is clean on all changed Swift files.
