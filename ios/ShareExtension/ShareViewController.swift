//
//  ShareViewController.swift
//  ShareExtension
//
//  The extension's principal class (wired via NSExtensionPrincipalClass in
//  Info.plist — no storyboard). Its only jobs: pull the shared URL out of the
//  extension context, host `ShareRootView` (the real "submit and forget" UI),
//  and complete the request when that view finishes. All real work — job
//  submission, PendingJobStore persistence — lives in ShareRootView / RecipeKit.
//

import UIKit
import SwiftUI
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        extractSharedURL { [weak self] urlString in
            self?.presentRoot(with: urlString)
        }
    }

    // MARK: - UI

    private func presentRoot(with urlString: String?) {
        let root = ShareRootView(
            sharedURL: urlString,
            onFinish: { [weak self] in self?.finish() }
        )
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear

        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    // MARK: - URL extraction

    /// Walks every attachment across every input item, preferring a real URL
    /// provider, then falling back to plain text that contains a URL (IG/TikTok
    /// sometimes hand over the link as text). Always resolves on the main queue;
    /// passes nil if nothing usable is found (ShareRootView shows a graceful
    /// "unsupported link" state rather than crashing).
    private func extractSharedURL(completion: @escaping (String?) -> Void) {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?
            .flatMap { $0.attachments ?? [] } ?? []

        let urlType = UTType.url.identifier
        let textType = UTType.plainText.identifier

        // Prefer an explicit URL attachment.
        if let urlProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(urlType) }) {
            urlProvider.loadItem(forTypeIdentifier: urlType, options: nil) { item, _ in
                let resolved = (item as? URL)?.absoluteString ?? (item as? String)
                DispatchQueue.main.async { completion(resolved) }
            }
            return
        }

        // Fall back to plain text that may contain a link.
        if let textProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(textType) }) {
            textProvider.loadItem(forTypeIdentifier: textType, options: nil) { item, _ in
                let text = item as? String
                DispatchQueue.main.async { completion(Self.firstURL(in: text) ?? text) }
            }
            return
        }

        DispatchQueue.main.async { completion(nil) }
    }

    private static func firstURL(in text: String?) -> String? {
        guard let text else { return nil }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?.firstMatch(in: text, options: [], range: range)?.url?.absoluteString
    }
}
