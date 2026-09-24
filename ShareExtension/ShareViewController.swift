import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Receives PDFs and images from other apps (e.g. WhatsApp → Share → Doxi) and
/// places them in the shared App Group inbox. Doxi imports and analyses them
/// the next time it is opened; nothing is uploaded anywhere.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareView(model: model, onDone: { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await receive() }
    }

    private var inboxURL: URL? {
        let group = Bundle.main.object(forInfoDictionaryKey: "DoxiAppGroup") as? String ?? "group.com.doxi.app"
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        let inbox = container.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        return inbox
    }

    @MainActor
    private func receive() async {
        guard let inbox = inboxURL else {
            model.state = .failed("Doxi's shared storage is not available. Check that the app group is configured.")
            return
        }
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        var saved = 0
        var rejected = 0
        for provider in providers {
            let type: UTType? = provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) ? .pdf
                : provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) ? .image : nil
            guard let type else { rejected += 1; continue }
            if await copy(provider, type: type, to: inbox) { saved += 1 } else { rejected += 1 }
        }
        if saved == 0 {
            model.state = .failed(rejected > 0 ? "Doxi can import PDFs and images. This item isn't one of those." : "Nothing to import.")
        } else {
            model.state = .saved(count: saved, skipped: rejected)
        }
    }

    private func copy(_ provider: NSItemProvider, type: UTType, to inbox: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: false)
                    return
                }
                // The temporary file is deleted when this handler returns, so copy synchronously.
                let name = "\(Int(Date().timeIntervalSince1970 * 1000))_\(url.lastPathComponent)"
                let destination = inbox.appendingPathComponent(name)
                do {
                    try FileManager.default.copyItem(at: url, to: destination)
                    try (destination as NSURL).setResourceValue(URLFileProtection.complete, forKey: .fileProtectionKey)
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(returning: FileManager.default.fileExists(atPath: destination.path))
                }
            }
        }
    }
}

@MainActor
final class ShareModel: ObservableObject {
    enum State: Equatable {
        case receiving
        case saved(count: Int, skipped: Int)
        case failed(String)
    }

    @Published var state: State = .receiving
}

struct ShareView: View {
    @ObservedObject var model: ShareModel
    var onDone: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                switch model.state {
                case .receiving:
                    ProgressView("Saving to Doxi…")
                case .saved(let count, let skipped):
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
                    Text(count == 1 ? "Saved to Doxi" : "\(count) documents saved to Doxi").font(.headline)
                    Text("Open Doxi to read and analyse \(count == 1 ? "it" : "them"). Everything stays on your device until you choose otherwise.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if skipped > 0 {
                        Text("\(skipped) item\(skipped == 1 ? " was" : "s were") skipped (only PDFs and images are supported).")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 44)).foregroundStyle(.orange)
                    Text(message).multilineTextAlignment(.center)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Doxi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone).disabled(model.state == .receiving)
                }
            }
        }
    }
}
