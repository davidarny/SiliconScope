//
//  File:      Notifier.swift
//  Created:   2026-06-19
//  Updated:   2026-06-19
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Thin wrapper over UNUserNotificationCenter for the opt-in threshold alerts
//             (GPU thermal throttle, memory pressure, swapping).
//  Notes:     Guarded on Bundle.main.bundleIdentifier — under `swift run` there is no app
//             bundle and UNUserNotificationCenter.current() would trap, so we no-op there.
//             Real delivery happens from the signed/notarized .app.
//
import Foundation
import UserNotifications

enum Notifier {
    /// Notifications require a real app bundle; dev (`swift run`) has none → no-op.
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
