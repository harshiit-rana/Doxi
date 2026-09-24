import DoxiCore
import SwiftData
import SwiftUI

struct DocumentListView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var context
    @Query(sort: \DocumentRecord.modifiedAt, order: .reverse) private var documents: [DocumentRecord]
    @State private var capture: CaptureAction?
    @State private var path = NavigationPath()
    @State private var pendingDelete: DocumentRecord?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if documents.isEmpty {
                    ContentUnavailableView {
                        Label("No documents yet", systemImage: "doc.text")
                    } description: {
                        Text("Scan a paper contract or import a PDF. Doxi reads it on your device and finds dates, amounts and obligations.")
                    } actions: {
                        AddDocumentMenu(action: $capture).buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(documents) { doc in
                            NavigationLink(value: doc.id) { DocumentRow(document: doc) }
                                .swipeActions {
                                    Button(role: .destructive) { pendingDelete = doc } label: { Label("Delete", systemImage: "trash") }
                                }
                        }
                    }
                }
            }
            .navigationTitle("Documents")
            .navigationDestination(for: UUID.self) { id in DocumentDetailLoaderInline(documentID: id) }
            .toolbar { ToolbarItem(placement: .primaryAction) { AddDocumentMenu(action: $capture) } }
            .documentCapture($capture) { doc in path.append(doc.id) }
            .confirmationDialog("Delete this document?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Delete document and its reminders", role: .destructive) {
                    if let doc = pendingDelete { services.delete(doc, context: context) }
                    pendingDelete = nil
                }
            } message: {
                Text("The file, extracted details, obligations and reminders will be removed from this device.")
            }
        }
    }
}

struct DocumentRow: View {
    let document: DocumentRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(document.title).font(.body.weight(.medium)).lineLimit(2)
            HStack(spacing: 8) {
                if let type = document.documentType { Text(type.displayName) }
                ProcessingBadge(status: document.status)
                if document.status == .confirmed && document.pendingFieldCount > 0 {
                    Text("\(document.pendingFieldCount) unchecked").foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Looks up a document for navigation destinations.
struct DocumentDetailLoaderInline: View {
    let documentID: UUID
    @Query private var docs: [DocumentRecord]

    init(documentID: UUID) {
        self.documentID = documentID
        _docs = Query(filter: #Predicate<DocumentRecord> { $0.id == documentID })
    }

    var body: some View {
        if let doc = docs.first {
            DocumentDetailView(document: doc)
        } else {
            ContentUnavailableView("Document not found", systemImage: "doc.questionmark")
        }
    }
}
