# Xcode Platform Inference Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Infer each Xcode target's run destination from its `SUPPORTED_PLATFORMS` so iOS/tvOS/watchOS targets get correct `-sdk`/`-target` compiler arguments instead of always falling back to macOS when `xcode.destination` is unspecified.

**Architecture:** `SwiftBuildSession.targets()` evaluates the `SUPPORTED_PLATFORMS` build setting per target via SwiftBuild macro evaluation (`evaluateMacroAsStringList`, target level, no run destination needed) and stores the result in `XcodeTarget.platforms`. A pure selection function `preferredPlatform(forSupportedPlatforms:)` then picks a platform name with a fixed priority (macOS first; within a non-macOS family prefer the simulator; device last), which maps to a `SWBRunDestinationInfo`.

**Tech Stack:** Swift, SwiftBuild (`import SwiftBuild`), XCTest. All new code lives behind `#if !NO_SWIFTPM_DEPENDENCY`.

**Spec:** `docs/superpowers/specs/2026-05-25-xcode-platform-inference-design.md`

---

## Build / Test Environment

This work requires macOS + Xcode 26.4. Run all `swift` commands with the Xcode 26.4 developer dir. Do **not** set `SWIFTCI_USE_LOCAL_DEPS=1` (sibling checkouts are absent; the build uses resolved remote dependencies).

```bash
export DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer
```

Integration tests (`#if !NO_SWIFTPM_DEPENDENCY`) call into a real SwiftBuild session backed by `xcrun xcodebuild`; they self-skip via `skipUnlessXcodeAvailable()` when `xcodebuild` is unavailable. The pure unit tests in Task 1 run everywhere.

---

## File Structure

- **Modify** `Sources/BuildServerIntegration/SwiftBuildSession.swift`
  - `targets()` — populate `XcodeTarget.platforms` from `SUPPORTED_PLATFORMS`.
  - Add `supportedPlatforms(forTargetGUID:)` private helper (macro evaluation).
  - Add `preferredPlatform(forSupportedPlatforms:)` — `package static`, pure selection logic.
  - Rewrite `runDestination(forPlatform:)` to take a non-optional platform name and add the `macosx` case (removes the TODO).
  - Update `runDestination(for:)` to use the two helpers.
- **Modify** `Sources/SKTestSupport/XcodeTestProject.swift`
  - Add `Kind` enum (`.macOSCommandLineTool` default, `.iOSApp`) and a `kind:` init parameter.
  - Add `iOSAppPbxprojTemplate` (validated iOS app `project.pbxproj`).
- **Modify** `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift`
  - Add `preferredPlatform` unit tests (inside the existing `#if !NO_SWIFTPM_DEPENDENCY` block).
  - Add two Xcode-gated integration tests (macOS reports `macosx`; iOS infers simulator).

All test additions go into the **existing** `#if !NO_SWIFTPM_DEPENDENCY` block in `XcodeBuildServerTests.swift` (lines 29–184) to reuse `skipUnlessXcodeAvailable()` and `temporaryDirectory()`.

---

## Task 1: Platform selection logic (pure, unit-tested)

**Files:**
- Modify: `Sources/BuildServerIntegration/SwiftBuildSession.swift:310-337`
- Test: `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift` (inside existing `#if !NO_SWIFTPM_DEPENDENCY` block)

- [ ] **Step 1: Write the failing unit tests**

Add these methods inside the `#if !NO_SWIFTPM_DEPENDENCY` block in `XcodeBuildServerTests.swift` (e.g. right after `testSwiftPMProjectNotClaimedByXcode`):

