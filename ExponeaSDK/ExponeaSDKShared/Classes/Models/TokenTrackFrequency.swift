//
//  TokenTrackFrequency.swift
//  ExponeaSDKShared
//
//  Created by Dominik Hádl on 07/08/2019.
//  Copyright © 2019 Exponea. All rights reserved.
//

import Foundation

/// Used to configure when how often should a push notification token be tracked to Exponea.
/// See `Configuration` for ways how to set it up.
///
/// - onTokenChange: Tracked whenever the push token changes.
/// - everyLaunch: Tracked once per app process start (cold launch until process death).
///   Foreground transitions within the same process do not re-track unless an override applies
///   (permission change, token change, manual `trackPushToken()`, anonymize/stopIntegration,
///   etc.). App version or application ID changes are detected at SDK startup and only affect
///   `onTokenChange`/`daily` staleness checks, not mid-process `.everyLaunch` behavior.
///   Consider data usage/battery life.
/// - daily: Once a day on app launch.
public enum TokenTrackFrequency: String, Codable {
    case onTokenChange
    case everyLaunch
    case daily
}
