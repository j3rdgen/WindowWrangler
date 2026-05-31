//
//  AppInfo.swift
//  Window Wrangler
//
//  Centralized lookup for the app's display name.
//  Reading from the bundle (instead of hardcoding) means a future
//  rename only requires changing the build setting — no global
//  find-and-replace through source code.
//

import Foundation

enum AppInfo {

    /// User-visible app name. Mirrors CFBundleDisplayName from Info.plist.
    /// Falls back to bundle name, then a hardcoded default.
    static let displayName: String = {
        let info = Bundle.main.infoDictionary
        if let display = info?["CFBundleDisplayName"] as? String, !display.isEmpty {
            return display
        }
        if let name = info?[kCFBundleNameKey as String] as? String, !name.isEmpty {
            return name
        }
        return "Window Wrangler"
    }()
}
