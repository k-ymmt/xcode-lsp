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

import BuildServerIntegration
import Foundation
import XCTest

final class XcodeSchemeTests: XCTestCase {
  #if !NO_SWIFTPM_DEPENDENCY
  private func scheme(buildEntries: String, extraActions: String = "") -> Data {
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <Scheme LastUpgradeVersion="1500" version="1.7">
         <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
            <BuildActionEntries>
      \(buildEntries)
            </BuildActionEntries>
         </BuildAction>
      \(extraActions)
      </Scheme>
      """
    return Data(xml.utf8)
  }

  private func entry(blueprintName: String) -> String {
    """
          <BuildActionEntry buildForRunning="YES">
             <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="\(blueprintName)" BuildableName="\(blueprintName)" BlueprintName="\(blueprintName)" ReferencedContainer="container:MyApp.xcodeproj"></BuildableReference>
          </BuildActionEntry>
    """
  }

  func testParsesMultipleBuildActionTargetNames() {
    let data = scheme(buildEntries: entry(blueprintName: "App") + "\n" + entry(blueprintName: "Framework"))
    XCTAssertEqual(XcodeScheme.buildActionTargetNames(xcschemeContents: data), ["App", "Framework"])
  }

  func testEmptyBuildActionReturnsEmpty() {
    let data = scheme(buildEntries: "")
    XCTAssertEqual(XcodeScheme.buildActionTargetNames(xcschemeContents: data), [])
  }

  func testDeduplicatesNames() {
    let data = scheme(buildEntries: entry(blueprintName: "App") + "\n" + entry(blueprintName: "App"))
    XCTAssertEqual(XcodeScheme.buildActionTargetNames(xcschemeContents: data), ["App"])
  }

  func testIgnoresBuildableReferencesOutsideBuildAction() {
    // A TestAction BuildableReference must NOT be picked up.
    let testAction = """
         <TestAction buildConfiguration="Debug">
            <Testables>
               <TestableReference skipped="NO">
                  <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="Tests" BuildableName="Tests" BlueprintName="Tests" ReferencedContainer="container:MyApp.xcodeproj"></BuildableReference>
               </TestableReference>
            </Testables>
         </TestAction>
      """
    let data = scheme(buildEntries: entry(blueprintName: "App"), extraActions: testAction)
    XCTAssertEqual(XcodeScheme.buildActionTargetNames(xcschemeContents: data), ["App"])
  }
  #endif
}
