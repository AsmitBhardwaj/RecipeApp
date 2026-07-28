//
//  ShareViewController.swift
//  ShareExtension
//
//  Principal class for the Share Extension (referenced by NSExtensionPrincipalClass
//  in Info.plist — there is deliberately NO storyboard). Its only job is to pull
//  the shared URL out of the extension context and host the SwiftUI
//  `ShareRootView`, which submits the job and dismisses. All real work (submit +
//  persist to the shared App Group store) is reused verbatim from RecipeKit; the
//  extension adds no networking or model code of its own.
//

import UIKit
import SwiftUI
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        extractSharedURL { [weak self] url in
            self?.presentUI(url: url)
        }
    }

    // MARK: - UI

    private func presentUI(url: String?) {
        let root = ShareRootView(
            sharedURL: url,
            onFinish: { [weak self] in self?.finish() }
        )
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    /// Complete and dismiss. The extension never waits on extraction — the main
    /// app picks the job up from the shared store on next foreground.
    private func finish() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    // MARK: - Extract the shared URL

    /// Pulls a URL string from the shared item: a real `public.url` attachment
    /// first, then a URL detected inside shared `public.plain-text`. Returns nil
    /// if neither yields one (the UI then shows the unsupported-link state).
    private func extractSharedURL(completion: @escaping (String?) -> Void) {
        guard
            let item = extensionContext?.inputItems.first as? NSExtensionItem,
            let providers = item.attachments
        else {
            completion(nil)
            return
        }

        let urlType = UTType.url.identifier
        let textType = UTType.plainText.identifier

        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(urlType) }) {
            provider.loadItem(forTypeIdentifier: urlType, options: nil) { value, _ in
                let url = (value as? URL)?.absoluteString ?? (value as? String)
                DispatchQueue.main.async { completion(url) }
            }
            return
        }

        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(textType) }) {
            provider.loadItem(forTypeIdentifier: textType, options: nil) { value, _ in
                let url = (value as? String).flatMap(Self.firstURL(in:))
                DispatchQueue.main.async { completion(url) }
            }
            return
        }

        completion(nil)
    }

    /// First link found in free text (Instagram/TikTok sometimes share the caption
    /// with the URL embedded rather than a bare URL attachment).
    private static func firstURL(in text: String) -> String? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?.firstMatch(in: text, options: [], range: range)?.url?.absoluteString
    }
}
