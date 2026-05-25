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
/// The project layout depends on the ``Kind`` passed to ``init(kind:sourceContents:fileManager:)``.
/// `.macOSCommandLineTool` and `.iOSApp` each produce a single target named `MyApp` with one source file,
/// `main.swift`. `.appWithFrameworkDependency` produces two targets: `App` (a macOS command-line tool with
/// `App/main.swift`) depending on `Framework` (a macOS framework with `Framework/Framework.swift`).
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

  /// The primary Swift source file whose contents are the `sourceContents` passed to ``init``. For
  /// `.macOSCommandLineTool` and `.iOSApp` this is `main.swift` at the project root; for
  /// `.appWithFrameworkDependency` it is `App/main.swift`.
  package let sourceFileURL: URL

  private let fileManager: FileManager

  /// The kind of project to generate.
  package enum Kind: Sendable {
    /// A macOS command-line tool (`com.apple.product-type.tool`, `SDKROOT = macosx`).
    case macOSCommandLineTool
    /// An iOS application (`com.apple.product-type.application`, `SDKROOT = iphoneos`,
    /// `SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"`).
    case iOSApp
    /// A macOS project with an `App` target that depends on a `Framework` target.
    case appWithFrameworkDependency
  }

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

  /// The validated `project.pbxproj` template for an iOS application target named `MyApp` with a single
  /// `main.swift` source file.
  ///
  /// This content is byte-identical to a `project.pbxproj` that was verified with
  /// `xcodebuild -list`, `xcodebuild -dumpPIF`, and `plutil -lint` using Xcode 26.4 (objectVersion 56).
  ///
  /// - Important: The leading indentation of the lines below uses tabs, matching what Xcode writes. The closing
  ///   delimiter of the multi-line string literal is placed at column zero so that Swift does not strip the leading
  ///   tabs from the embedded content.
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

  /// The validated `project.pbxproj` template for a macOS project named `MyApp` containing two targets: a
  /// command-line tool `App` (`com.apple.product-type.tool`) with a single `App/main.swift` source file, and a
  /// framework `Framework` (`com.apple.product-type.framework`) with a single `Framework/Framework.swift` source
  /// file. `App` declares a target dependency on `Framework`, so SwiftBuild's dependency closure (with implicit
  /// dependencies) includes `Framework` whenever `App` is a seed target.
  ///
  /// This content is byte-identical to a `project.pbxproj` that was verified with
  /// `xcodebuild -list`, `xcodebuild -dumpPIF`, and `plutil -lint` using Xcode 26.4 (objectVersion 56).
  ///
  /// - Important: The leading indentation of the lines below uses tabs, matching what Xcode writes. The closing
  ///   delimiter of the multi-line string literal is placed at column zero so that Swift does not strip the leading
  ///   tabs from the embedded content.
  // swift-format-ignore
  package static let appWithFrameworkPbxprojTemplate: String = """
// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 56;
	objects = {

/* Begin PBXBuildFile section */
		A100000000000000000000B1 /* main.swift in Sources */ = {isa = PBXBuildFile; fileRef = A100000000000000000000A1 /* main.swift */; };
		B100000000000000000000B1 /* Framework.swift in Sources */ = {isa = PBXBuildFile; fileRef = B100000000000000000000A1 /* Framework.swift */; };
		A100000000000000000000B2 /* Framework.framework in Frameworks */ = {isa = PBXBuildFile; fileRef = B100000000000000000000A2 /* Framework.framework */; };
/* End PBXBuildFile section */

/* Begin PBXContainerItemProxy section */
		A100000000000000000000E0 /* PBXContainerItemProxy */ = {
			isa = PBXContainerItemProxy;
			containerPortal = A100000000000000000000B0 /* Project object */;
			proxyType = 1;
			remoteGlobalIDString = B100000000000000000000E1;
			remoteInfo = Framework;
		};
/* End PBXContainerItemProxy section */

/* Begin PBXFileReference section */
		A100000000000000000000A1 /* main.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = main.swift; sourceTree = "<group>"; };
		A100000000000000000000A2 /* App */ = {isa = PBXFileReference; explicitFileType = "compiled.mach-o.executable"; includeInIndex = 0; path = App; sourceTree = BUILT_PRODUCTS_DIR; };
		B100000000000000000000A1 /* Framework.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Framework.swift; sourceTree = "<group>"; };
		B100000000000000000000A2 /* Framework.framework */ = {isa = PBXFileReference; explicitFileType = wrapper.framework; includeInIndex = 0; path = Framework.framework; sourceTree = BUILT_PRODUCTS_DIR; };
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
		A100000000000000000000C1 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				A100000000000000000000B2 /* Framework.framework in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
		B100000000000000000000C1 /* Frameworks */ = {
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
				A100000000000000000000D3 /* App */,
				B100000000000000000000D3 /* Framework */,
				A100000000000000000000D2 /* Products */,
			);
			sourceTree = "<group>";
		};
		A100000000000000000000D2 /* Products */ = {
			isa = PBXGroup;
			children = (
				A100000000000000000000A2 /* App */,
				B100000000000000000000A2 /* Framework.framework */,
			);
			name = Products;
			sourceTree = "<group>";
		};
		A100000000000000000000D3 /* App */ = {
			isa = PBXGroup;
			children = (
				A100000000000000000000A1 /* main.swift */,
			);
			path = App;
			sourceTree = "<group>";
		};
		B100000000000000000000D3 /* Framework */ = {
			isa = PBXGroup;
			children = (
				B100000000000000000000A1 /* Framework.swift */,
			);
			path = Framework;
			sourceTree = "<group>";
		};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		A100000000000000000000E1 /* App */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = A100000000000000000000F1 /* Build configuration list for PBXNativeTarget "App" */;
			buildPhases = (
				A100000000000000000000C2 /* Sources */,
				A100000000000000000000C1 /* Frameworks */,
			);
			buildRules = (
			);
			dependencies = (
				A100000000000000000000E2 /* PBXTargetDependency */,
			);
			name = App;
			productName = App;
			productReference = A100000000000000000000A2 /* App */;
			productType = "com.apple.product-type.tool";
		};
		B100000000000000000000E1 /* Framework */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = B100000000000000000000F1 /* Build configuration list for PBXNativeTarget "Framework" */;
			buildPhases = (
				B100000000000000000000C2 /* Sources */,
				B100000000000000000000C1 /* Frameworks */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = Framework;
			productName = Framework;
			productReference = B100000000000000000000A2 /* Framework.framework */;
			productType = "com.apple.product-type.framework";
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
					B100000000000000000000E1 = {
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
				A100000000000000000000E1 /* App */,
				B100000000000000000000E1 /* Framework */,
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
		B100000000000000000000C2 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				B100000000000000000000B1 /* Framework.swift in Sources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXSourcesBuildPhase section */

/* Begin PBXTargetDependency section */
		A100000000000000000000E2 /* PBXTargetDependency */ = {
			isa = PBXTargetDependency;
			target = B100000000000000000000E1 /* Framework */;
			targetProxy = A100000000000000000000E0 /* PBXContainerItemProxy */;
		};
/* End PBXTargetDependency section */

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
		B100000000000000000000F4 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				PRODUCT_NAME = "$(TARGET_NAME:c99extidentifier)";
				SWIFT_VERSION = 5.0;
			};
			name = Debug;
		};
		B100000000000000000000F5 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				PRODUCT_NAME = "$(TARGET_NAME:c99extidentifier)";
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
		A100000000000000000000F1 /* Build configuration list for PBXNativeTarget "App" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				A100000000000000000000F4 /* Debug */,
				A100000000000000000000F5 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
		B100000000000000000000F1 /* Build configuration list for PBXNativeTarget "Framework" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				B100000000000000000000F4 /* Debug */,
				B100000000000000000000F5 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
/* End XCConfigurationList section */
	};
	rootObject = A100000000000000000000B0 /* Project object */;
}

"""

  /// Creates a minimal Xcode project on disk in a fresh temporary directory.
  ///
  /// - Parameters:
  ///   - kind: The kind of project to generate. Defaults to `.macOSCommandLineTool`.
  ///   - sourceContents: The contents written to the primary source file (`main.swift`, or `App/main.swift` for
  ///     `.appWithFrameworkDependency`).
  ///   - fileManager: The `FileManager` used to create and (on deinit) remove the project. Defaults to `.default`.
  package init(kind: Kind = .macOSCommandLineTool, sourceContents: String, fileManager: FileManager = .default) throws {
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

    // The `.appWithFrameworkDependency` project references its sources under per-target subdirectories
    // (`App/main.swift` and `Framework/Framework.swift`); every other kind keeps `main.swift` at the project root.
    switch kind {
    case .macOSCommandLineTool, .iOSApp:
      self.sourceFileURL = root.appendingPathComponent("main.swift", isDirectory: false)
    case .appWithFrameworkDependency:
      self.sourceFileURL =
        root
        .appendingPathComponent("App", isDirectory: true)
        .appendingPathComponent("main.swift", isDirectory: false)
    }

    try fileManager.createDirectory(at: xcodeprojURL, withIntermediateDirectories: true)
    let template: String
    switch kind {
    case .macOSCommandLineTool: template = Self.pbxprojTemplate
    case .iOSApp: template = Self.iOSAppPbxprojTemplate
    case .appWithFrameworkDependency: template = Self.appWithFrameworkPbxprojTemplate
    }
    try template.write(
      to: xcodeprojURL.appendingPathComponent("project.pbxproj", isDirectory: false),
      atomically: true,
      encoding: .utf8
    )

    try fileManager.createDirectory(
      at: sourceFileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try sourceContents.write(to: sourceFileURL, atomically: true, encoding: .utf8)

    if case .appWithFrameworkDependency = kind {
      let frameworkSourceURL =
        root
        .appendingPathComponent("Framework", isDirectory: true)
        .appendingPathComponent("Framework.swift", isDirectory: false)
      try fileManager.createDirectory(
        at: frameworkSourceURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try "public func frameworkEntry() {}\n".write(to: frameworkSourceURL, atomically: true, encoding: .utf8)
    }
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

  /// Write a minimal shared `.xcscheme` named `name` into `<xcodeprojURL>/xcshareddata/xcschemes`,
  /// whose Build action references `buildTargetNames`. Returns the written scheme file URL.
  ///
  /// Only the `BlueprintName` attribute is meaningful to SourceKit-LSP's scheme parser; the other
  /// attributes are filled with the target name as a stand-in.
  @discardableResult
  package func writeSharedScheme(named name: String, buildTargetNames: [String]) throws -> URL {
    let schemesDir = xcodeprojURL.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true)
    try fileManager.createDirectory(at: schemesDir, withIntermediateDirectories: true)
    let container = xcodeprojURL.lastPathComponent
    let entryLines: [String] = buildTargetNames.flatMap { target -> [String] in
      [
        "         <BuildActionEntry buildForTesting=\"YES\" buildForRunning=\"YES\" buildForProfiling=\"YES\" buildForArchiving=\"YES\" buildForAnalyzing=\"YES\">",
        "            <BuildableReference BuildableIdentifier=\"primary\" BlueprintIdentifier=\"\(target)\" BuildableName=\"\(target)\" BlueprintName=\"\(target)\" ReferencedContainer=\"container:\(container)\"></BuildableReference>",
        "         </BuildActionEntry>",
      ]
    }
    let lines: [String] =
      [
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
        "<Scheme LastUpgradeVersion=\"1500\" version=\"1.7\">",
        "   <BuildAction parallelizeBuildables=\"YES\" buildImplicitDependencies=\"YES\">",
        "      <BuildActionEntries>",
      ] + entryLines + [
        "      </BuildActionEntries>",
        "   </BuildAction>",
        "</Scheme>",
      ]
    let url = schemesDir.appendingPathComponent("\(name).xcscheme", isDirectory: false)
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    return url
  }
}
