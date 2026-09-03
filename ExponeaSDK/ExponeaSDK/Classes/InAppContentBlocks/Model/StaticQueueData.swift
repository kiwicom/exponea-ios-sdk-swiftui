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
    internal var skipEtag: Bool = false
    public var completion: TypeBlock<StaticReturnData>?

    public init(
        tag: Int,
        placeholderId: String,
        completion: TypeBlock<StaticReturnData>? = nil
    ) {
        self.tag = tag
        self.placeholderId = placeholderId
        self.makeResourcesOffline = true
        self.skipEtag = false
        self.completion = completion
    }

    init(
        tag: Int,
        placeholderId: String,
        makeResourcesOffline: Bool,
        skipEtag: Bool = false,
        completion: TypeBlock<StaticReturnData>? = nil
    ) {
        self.tag = tag
        self.placeholderId = placeholderId
        self.makeResourcesOffline = makeResourcesOffline
        self.skipEtag = skipEtag
        self.completion = completion
    }
}
