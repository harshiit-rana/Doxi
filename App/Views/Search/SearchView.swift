import DoxiCore
import SwiftData
import SwiftUI

/// Local search across filenames, OCR/PDF text, parties, amounts, dates,
/// document types and obligations.
struct SearchView: View {
    @Query(sort: \DocumentRecord.modifiedAt, order: .reverse) private var documents: [DocumentRecord]
    @State private var query = ""
    @State private var results: [SearchService.Hit] = []

    var body: some View {
        NavigationStack {
            List {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Section {
                        Text("Search by company or person, amount (₹80,000 or 80k), month (October), date, document type or any text in your documents.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ForEach(results) { hit in
                        NavigationLink(value: hit.id) { SearchResultRow(document: hit.document, result: hit.result) }
                    }
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "ABC Technologies, ₹80,000, October…")
            .navigationDestination(for: UUID.self) { id in DocumentDetailLoaderInline(documentID: id) }
            .onChange(of: query) { _, q in run(q) }
            .onChange(of: documents.count) { _, _ in run(query) }
        }
    }

    func run(_ q: String) {
        results = SearchService.search(q, in: documents)
    }
}

struct SearchResultRow: View {
    let document: DocumentRecord
    let result: SearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(document.title).font(.body.weight(.medium)).lineLimit(2)
            if let type = document.documentType {
                Text(type.displayName).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(result.matchedFields.prefix(3), id: \.self) { f in
                Text(f).font(.caption).lineLimit(1)
            }
            let obligations = document.obligations.filter { result.matchedObligationIDs.contains($0.id) }
            ForEach(obligations.prefix(3)) { ob in
                HStack(spacing: 6) {
                    Text(ob.title).font(.caption).lineLimit(1)
                    ObligationStatusBadge(status: ob.status())
                }
            }
            if result.matchedFields.isEmpty && obligations.isEmpty, let snippet = result.snippet {
                Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}
