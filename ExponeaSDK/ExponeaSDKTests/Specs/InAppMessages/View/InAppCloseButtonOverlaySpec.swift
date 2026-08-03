import Foundation
import Nimble
import Quick
import UIKit

@testable import ExponeaSDK

final class InAppCloseButtonOverlaySpec: QuickSpec {
    override func spec() {
        func makeConfig(
            margin: [InAppButtonEdge],
            visibility: Bool = true,
            imageURL: String? = nil,
            backgroundColor: String? = nil,
            iconColor: String? = nil
        ) -> InAppCloseButtonConfig {
            InAppCloseButtonConfig(
                margin: margin,
                imageURL: imageURL,
                backgroundColor: backgroundColor,
                iconColor: iconColor,
                visibility: visibility
            )
        }

        describe("InAppCloseButtonOverlay padding resolution") {
            it("should resolve explicit top and trailing margins") {
                let config = makeConfig(
                    margin: "8px 12px 0px 0px".calculatePaddings()
                )

                expect(InAppCloseButtonOverlay.topPadding(from: config)).to(equal(8))
                expect(InAppCloseButtonOverlay.trailingPadding(from: config)).to(equal(12))
            }

            it("should default missing top and trailing edges to zero") {
                let config = makeConfig(margin: [])

                expect(InAppCloseButtonOverlay.topPadding(from: config)).to(equal(0))
                expect(InAppCloseButtonOverlay.trailingPadding(from: config)).to(equal(0))
            }

            it("should ignore leading and bottom margin values for placement") {
                let config = makeConfig(
                    margin: [
                        InAppButtonEdge(edge: .top, value: 8),
                        InAppButtonEdge(edge: .trailing, value: 10),
                        InAppButtonEdge(edge: .leading, value: 99),
                        InAppButtonEdge(edge: .bottom, value: 77)
                    ]
                )

                expect(InAppCloseButtonOverlay.topPadding(from: config)).to(equal(8))
                expect(InAppCloseButtonOverlay.trailingPadding(from: config)).to(equal(10))
            }
        }

        describe("InAppCloseButtonOverlay visibility and sizing") {
            it("should preserve visibility from the close button config") {
                let visible = makeConfig(margin: [], visibility: true)
                let hidden = makeConfig(margin: [], visibility: false)

                expect(visible.visibility).to(beTrue())
                expect(hidden.visibility).to(beFalse())
            }

            it("should preserve the 40 by 40 padded tap target") {
                let config = makeConfig(margin: [])

                expect(config.sizeWithPadding.width).to(equal(40))
                expect(config.sizeWithPadding.height).to(equal(40))
            }
        }

        describe("InAppCloseButtonOverlay icon tint resolution") {
            it("should return the parsed color for a valid 6-digit hex") {
                let config = makeConfig(margin: [], iconColor: "#333333")
                let tint = InAppCloseButtonOverlay.resolvedIconTint(from: config)

                expect(tint).toNot(beNil())
                expect(tint).to(equal(UIColor.parse("#333333")))
            }

            it("should return nil for a valid 8-digit hex with zero alpha so the asset stays untinted") {
                let config = makeConfig(margin: [], iconColor: "#33333300")
                let tint = InAppCloseButtonOverlay.resolvedIconTint(from: config)

                expect(tint).to(beNil())
            }

            it("should fall back to the default icon tint for an invalid 5-digit hex") {
                let config = makeConfig(margin: [], iconColor: "#33333")
                let tint = InAppCloseButtonOverlay.resolvedIconTint(from: config)

                expect(tint).to(equal(InAppCloseButtonOverlay.defaultIconTint))
                expect(tint).to(equal(UIColor.black))
            }

            it("should fall back to the default icon tint when icon color is nil") {
                let config = makeConfig(margin: [], iconColor: nil)
                let tint = InAppCloseButtonOverlay.resolvedIconTint(from: config)

                expect(tint).to(equal(InAppCloseButtonOverlay.defaultIconTint))
                expect(tint).to(equal(UIColor.black))
            }

            it("should return the parsed color for a CSS color name") {
                let config = makeConfig(margin: [], iconColor: "black")
                let tint = InAppCloseButtonOverlay.resolvedIconTint(from: config)

                expect(tint).to(equal(UIColor.parse("black")))
            }
        }

        describe("InAppCloseButtonOverlay background color resolution") {
            it("should return the parsed color for a valid background hex") {
                let config = makeConfig(margin: [], backgroundColor: "#112233")
                let color = InAppCloseButtonOverlay.resolvedBackgroundColor(from: config)

                expect(color).to(equal(UIColor.parse("#112233")))
            }

            it("should fall back to semi-transparent white when background color is absent") {
                let config = makeConfig(margin: [], backgroundColor: nil)
                let color = InAppCloseButtonOverlay.resolvedBackgroundColor(from: config)

                expect(color).to(equal(InAppCloseButtonOverlay.defaultBackgroundColor))
                expect(color).to(equal(UIColor.white.withAlphaComponent(0.6)))
            }

            it("should fall back to semi-transparent white when background color is unparseable") {
                let config = makeConfig(margin: [], backgroundColor: "#33333")
                let color = InAppCloseButtonOverlay.resolvedBackgroundColor(from: config)

                expect(color).to(equal(InAppCloseButtonOverlay.defaultBackgroundColor))
                expect(color).to(equal(UIColor.white.withAlphaComponent(0.6)))
            }
        }
    }
}
