//
//  ActivityView.swift
//  RecipeApp
//
//  Thin SwiftUI wrapper over the native iOS share sheet (UIActivityViewController)
//  so any screen can present Mail / Messages / WhatsApp / etc. for a set of items
//  — no Mail-specific entitlements. Present it from a `.sheet`.
//

import SwiftUI
import UIKit

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
