//
//  PushNotificationManagerType.swift
//  ExponeaSDK
//
//  Created by Panaxeo on 07/11/2019.
//  Copyright © 2019 Exponea. All rights reserved.
//

protocol PushNotificationManagerType: AnyObject {
    var delegate: PushNotificationManagerDelegate? { get set }
    func applicationDidBecomeActive()
    func handlePushOpened(userInfoObject: AnyObject?, actionIdentifier: String?)
    func handlePushOpenedWithoutTrackingConsent(userInfoObject: AnyObject?, actionIdentifier: String?)
    func handlePushTokenRegistered(dataObject: AnyObject?)
    func handlePushTokenRegistered(token: String)
    func verifyPushStatusAndTrackPushToken()
    func markEveryLaunchSessionTracked()

    var didReceiveSelfPushCheck: Bool { get }
}