```swift
// MARK: - preferredPlatform selection logic

func testPreferredPlatformMacOnly() {
  XCTAssertEqual(SwiftBuildSession.preferredPlatform(forSupportedPlatforms: ["macosx"]), "macosx")
}

func testPreferredPlatformIOSPrefersSimulator() {
  XCTAssertEqual(
    SwiftBuildSession.preferredPlatform(forSupportedPlatforms: ["iphoneos", "iphonesimulator"]),
    "iphonesimulator"
  )
}

func testPreferredPlatformIOSDeviceOnly() {
  XCTAssertEqual(SwiftBuildSession.preferredPlatform(forSupportedPlatforms: ["iphoneos"]), "iphoneos")
}

func testPreferredPlatformTVOSPrefersSimulator() {
  XCTAssertEqual(
    SwiftBuildSession.preferredPlatform(forSupportedPlatforms: ["appletvos", "appletvsimulator"]),
    "appletvsimulator"
  )
}

func testPreferredPlatformWatchOSPrefersSimulator() {
  XCTAssertEqual(
    SwiftBuildSession.preferredPlatform(forSupportedPlatforms: ["watchos", "watchsimulator"]),
    "watchsimulator"
  )
}

func testPreferredPlatformCrossFamilyPrefersMacOS() {
  XCTAssertEqual(
    SwiftBuildSession.preferredPlatform(forSupportedPlatforms: ["macosx", "iphoneos", "iphonesimulator"]),
    "macosx"
  )
}

func testPreferredPlatformEmptyFallsBackToMacOS() {
  XCTAssertEqual(SwiftBuildSession.preferredPlatform(forSupportedPlatforms: []), "macosx")
}
```

- [ ] **Step 2: Run the tests to verify they fail to compile**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer \
  swift test --filter BuildServerIntegrationTests.XcodeBuildServerTests/testPreferredPlatform
```
Expected: compile error — `type 'SwiftBuildSession' has no member 'preferredPlatform'`.

- [ ] **Step 3: Implement the selection logic**

In `SwiftBuildSession.swift`, replace the existing `runDestination(for:)` and `runDestination(forPlatform:)` (currently `:310-337`) with:

```swift
  private func runDestination(for target: XcodeTarget) -> SWBRunDestinationInfo {
    if let destinationOverride, let parsed = Self.parseDestination(destinationOverride) {
      return parsed
    }
    return Self.runDestination(forPlatform: Self.preferredPlatform(forSupportedPlatforms: target.platforms))
  }

  /// Choose the preferred platform name from a target's supported platforms for headless indexing.
  ///
  /// Priority: macOS first (host-native, always available, needs no simulator runtime); then each
  /// non-macOS family's simulator (no code signing / device provisioning required for indexing);
  /// then devices. Falls back to "macosx" when nothing is recognized (e.g. an empty list).
  package static func preferredPlatform(forSupportedPlatforms supported: [String]) -> String {
    let set = Set(supported)
    let order = [
      "macosx",
      "iphonesimulator", "appletvsimulator", "watchsimulator",
      "iphoneos", "appletvos", "watchos",
    ]
    return order.first { set.contains($0) } ?? "macosx"
  }

  /// Map a platform name to a run destination. Unknown names fall back to macOS.
  static func runDestination(forPlatform platform: String) -> SWBRunDestinationInfo {
    switch platform {
    case "iphonesimulator":
      return .iOSSimulator
    case "iphoneos":
      return .iOS
    case "appletvsimulator":
      return .tvOSSimulator
    case "appletvos":
      return .tvOS
    case "watchsimulator":
      return .watchOSSimulator
    case "watchos":
      return .watchOS
    case "macosx":
      return .macOS
    default:
      return .macOS
    }
  }
```

This removes the `// TODO: Richer platform inference...` comment that was in the old `default` case.

- [ ] **Step 4: Run the unit tests to verify they pass**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer \
  swift test --filter BuildServerIntegrationTests.XcodeBuildServerTests/testPreferredPlatform
```
Expected: 7 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/BuildServerIntegration/SwiftBuildSession.swift \
        Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift
git commit -m "feat(BuildServerIntegration): platform selection from supported platforms

Task: XcodeBuildServer platform inference. Add preferredPlatform(forSupportedPlatforms:)
choosing macOS first, then simulators, then devices, and route runDestination through it.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 2: Populate `XcodeTarget.platforms` from `SUPPORTED_PLATFORMS`

**Files:**
- Modify: `Sources/BuildServerIntegration/SwiftBuildSession.swift:133-140`
- Test: `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift` (inside existing `#if !NO_SWIFTPM_DEPENDENCY` block)

