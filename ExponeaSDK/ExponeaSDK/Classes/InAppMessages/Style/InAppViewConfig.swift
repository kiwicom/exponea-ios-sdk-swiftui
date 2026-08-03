//
//  InAppViewConfig.swift
//  ExponeaSDK
//
//  Created by Ankmara on 18.03.2025.
//  Copyright © 2025 Exponea. All rights reserved.
//

import Foundation
import Combine

final class InAppViewConfig: ObservableObject {
    var height: CGFloat = 0 {
        willSet {
            debouncer.debounce {
                if self.height != 0 && !self.isLoaded {
                    self.isLoaded = true
                    self.textCompletionHeight?(newValue)
                }
            }
        }
    }
    public var textCompletionHeight: TypeBlock<CGFloat>?
    var isTitleLoaded = false
    var isBodyLoaded = false
    var isImageLoaded = false

    var isLoaded = false
    @Published var shouldBeScrollable = false
    var debouncer = Debouncer(delay: 1.5)
}
