import SwiftUI
import VisionKit

/// The system document camera: page detection, perspective correction,
/// cropping and multi-page capture.
struct ScannerView: UIViewControllerRepresentable {
    var onFinish: ([UIImage]) -> Void
    var onCancel: () -> Void
    var onError: (Error) -> Void

    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: ScannerView
        init(_ parent: ScannerView) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let images = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            parent.onFinish(images)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            parent.onError(error)
        }
    }
}

/// A scanned page being reviewed before the PDF is created.
struct ScannedPage: Identifiable {
    let id = UUID()
    var original: UIImage
    var quarterTurns = 0
    var enhanced = false

    var rendered: UIImage {
        let rotated = PDFBuilder.rotate(original, clockwiseQuarterTurns: quarterTurns)
        return enhanced ? PDFBuilder.enhance(rotated) : rotated
    }
}

/// Review scanned pages: reorder, rotate, enhance or delete, then create the PDF.
struct ScanReviewView: View {
    @State var pages: [ScannedPage]
    var onCreate: ([UIImage]) -> Void
    var onScanMore: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var editMode = EditMode.inactive
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($pages) { $page in
                        HStack(spacing: 12) {
                            Image(uiImage: page.rendered)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 70, height: 96)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Page \((pages.firstIndex { $0.id == page.id } ?? 0) + 1)").font(.headline)
                                HStack {
                                    Button { page.quarterTurns += 1 } label: { Label("Rotate", systemImage: "rotate.right") }
                                    Toggle(isOn: $page.enhanced) { Label("Enhance", systemImage: "wand.and.stars") }
                                        .toggleStyle(.button)
                                }
                                .buttonStyle(.bordered)
                                .labelStyle(.iconOnly)
                                .controlSize(.small)
                            }
                        }
                    }
                    .onMove { pages.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { pages.remove(atOffsets: $0) }
                } footer: {
                    Text("Drag to reorder pages. Enhance increases contrast for faint or shadowed scans.")
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle("\(pages.count) page\(pages.count == 1 ? "" : "s")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Discard", role: .destructive) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button(editMode.isEditing ? "Done" : "Reorder") {
                        editMode = editMode.isEditing ? .inactive : .active
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    if let onScanMore {
                        Button { onScanMore() } label: { Label("Scan more", systemImage: "plus.viewfinder") }
                    }
                    Spacer()
                    Button {
                        isCreating = true
                        let images = pages.map(\.rendered)
                        onCreate(images)
                        dismiss()
                    } label: {
                        Text("Save PDF").bold()
                    }
                    .disabled(pages.isEmpty || isCreating)
                }
            }
        }
    }
}
