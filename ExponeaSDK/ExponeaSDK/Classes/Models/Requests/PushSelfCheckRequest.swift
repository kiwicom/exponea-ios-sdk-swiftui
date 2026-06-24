//
//  PushSelfCheckRequest.swift
//  ExponeaSDK
//
//  Created by Panaxeo on 26/05/2020.
//  Copyright © 2020 Exponea. All rights reserved.
//

import Foundation

struct PushSelfCheckRequest: Codable, RequestParametersType {
    let pushToken: String
    /// Project / mobile-app identifier used for multi-app routing on the backend.
    /// Mirrors `AppInboxRequest.applicationID`: callers always populate it from
    /// `Configuration.applicationID` (which falls back to `Constants.General.applicationID`),
    /// so the field is technically optional only to preserve backwards-compatibility
    /// with consumers that still build the request without it.
    var applicationID: String?

    var parameters: [String: JSONValue] {
        var result: [String: JSONValue] = [
            "platform": "ios".jsonValue,
            "push_notification_id": pushToken.jsonValue
        ]
        if let applicationID {
            result["application_id"] = applicationID.jsonValue
        }
        return result
    }
}
