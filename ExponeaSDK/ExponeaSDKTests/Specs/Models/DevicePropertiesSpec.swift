//
//  DevicePropertiesSpec.swift
//  ExponeaSDKTests
//
//  Created by Ricardo Tokashiki on 16/04/2018.
//  Copyright © 2018 Exponea. All rights reserved.
//

import Foundation
import Quick
import Nimble

@testable import ExponeaSDK

class DevicePropertiesSpec: QuickSpec {

    class MockBundle: Bundle {
        override var infoDictionary: [String: Any]? {
            return [Constants.Keys.appVersion: "1.2"]
        }
    }

    override func spec() {
        describe("A device") {
            context("after beign properly initialized") {

                let device = DeviceProperties(bundle: MockBundle())

                it("Should not be nil") {
                    expect(device).toNot(beNil())
                }

                it("Should have a valid device type") {
                    expect(device.deviceType).to(equal("mobile"))
                }

                it("Should have a OS Version equals iOS current version") {
                    expect(device.osVersion).to(equal(UIDevice.current.systemVersion))
                }

                it("Should have a device type equals mobile") {
                    expect(device.deviceType).to(equal("mobile"))
                }

                it("Should have version number different from N/A") {
                    expect(device.appVersion).toNot(equal("N/A"))
                    expect(device.appVersion).to(equal("1.2"))
                }
            }
        }

        describe("UIDevice.mapDeviceIdentifier") {
            // Sampled coverage: one known identifier per device family plus the fallback /
            // simulator paths. A full enumeration would be brittle and high-maintenance
            // (the marketing-name strings are the source-of-truth themselves and shift with
            // Apple's rebrands — e.g. "Plus" → "Air" for iPhone 17). Sampling guards
            // structural correctness without locking in copy.
            it("maps a known iPhone identifier to its marketing name") {
                expect(UIDevice.mapDeviceIdentifier("iPhone18,1")).to(equal("iPhone 17 Pro"))
            }

            it("maps a known iPad Pro identifier to its marketing name") {
                expect(UIDevice.mapDeviceIdentifier("iPad17,3")).to(equal("iPad Pro 13-inch (M5)"))
            }

            // Defends the user-visible wire-shape contract: unmapped hardware (typically
            // released after this SDK ships) must surface its raw `uname()` identifier so
            // analytics dashboards stay debuggable, instead of silently collapsing to the
            // generic form-factor name from `UIDevice.current.model`.
            it("falls back to the raw identifier when no marketing name is mapped") {
                expect(UIDevice.mapDeviceIdentifier("iPhone99,99")).to(equal("iPhone99,99"))
                expect(UIDevice.mapDeviceIdentifier("iPad99,99")).to(equal("iPad99,99"))
            }

            // Regression guard for the simulator routing: regardless of which architecture
            // identifier the simulator process reports (i386 / x86_64 on Intel hosts or
            // Rosetta, arm64 on Apple Silicon natively), the wire field must surface a
            // "Simulator <name>" string — never leak the raw arch token.
            it("routes simulator architecture identifiers through the simulator path") {
                for arch in ["i386", "x86_64", "arm64"] {
                    let resolved = UIDevice.mapDeviceIdentifier(arch)
                    expect(resolved).to(beginWith("Simulator "), description: "arch=\(arch)")
                    expect(resolved).toNot(equal(arch), description: "arch=\(arch) must not wire-leak as-is")
                }
            }
        }
    }
}
