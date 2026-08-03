//
//  FastBarApp.swift
//  FastBar
//
//  Created by Fatih Kadir Akın on 3.08.2026.
//

import SwiftUI

@main
struct FastBarApp: App {
    @StateObject private var monitor = SpeedMonitor()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(monitor)
        } label: {
            Text(monitor.menuBarCurrentText)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .menuBarExtraStyle(.window)
    }
}
