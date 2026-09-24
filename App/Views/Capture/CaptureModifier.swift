import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Adds the Scan / Import flows to any screen. Show the menu with `AddDocumentMenu`.
struct CaptureCoordinator: ViewModifier {
    @Binding var action: CaptureAction?
    var onImported: ((DocumentRecord) -> Void)?
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var context
    @State private var showScanner = false
    @State private var showImporter = false
    @State private var reviewPages: [ScannedPage]?
    @State private var errorMessage: String?

    var scanMoreAction: (() -> Void)? {
        guard ScannerView.isSupported else { return nil }
        return { showScanner = true }
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: action) { _, new in
                switch new {
                case .scan: showScanner = true
                case .importFile: showImporter = true
                case nil: break
                }
                action = nil
            }
            .fullScreenCover(isPresented: $showScanner) {
                ScannerView(
                    onFinish: { images in
                        showScanner = false
                        let existing = reviewPages ?? []
                        reviewPages = existing + images.map { ScannedPage(original: $0) }
                    },
                    onCancel: { showScanner = false },
                    onError: { error in
                        showScanner = false
                        errorMessage = "Scanning failed: \(error.localizedDescription)"
                    })
                .ignoresSafeArea()
            }
            .sheet(isPresented: Binding(get: { reviewPages != nil && !showScanner }, set: { if !$0 { reviewPages = nil } })) {
                if let pages = reviewPages {
                    ScanReviewView(pages: pages, onCreate: { images in
                        reviewPages = nil
                        do {
                            let doc = try services.importer.importScan(pages: images, context: context)
                            services.process(doc, context: context)
                            onImported?(doc)
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }, onScanMore: scanMoreAction)
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf, .image], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    var failures: [String] = []
                    for url in urls {
                        do {
                            let doc = try services.importer.importFile(at: url, origin: .importFile, context: context)
                            services.process(doc, context: context)
                            if urls.count == 1 { onImported?(doc) }
                        } catch {
                            failures.append(error.localizedDescription)
                        }
                    }
                    if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
            .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
    }
}

enum CaptureAction: Hashable { case scan, importFile }

extension View {
    func documentCapture(_ action: Binding<CaptureAction?>, onImported: ((DocumentRecord) -> Void)? = nil) -> some View {
        modifier(CaptureCoordinator(action: action, onImported: onImported))
    }
}

/// The single "+" entry point for adding documents.
struct AddDocumentMenu: View {
    @Binding var action: CaptureAction?

    var body: some View {
        Menu {
            if ScannerView.isSupported {
                Button { action = .scan } label: { Label("Scan document", systemImage: "doc.viewfinder") }
            }
            Button { action = .importFile } label: { Label("Import from Files", systemImage: "folder") }
        } label: {
            Label("Add document", systemImage: "plus")
        }
    }
}
