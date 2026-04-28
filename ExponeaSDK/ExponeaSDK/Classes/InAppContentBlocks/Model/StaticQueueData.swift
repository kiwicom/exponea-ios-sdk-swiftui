//
//  StaticQueueData.swift
//  ExponeaSDK
//
//  Created by Ankmara on 10.07.2023.
//  Copyright © 2023 Exponea. All rights reserved.
//

public struct StaticQueueData {
    public let tag: Int
    public let placeholderId: String
    internal var makeResourcesOffline: Bool = true
    public var completion: TypeBlock<StaticReturnData>?

    public init(
        tag: Int,
        placeholderId: String,
        completion: TypeBlock<StaticReturnData>? = nil
    ) {
        self.tag = tag
        self.placeholderId = placeholderId
        self.makeResourcesOffline = true
        self.completion = completion
    }

    init(
        tag: Int,
        placeholderId: String,
        makeResourcesOffline: Bool,
        completion: TypeBlock<StaticReturnData>? = nil
    ) {
        self.tag = tag
        self.placeholderId = placeholderId
        self.makeResourcesOffline = makeResourcesOffline
        self.completion = completion
    }
}
