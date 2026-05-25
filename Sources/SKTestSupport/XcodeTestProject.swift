//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

package import Foundation

/// A minimal, valid `.xcodeproj` written to a fresh temporary directory on disk.
///
/// The project defines a single macOS command-line tool target named `MyApp` with one Swift source file,
/// `main.swift`. The generated `project.pbxproj` is a hand-crafted template that has been validated to be accepted by
/// `xcodebuild` (`xcodebuild -list`, `xcodebuild -dumpPIF`), which is the operation SwiftBuild performs when loading
/// the project.
///
/// The temporary directory is removed when the `XcodeTestProject` is deinitialized, unless the
/// `SOURCEKIT_LSP_KEEP_TEST_SCRATCH_DIR` environment variable is set.
///
/// This type is pure Foundation and does not depend on SwiftBuild or any toolchain.
package final class XcodeTestProject {
  /// The temporary directory containing the `.xcodeproj` and the Swift source file.
  package let projectRoot: URL

  /// The `MyApp.xcodeproj` bundle inside ``projectRoot``.
  package let xcodeprojURL: URL

  /// The `main.swift` source file inside ``projectRoot``. Its contents are the `sourceContents` passed to ``init``.
  package let sourceFileURL: URL

  private let fileManager: FileManager

  /// The validated `project.pbxproj` template for a macOS command-line tool target named `MyApp` with a single
  /// `main.swift` source file.
  ///
  /// This content is byte-identical to a `project.pbxproj` that was verified with
  /// `xcodebuild -list`, `xcodebuild -dumpPIF`, and `plutil -lint` using Xcode 26.4 (objectVersion 56).
  ///
  /// - Important: The leading indentation of the lines below uses tabs, matching what Xcode writes. The closing
  ///   delimiter of the multi-line string literal is placed at column zero so that Swift does not strip the leading
  ///   tabs from the embedded content.
  // swift-format-ignore
  package static let pbxprojTemplate: String = """
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
		A100000000000000000000A2 /* MyApp */ = {isa = PBXFileReference; explicitFileType = "compiled.mach-o.executable"; includeInIndex = 0; path = MyApp; sourceTree = BUILT_PRODUCTS_DIR; };
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
				A100000000000000000000A2 /* MyApp */,
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
			productReference = A100000000000000000000A2 /* MyApp */;
			productType = "com.apple.product-type.tool";
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

  /// Creates a minimal macOS command-line tool Xcode project on disk in a fresh temporary directory.
  ///
  /// - Parameters:
  ///   - sourceContents: The contents written to `main.swift`.
  ///   - fileManager: The `FileManager` used to create and (on deinit) remove the project. Defaults to `.default`.
  package init(sourceContents: String, fileManager: FileManager = .default) throws {
    self.fileManager = fileManager

    let scratchDirectoriesName = "sourcekit-lsp-test-scratch"
    var uuid = UUID().uuidString[...]
    if let firstDash = uuid.firstIndex(of: "-") {
      uuid = uuid[..<firstDash]
    }
    let root = fileManager.temporaryDirectory
      .appendingPathComponent(scratchDirectoriesName, isDirectory: true)
      .appendingPathComponent("XcodeTestProject-\(uuid)", isDirectory: true)

    try? fileManager.removeItem(at: root)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    self.projectRoot = root
    self.xcodeprojURL = root.appendingPathComponent("MyApp.xcodeproj", isDirectory: true)
    self.sourceFileURL = root.appendingPathComponent("main.swift", isDirectory: false)

    try fileManager.createDirectory(at: xcodeprojURL, withIntermediateDirectories: true)
    try Self.pbxprojTemplate.write(
      to: xcodeprojURL.appendingPathComponent("project.pbxproj", isDirectory: false),
      atomically: true,
      encoding: .utf8
    )
    try sourceContents.write(to: sourceFileURL, atomically: true, encoding: .utf8)
  }

  deinit {
    if cleanScratchDirectories {
      try? fileManager.removeItem(at: projectRoot)
    }
  }

  /// Keeps the project alive until this is called, so the temporary directory is not removed prematurely by the
  /// project being deinitialized.
  package func keepAlive() {
    withExtendedLifetime(self) { _ in }
  }
}
