import DoxiCore
import Foundation

/// Adapts library records to the core search engine. Search runs entirely on-device.
enum SearchService {
    static func searchable(_ doc: DocumentRecord) -> SearchableDocument {
        let fields = doc.fields.filter { $0.verification != .rejected }.map { f -> SearchableDocument.Field in
            let v = f.value
            return SearchableDocument.Field(label: f.kind.displayName, value: v.searchableText, amount: v.primaryAmount, date: v.primaryDate)
        }
        let today = CalendarDate.today()
        let obligations = doc.obligations.map {
            SearchableDocument.Obligation(id: $0.id, title: $0.title + " " + ($0.counterparty ?? ""), amount: $0.amount,
                                          dueDate: $0.dueDate, status: $0.status(today: today))
        }
        return SearchableDocument(id: doc.id, filename: doc.originalFilename, title: doc.title,
                                  documentType: doc.documentType?.displayName ?? "", parties: doc.partyNames,
                                  fields: fields, obligations: obligations, fullText: doc.fullText,
                                  textAmounts: Set(doc.textAmounts.map { Int64($0) }),
                                  searchKeyBody: doc.searchKey.isEmpty && !doc.fullText.isEmpty ? nil : doc.searchKey)
    }

    struct Hit: Identifiable {
        let document: DocumentRecord
        let result: SearchResult
        var id: UUID { document.id }
    }

    static func search(_ query: String, in docs: [DocumentRecord]) -> [Hit] {
        let byID = Dictionary(docs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return SearchEngine.search(query, in: docs.map(searchable)).compactMap { r in byID[r.documentID].map { Hit(document: $0, result: r) } }
    }
}