- [ ] **Step 1: Write the failing integration test**

Add inside the `#if !NO_SWIFTPM_DEPENDENCY` block of `XcodeBuildServerTests.swift`, in the integration-tests section (after `testPreparePopulatesIndexStore`):

```swift
  /// Test 3: a real macOS target reports `macosx` among its supported platforms, proving that
  /// `SUPPORTED_PLATFORMS` macro evaluation works end-to-end against a real SwiftBuild session.
  func testMacOSTargetReportsMacosxPlatform() async throws {
    try skipUnlessXcodeAvailable()

    let project = try XcodeTestProject(sourceContents: "print(\"hello\")\n")
    defer { project.keepAlive() }

    let session = try await SwiftBuildSession(
      containerPath: project.xcodeprojURL,
      configuration: "Debug",
      destinationOverride: nil,
      derivedDataPath: project.projectRoot.appending(component: ".build").appending(component: "sk-xcode")
    )
    addTeardownBlock { await session.close() }

    let targets = try await session.targets()
    XCTAssertTrue(
      targets.contains { $0.platforms.contains("macosx") },
      "expected a target whose supported platforms include macosx, got: \(targets.map(\.platforms))"
    )
  }
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer \
  swift test --filter BuildServerIntegrationTests.XcodeBuildServerTests/testMacOSTargetReportsMacosxPlatform
```
Expected: FAIL — `platforms` is currently always `[]`, so no target contains `macosx`. (If `xcodebuild` is unavailable the test SKIPS instead; this task must be implemented on macOS+Xcode.)

- [ ] **Step 3: Implement platform population**

In `SwiftBuildSession.swift`, replace `targets()` (currently `:132-140`) with:

```swift
  /// All targets in the loaded workspace.
  package func targets() async throws -> [XcodeTarget] {
    let info = try await session.workspaceInfo()
    var result: [XcodeTarget] = []
    for targetInfo in info.targetInfos {
      let platforms = await supportedPlatforms(forTargetGUID: targetInfo.guid)
      result.append(
        XcodeTarget(guid: targetInfo.guid, name: targetInfo.targetName, platforms: platforms)
      )
    }
    return result
  }

  /// Evaluate the target's `SUPPORTED_PLATFORMS` build setting (e.g. `["iphoneos", "iphonesimulator"]`).
  ///
  /// `SUPPORTED_PLATFORMS` does not depend on the active run destination, so this evaluates with build
  /// parameters that set only the configuration. Returns an empty array on failure so that destination
  /// selection falls back to macOS rather than failing target enumeration.
  private func supportedPlatforms(forTargetGUID guid: String) async -> [String] {
    var params = SWBBuildParameters()
    params.configurationName = configuration
    return (try? await session.evaluateMacroAsStringList(
      "SUPPORTED_PLATFORMS",
      level: .target(guid),
      buildParameters: params,
      overrides: [:]
    )) ?? []
  }
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer \
  swift test --filter BuildServerIntegrationTests.XcodeBuildServerTests/testMacOSTargetReportsMacosxPlatform
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/BuildServerIntegration/SwiftBuildSession.swift \
        Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift
git commit -m "feat(BuildServerIntegration): infer target platforms via SUPPORTED_PLATFORMS

Task: XcodeBuildServer platform inference. Evaluate SUPPORTED_PLATFORMS per target through
SwiftBuild macro evaluation so XcodeTarget.platforms reflects the target's real platforms,
enabling correct run-destination selection.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 3: iOS app fixture in `XcodeTestProject`

**Files:**
- Modify: `Sources/SKTestSupport/XcodeTestProject.swift`

- [ ] **Step 1: Add the `Kind` enum and `kind:` init parameter**

In `XcodeTestProject`, add a nested enum (near the top of the class body) and thread it through `init`. Change the `init` signature and the template write.

Add the enum:
```swift
  /// The kind of project to generate.
  package enum Kind: Sendable {
    /// A macOS command-line tool (`com.apple.product-type.tool`, `SDKROOT = macosx`).
    case macOSCommandLineTool
    /// An iOS application (`com.apple.product-type.application`, `SDKROOT = iphoneos`,
    /// `SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"`).
    case iOSApp
  }
