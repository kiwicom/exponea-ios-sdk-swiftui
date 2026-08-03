import Foundation
import Nimble
import Quick
import SwiftUI
import UIKit

@testable import ExponeaSDK

final class InAppCloseButtonLayoutSpec: QuickSpec {
    override func spec() {
        let decoder: JSONDecoder = {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return decoder
        }()

        func decodeRichPayload(
            jsonTransform: (String) -> String = { $0 }
        ) -> RichInAppMessagePayload {
            let json = jsonTransform(SampleInAppMessage.samplePayloadRich)
            let data = json.data(using: .utf8)!
            let message = try! decoder.decode(InAppMessage.self, from: data)
            guard let payload = message.payload else {
                fail("Expected rich in-app payload")
                return try! decoder.decode(
                    InAppMessage.self,
                    from: SampleInAppMessage.samplePayloadRich.data(using: .utf8)!
                ).payload!
            }
            return payload
        }

        func hostView<V: View>(_ view: V) {
            let host = UIHostingController(rootView: view)
            host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            expect(host.view.bounds.width).to(equal(390))
        }

        func makeInAppView(
            from payload: RichInAppMessagePayload,
            isFullscreen: Bool = false,
            shouldBeScrollable: Bool = false
        ) -> InAppView {
            let view = InAppView(
                layouConfig: payload.layoutConfig,
                buttonsConfig: payload.buttons.compactMap { $0.buttonConfig }.filter { $0.isEnabled },
                titleConfig: payload.titleConfig,
                bodyConfig: payload.bodyConfig,
                closeButtonConfig: payload.closeConfig,
                imageConfig: payload.imageConfig,
                isFullscreen: isFullscreen
            )
            view.config.shouldBeScrollable = shouldBeScrollable
            return view
        }

        describe("InApp close button layout smoke tests") {
            it("should host modal layout with text at top") {
                let payload = decodeRichPayload { json in
                    json
                        .replacingOccurrences(of: "\"close_button_enabled\": false", with: "\"close_button_enabled\": true")
                        .replacingOccurrences(of: "\"text_position\": \"left\"", with: "\"text_position\": \"top\"")
                }
                hostView(makeInAppView(from: payload))
            }

            it("should host modal layout with text at bottom") {
                let payload = decodeRichPayload { json in
                    json
                        .replacingOccurrences(of: "\"close_button_enabled\": false", with: "\"close_button_enabled\": true")
                        .replacingOccurrences(of: "\"text_position\": \"left\"", with: "\"text_position\": \"bottom\"")
                }
                hostView(makeInAppView(from: payload))
            }

            it("should host scrollable modal layout") {
                let payload = decodeRichPayload { json in
                    json.replacingOccurrences(of: "\"close_button_enabled\": false", with: "\"close_button_enabled\": true")
                }
                hostView(makeInAppView(from: payload, shouldBeScrollable: true))
            }

            it("should host slide-in layout with text on the left") {
                let payload = decodeRichPayload { json in
                    json
                        .replacingOccurrences(of: "\"message_type\": \"modal\"", with: "\"message_type\": \"slidein\"")
                        .replacingOccurrences(of: "\"close_button_enabled\": false", with: "\"close_button_enabled\": true")
                }
                let slideInView = InAppMessageSlideInViewSwiftUI(
                    layouConfig: payload.layoutConfig,
                    buttonsConfig: payload.buttons.compactMap { $0.buttonConfig }.filter { $0.isEnabled },
                    titleConfig: payload.titleConfig,
                    bodyConfig: payload.bodyConfig,
                    closeButtonConfig: payload.closeConfig,
                    imageConfig: payload.imageConfig,
                    heightCompletion: nil
                )
                hostView(slideInView)
            }

            it("should host slide-in layout with text on the right") {
                let payload = decodeRichPayload { json in
                    json
                        .replacingOccurrences(of: "\"message_type\": \"modal\"", with: "\"message_type\": \"slidein\"")
                        .replacingOccurrences(of: "\"close_button_enabled\": false", with: "\"close_button_enabled\": true")
                        .replacingOccurrences(of: "\"text_position\": \"left\"", with: "\"text_position\": \"right\"")
                }
                let slideInView = InAppMessageSlideInViewSwiftUI(
                    layouConfig: payload.layoutConfig,
                    buttonsConfig: payload.buttons.compactMap { $0.buttonConfig }.filter { $0.isEnabled },
                    titleConfig: payload.titleConfig,
                    bodyConfig: payload.bodyConfig,
                    closeButtonConfig: payload.closeConfig,
                    imageConfig: payload.imageConfig,
                    heightCompletion: nil
                )
                hostView(slideInView)
            }

            it("should host slide-in fullscreen image with overlay and title at top") {
                let payload = decodeRichPayload { json in
                    json
                        .replacingOccurrences(of: "\"message_type\": \"modal\"", with: "\"message_type\": \"slidein\"")
                        .replacingOccurrences(of: "\"close_button_enabled\": false", with: "\"close_button_enabled\": true")
                        .replacingOccurrences(of: "\"image_size\": \"auto\"", with: "\"image_size\": \"fullscreen\"")
                        .replacingOccurrences(of: "\"text_position\": \"left\"", with: "\"text_position\": \"top\"")
                        .replacingOccurrences(
                            of: "\"image_enabled\": true",
                            with: "\"image_enabled\": true,\n            \"image_overlay_enabled\": true"
                        )
                }
                let slideInView = InAppMessageSlideInViewSwiftUI(
                    layouConfig: payload.layoutConfig,
                    buttonsConfig: payload.buttons.compactMap { $0.buttonConfig }.filter { $0.isEnabled },
                    titleConfig: payload.titleConfig,
                    bodyConfig: payload.bodyConfig,
                    closeButtonConfig: payload.closeConfig,
                    imageConfig: payload.imageConfig,
                    heightCompletion: nil
                )
                hostView(slideInView)
            }
        }
    }
}

