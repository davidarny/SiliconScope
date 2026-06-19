//
//  File:      LoginItem.swift
//  Created:   2026-06-19
//  Updated:   2026-06-19
//  Developer: Kennt Kim / Calida Lab
//  Overview:  "Launch at login" via SMAppService.mainApp (macOS 13+). No helper bundle or
//             login-item plist needed — the main app registers itself.
//  Notes:     Only works from a signed .app bundle; under `swift run` (no bundle)
//             register() throws, which we swallow so the dev build never crashes. The
//             Settings toggle reads `isEnabled` for the source of truth.
//
import Foundation
import ServiceManagement

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Register/unregister the app as a login item. Errors (e.g. unsigned dev build) are
    /// logged and ignored so the UI degrades gracefully.
    static func setEnabled(_ on: Bool) {
        do {
            switch (on, SMAppService.mainApp.status) {
            case (true, let s) where s != .enabled:  try SMAppService.mainApp.register()
            case (false, .enabled):                  try SMAppService.mainApp.unregister()
            default:                                  break
            }
        } catch {
            NSLog("SiliconScope LoginItem: \(error.localizedDescription)")
        }
    }
}