```

Change the `init` (currently `:235`) from:
```swift
  package init(sourceContents: String, fileManager: FileManager = .default) throws {
    self.fileManager = fileManager
```
to:
```swift
  package init(kind: Kind = .macOSCommandLineTool, sourceContents: String, fileManager: FileManager = .default) throws {
    self.fileManager = fileManager
```

Inside `init`, replace the single template write (currently `:255-259`):
```swift
    try Self.pbxprojTemplate.write(
      to: xcodeprojURL.appendingPathComponent("project.pbxproj", isDirectory: false),
      atomically: true,
      encoding: .utf8
    )
```
with:
```swift
    let template: String
    switch kind {
    case .macOSCommandLineTool: template = Self.pbxprojTemplate
    case .iOSApp: template = Self.iOSAppPbxprojTemplate
    }
    try template.write(
      to: xcodeprojURL.appendingPathComponent("project.pbxproj", isDirectory: false),
      atomically: true,
      encoding: .utf8
    )
```

(The default value keeps existing call sites — `XcodeTestProject(sourceContents:)` — working unchanged.)

- [ ] **Step 2: Add the iOS app `project.pbxproj` template**

Add this `package static let` next to `pbxprojTemplate` (keep the `// swift-format-ignore` and the column-zero closing delimiter so leading tabs are preserved). This is the macOS template transformed to an iOS application target: product type `application`, product `MyApp.app`, `SDKROOT = iphoneos`, `IPHONEOS_DEPLOYMENT_TARGET`, and an explicit `SUPPORTED_PLATFORMS`.

```swift
  /// The `project.pbxproj` template for an iOS application target named `MyApp` with a single
  /// `main.swift` source file. Must be validated with `xcodebuild -dumpPIF` (see plan Task 3 Step 3).
  // swift-format-ignore
  package static let iOSAppPbxprojTemplate: String = """
// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 56;
	objects = {

/* Begin PBXBuildFile section */
		A100000000000000000000B1 /* main.swift in Sources */ = {isa = PBXBuildFile; fileRef = A100000000000000000000A1 /* main.swift */; };
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
		A100000000000000000000A1 /* main.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = main.swift; sourceTree = "<group>"; };
		A100000000000000000000A2 /* MyApp.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = MyApp.app; sourceTree = BUILT_PRODUCTS_DIR; };
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
		A100000000000000000000C1 /* Frameworks */ = {
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
				A100000000000000000000D2 /* Products */,
			);
			sourceTree = "<group>";
		};
		A100000000000000000000D2 /* Products */ = {
			isa = PBXGroup;
			children = (
				A100000000000000000000A2 /* MyApp.app */,
			);
			name = Products;
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
			productReference = A100000000000000000000A2 /* MyApp.app */;
			productType = "com.apple.product-type.application";
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
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		A100000000000000000000F2 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_OBJC_ARC = YES;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				GCC_NO_COMMON_BLOCKS = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = iphoneos;
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
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				SDKROOT = iphoneos;
				SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_VERSION = 5.0;
			};
			name = Release;
		};
		A100000000000000000000F4 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				GENERATE_INFOPLIST_FILE = YES;
				PRODUCT_BUNDLE_IDENTIFIER = com.example.MyApp;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2";
			};
			name = Debug;
		};
		A100000000000000000000F5 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				GENERATE_INFOPLIST_FILE = YES;
				PRODUCT_BUNDLE_IDENTIFIER = com.example.MyApp;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2";
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
/* End XCConfigurationList section */
	};
	rootObject = A100000000000000000000B0 /* Project object */;
}

"""
```

- [ ] **Step 3: Build, then validate the iOS template with `xcodebuild`**

Build to confirm `XcodeTestProject` still compiles:
```bash
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift build --target SKTestSupport
```
Expected: builds with no errors.

Then confirm `xcodebuild` accepts the template (the same operations SwiftBuild performs on load). Materialize the fixture from the new template and run the validators:

```bash
TMP=$(mktemp -d)
mkdir -p "$TMP/MyApp.xcodeproj"
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer \
  swift -e 'import SKTestSupport; try FileManager.default.removeItem(atPath: CommandLine.arguments[1] + "/MyApp.xcodeproj"); let p = try XcodeTestProject(kind: .iOSApp, sourceContents: "let x = 1\n"); FileManager.default.createFile(atPath: CommandLine.arguments[1] + "/path.txt", contents: p.xcodeprojURL.path.data(using: .utf8))' "$TMP" 2>/dev/null || true
```

If `swift -e` against the package is inconvenient, instead copy `XcodeTestProject.iOSAppPbxprojTemplate`'s content into `"$TMP/MyApp.xcodeproj/project.pbxproj"` by hand. Either way, validate the resulting `project.pbxproj`:

```bash
PROJ="$TMP/MyApp.xcodeproj"
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer plutil -lint "$PROJ/project.pbxproj"
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer xcrun xcodebuild -list -project "$PROJ"
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer xcrun xcodebuild -dumpPIF -project "$PROJ" >/dev/null
```
Expected: `plutil -lint` reports OK; `-list` shows the `MyApp` target with `Debug`/`Release` configurations; `-dumpPIF` exits 0 with no error.

If any command fails, fix the template (most likely a missing/renamed build setting) and re-run until all three pass. The authoritative end-to-end check is Task 4 (its `SwiftBuildSession.init` loads the fixture via `-dumpPIF` and fails loudly on an invalid project); this step isolates fixture problems from test-logic problems.

If the `application` product type proves troublesome under `-dumpPIF` for reasons unrelated to platforms, falling back to `com.apple.product-type.framework` (drop `GENERATE_INFOPLIST_FILE`, `PRODUCT_BUNDLE_IDENTIFIER`, `TARGETED_DEVICE_FAMILY`; product `MyApp.framework`, `explicitFileType = wrapper.framework`) is acceptable — the platform-inference path is identical because it depends only on `SDKROOT`/`SUPPORTED_PLATFORMS`.

- [ ] **Step 4: Commit**

```bash
git add Sources/SKTestSupport/XcodeTestProject.swift
git commit -m "test(SKTestSupport): add iOS app Xcode project fixture

Task: XcodeBuildServer platform inference. Add an iOS application variant to XcodeTestProject
(validated project.pbxproj with SDKROOT=iphoneos and SUPPORTED_PLATFORMS) so platform inference
can be tested against a non-macOS target.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 4: Integration test — iOS target infers a simulator destination

**Files:**
- Test: `Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift` (inside existing `#if !NO_SWIFTPM_DEPENDENCY` block)

- [ ] **Step 1: Write the failing integration test**

Add inside the `#if !NO_SWIFTPM_DEPENDENCY` block, after `testMacOSTargetReportsMacosxPlatform`:

```swift
  /// Test 4: an iOS target reports a simulator platform and, with no destination override, its indexing
  /// compiler arguments reference the iOS Simulator SDK — the direct regression test for the previous
  /// "always fall back to macOS" behavior.
  func testIOSTargetInfersSimulatorDestination() async throws {
    try skipUnlessXcodeAvailable()

    let project = try XcodeTestProject(kind: .iOSApp, sourceContents: "let x = 1\n")
    defer { project.keepAlive() }

    let session = try await SwiftBuildSession(
      containerPath: project.xcodeprojURL,
      configuration: "Debug",
      destinationOverride: nil,
      derivedDataPath: project.projectRoot.appending(component: ".build").appending(component: "sk-xcode")
    )
    addTeardownBlock { await session.close() }

    let targets = try await session.targets()
    let iosTarget = try XCTUnwrap(
      targets.first { $0.platforms.contains("iphonesimulator") },
      "expected a target whose supported platforms include iphonesimulator, got: \(targets.map(\.platforms))"
    )

    let indexingFiles = try await session.indexingFiles(for: iosTarget)
    let args = indexingFiles.flatMap(\.compilerArguments)
    XCTAssertFalse(args.isEmpty, "expected compiler arguments for the iOS target source files")

    // The chosen destination must be the iOS Simulator: either the SDK path mentions iPhoneSimulator,
    // or the `-target` triple is an iOS simulator triple (e.g. arm64-apple-ios17.0-simulator).
    let mentionsIOSSimulator = args.contains {
      $0.contains("iPhoneSimulator") || ($0.contains("-apple-ios") && $0.contains("simulator"))
    }
    XCTAssertTrue(
      mentionsIOSSimulator,
      "expected iOS Simulator SDK/target in compiler arguments, got: \(args)"
    )
  }
```

- [ ] **Step 2: Run the test**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer \
  swift test --filter BuildServerIntegrationTests.XcodeBuildServerTests/testIOSTargetInfersSimulatorDestination
```
Expected: PASS (Tasks 1–3 already implement the behavior and fixture). If it fails on the platform assertion, the iOS fixture's `SUPPORTED_PLATFORMS` is not being read — recheck Task 3 Step 3 validation. If it fails on the SDK assertion, confirm `preferredPlatform` returns `iphonesimulator` for `["iphoneos", "iphonesimulator"]` (Task 1).

- [ ] **Step 3: Commit**

```bash
git add Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift
git commit -m "test(BuildServerIntegration): iOS target infers simulator destination

Task: XcodeBuildServer platform inference. Verify an iOS target's supported platforms include
iphonesimulator and that its indexing compiler arguments reference the iOS Simulator SDK when no
destination override is set.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 5: Full-suite verification and lint

**Files:** none (verification only)

- [ ] **Step 1: Run the full module test suite**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer \
  swift test --filter BuildServerIntegrationTests
```
Expected: all existing tests (93) plus the 7 unit tests and 2 integration tests PASS; nothing regresses.

- [ ] **Step 2: Confirm the TODO is gone**

Run:
```bash
grep -rn "TODO\|FIXME" Sources/BuildServerIntegration/SwiftBuildSession.swift
```
Expected: no output (the platform-inference TODO at the old `:333` is removed).

- [ ] **Step 3: Run swift-format lint**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer \
  swift format lint --strict --recursive \
  Sources/BuildServerIntegration/SwiftBuildSession.swift \
  Sources/SKTestSupport/XcodeTestProject.swift \
  Tests/BuildServerIntegrationTests/XcodeBuildServerTests.swift
```
Expected: no lint diagnostics. (`iOSAppPbxprojTemplate` carries `// swift-format-ignore`, matching the existing `pbxprojTemplate`.) Fix any reported issues and amend the relevant commit.

- [ ] **Step 4: Final commit (only if lint fixes were needed)**

```bash
git add -A
git commit -m "style(BuildServerIntegration): satisfy swift-format lint

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Definition of Done

- `SwiftBuildSession.targets()` returns each target's real supported platforms in `XcodeTarget.platforms`.
- With no `xcode.destination`, iOS/tvOS/watchOS targets resolve to their simulator destination (not macOS); macOS targets remain macOS.
- An explicit `xcode.destination` is still honored first (unchanged `runDestination(for:)` override branch).
- `preferredPlatform(forSupportedPlatforms:)` unit tests pass in all environments.
- On macOS + Xcode, `testMacOSTargetReportsMacosxPlatform` and `testIOSTargetInfersSimulatorDestination` pass.
- The full `BuildServerIntegrationTests` suite passes with no regressions.
- The `SwiftBuildSession.swift` platform-inference TODO is removed.
- swift-format lint is clean.
