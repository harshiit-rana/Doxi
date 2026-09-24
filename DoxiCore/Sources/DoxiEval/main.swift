import DoxiCore
import Foundation
#if canImport(PDFKit) && canImport(Vision)
import DoxiReader
#endif

// doxi-eval: runs every labelled document in one or more dataset folders through
// the Phase 1 extraction pipeline and reports accuracy per document and per field.
//
//   swift run doxi-eval ../Evaluation/datasets/synthetic-temporary ../Evaluation/datasets/real
//   ANTHROPIC_API_KEY=... swift run doxi-eval --provider anthropic ../Evaluation/datasets/real
//
// Each document `name.ext` needs a hand-written `name.expected.json` (see
// Evaluation/README.md). Labels must be written from the document, never copied
// from extractor output.

struct Options {
    var folders: [String] = []
    var provider: String?
    var model = AnthropicExtractionProvider.defaultModel
    var jsonOut: String?
    var verbose = false
    var today = CalendarDate.today()
}

func parseArguments() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "--provider": o.provider = args.isEmpty ? nil : args.removeFirst()
        case "--model": if !args.isEmpty { o.model = args.removeFirst() }
        case "--json": o.jsonOut = args.isEmpty ? nil : args.removeFirst()
        case "--today": if !args.isEmpty, let d = CalendarDate(iso: args.removeFirst()) { o.today = d }
        case "-v", "--verbose": o.verbose = true
        case "-h", "--help":
            print("usage: doxi-eval [--provider anthropic] [--model ID] [--json report.json] [--verbose] <dataset-folder>...")
            exit(0)
        default: o.folders.append(a)
        }
    }
    return o
}

// MARK: Loading

let documentExtensions = ["txt", "pages.json", "pdf", "png", "jpg", "jpeg", "heic", "tif", "tiff"]

func findDocument(for expectedURL: URL) -> URL? {
    let base = expectedURL.lastPathComponent.replacingOccurrences(of: ".expected.json", with: "")
    let dir = expectedURL.deletingLastPathComponent()
    for ext in documentExtensions {
        let url = dir.appendingPathComponent("\(base).\(ext)")
        if FileManager.default.fileExists(atPath: url.path) { return url }
    }
    return nil
}

func loadText(_ url: URL) -> (DocumentText?, String?) {
    let name = url.lastPathComponent
    if name.hasSuffix(".pages.json") {
        guard let data = try? Data(contentsOf: url), let doc = try? JSONDecoder().decode(DocumentText.self, from: data) else {
            return (nil, "Could not decode \(name)")
        }
        return (doc, nil)
    }
    if url.pathExtension.lowercased() == "txt" {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return (nil, "Could not read \(name)") }
        return (DocumentText(plainText: s), nil)
    }
    #if canImport(PDFKit) && canImport(Vision)
    guard let pages = DocumentReader().read(fileURL: url) else { return (nil, "Could not open \(name)") }
    return (DocumentText(pages: pages.map(\.text)), nil)
    #else
    return (nil, "\(name): PDF and image documents need macOS (PDFKit + Vision). Export a .pages.json from the app or run on a Mac.")
    #endif
}

// MARK: Scoring

struct FieldScore {
    var correct = 0.0
    var total = 0.0
    var ratio: Double? { total > 0 ? correct / total : nil }
    mutating func add(_ c: Double, of t: Double = 1) { correct += c; total += t }
}

let reportedFields = ["Document type", "Parties", "Effective date", "End date", "Total amount", "Payments",
                      "Notice period", "Renewal", "Identifiers", "Source matching"]

struct DocumentReport {
    var name: String
    var scores: [String: FieldScore] = [:]
    var mistakes: [String] = []
    var highConfidenceErrors = 0
    var warnings: [String] = []
}

func f1(expected: Int, extracted: Int, matched: Int) -> Double {
    if expected == 0 && extracted == 0 { return 1 }
    guard expected > 0, extracted > 0 else { return 0 }
    let p = Double(matched) / Double(extracted), r = Double(matched) / Double(expected)
    return p + r == 0 ? 0 : 2 * p * r / (p + r)
}

func amountMinor(_ any: Any?) -> Int64? {
    if let n = any as? NSNumber { return Money(major: Decimal(n.doubleValue)).minorUnits }
    if let s = any as? String { return AmountParser.parseLoose(s)?.minorUnits }
    return nil
}

func accepted(_ fields: [ExtractedFieldDraft], _ kind: FieldKind) -> [ExtractedFieldDraft] {
    // Evaluate what the user would see first: the highest-confidence value.
    fields.filter { $0.kind == kind }.sorted { $0.confidence > $1.confidence }
}

func score(fields: [ExtractedFieldDraft], expected: [String: Any], name: String) -> DocumentReport {
    var rep = DocumentReport(name: name)
    func record(_ field: String, _ ok: Bool, _ detail: @autoclosure () -> String, confidence: Confidence?) {
        rep.scores[field, default: FieldScore()].add(ok ? 1 : 0)
        if !ok {
            rep.mistakes.append("\(field): \(detail())")
            if confidence == .high { rep.highConfidenceErrors += 1 }
        }
    }

    if expected.keys.contains("document_type") {
        let want = (expected["document_type"] as? String).flatMap(DocumentType.init(loose:))
        let got = accepted(fields, .documentType).first
        var gotType: DocumentType?
        if case .documentType(let t)? = got?.value { gotType = t }
        record("Document type", want == gotType, "expected \(want?.rawValue ?? "none"), got \(gotType?.rawValue ?? "none")", confidence: got?.confidence)
    }

    if let want = expected["parties"] as? [String] {
        let got = fields.filter { $0.kind == .party }.compactMap { f -> String? in
            if case .party(let p) = f.value { return p.name }
            return nil
        }
        let matched = want.filter { w in got.contains { PartyMatcher.similarity($0, w) >= PartyMatcher.matchThreshold } }.count
        let value = f1(expected: want.count, extracted: got.count, matched: matched)
        rep.scores["Parties", default: FieldScore()].add(value)
        if value < 1 { rep.mistakes.append("Parties: expected \(want), got \(got)") }
    }

    for (key, kind, label) in [("effective_date", FieldKind.effectiveDate, "Effective date"), ("end_date", .endDate, "End date")] {
        guard expected.keys.contains(key) else { continue }
        let want = (expected[key] as? String).flatMap(CalendarDate.init(iso:))
        let got = accepted(fields, kind).first
        let gotDate = got?.value.primaryDate
        record(label, want == gotDate, "expected \(want?.isoString ?? "none"), got \(gotDate?.isoString ?? "none")", confidence: got?.confidence)
    }

    if expected.keys.contains("total_amount") {
        let want = amountMinor(expected["total_amount"])
        let got = accepted(fields, .totalAmount).first
        let gotMinor = got?.value.primaryAmount?.minorUnits
        record("Total amount", want == gotMinor, "expected \(want.map { Money(minorUnits: $0).formatted } ?? "none"), got \(gotMinor.map { Money(minorUnits: $0).formatted } ?? "none")", confidence: got?.confidence)
    }

    if let want = expected["payments"] as? [[String: Any]] {
        let got = fields.filter { $0.kind == .payment }.compactMap { f -> PaymentValue? in
            if case .payment(let p) = f.value { return p }
            return nil
        }
        var used = Set<Int>()
        var matched = 0
        for w in want {
            let amount = amountMinor(w["amount"])
            let due = (w["due_date"] as? String).flatMap(CalendarDate.init(iso:))
            let recurrence = (w["recurrence"] as? String).flatMap(RecurrenceFrequency.init(loose:))
            if let i = got.indices.first(where: { i in
                !used.contains(i) && got[i].amount?.minorUnits == amount && got[i].due?.resolved == due
                    && (recurrence == nil || got[i].recurrence?.frequency == recurrence)
            }) {
                used.insert(i)
                matched += 1
            }
        }
        let value = f1(expected: want.count, extracted: got.count, matched: matched)
        rep.scores["Payments", default: FieldScore()].add(value)
        if value < 1 {
            let desc = got.map { "\($0.amount?.formatted ?? "?")@\($0.due?.resolved?.isoString ?? "none")" }
            rep.mistakes.append("Payments: expected \(want.count), matched \(matched), got \(desc)")
        }
    }

    if expected.keys.contains("notice_period_days") {
        let want = (expected["notice_period_days"] as? NSNumber)?.intValue
        let got = accepted(fields, .noticePeriod).first
        var days: Int?
        if case .duration(let d)? = got?.value { days = d.approximateDays }
        record("Notice period", want == days, "expected \(want.map(String.init) ?? "none"), got \(days.map(String.init) ?? "none")", confidence: got?.confidence)
    }

    if expected.keys.contains("renewal_automatic") {
        let want: Bool?? = expected["renewal_automatic"] is NSNull ? .some(nil) : .some((expected["renewal_automatic"] as? NSNumber)?.boolValue)
        let got = accepted(fields, .renewal).first
        var automatic: Bool??
        if case .renewal(let r)? = got?.value { automatic = .some(r.automatic) }
        // Expected null means "no renewal clause": correct only if nothing was extracted.
        let ok: Bool
        switch want {
        case .some(.none): ok = got == nil
        case .some(.some(let w)): ok = automatic == .some(w)
        case .none: ok = true
        }
        record("Renewal", ok, "expected \(String(describing: want ?? nil)), got \(got == nil ? "no renewal field" : String(describing: automatic ?? nil))", confidence: got?.confidence)
    }

    if let want = expected["identifiers"] as? [String] {
        let got = fields.filter { $0.kind == .identifier }.compactMap { f -> String? in
            if case .identifier(let i) = f.value { return i.value }
            return nil
        }
        let matched = Set(want).intersection(got).count
        let value = f1(expected: want.count, extracted: got.count, matched: matched)
        rep.scores["Identifiers", default: FieldScore()].add(value)
        if value < 1 { rep.mistakes.append("Identifiers: expected \(want), got \(got)") }
    }

    // Source matching: extracted facts that point at text actually containing them.
    let sourced = fields.filter { $0.kind != .clause }
    for f in sourced {
        let ok = f.source != nil && (f.source!.match == .exact || f.source!.match == .normalized) && f.valueVerifiedInSource != false
        rep.scores["Source matching", default: FieldScore()].add(ok ? 1 : 0)
    }
    return rep
}

// MARK: Run

let options = parseArguments()
guard !options.folders.isEmpty else {
    print("usage: doxi-eval [--provider anthropic] [--json report.json] <dataset-folder>...")
    exit(2)
}

var provider: (any ExtractionProvider)?
if options.provider == "anthropic" {
    guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty else {
        print("Set ANTHROPIC_API_KEY to evaluate the cloud provider.")
        exit(2)
    }
    provider = AnthropicExtractionProvider(apiKey: key, model: options.model)
}
let pipeline = ExtractionPipeline(provider: provider)

var reports: [DocumentReport] = []
var skipped: [String] = []
for folder in options.folders {
    let dir = URL(fileURLWithPath: folder)
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    for expectedURL in files.filter({ $0.lastPathComponent.hasSuffix(".expected.json") }).sorted(by: { $0.path < $1.path }) {
        guard let docURL = findDocument(for: expectedURL) else {
            skipped.append("\(expectedURL.lastPathComponent): no matching document file")
            continue
        }
        guard let data = try? Data(contentsOf: expectedURL),
              let expected = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            skipped.append("\(expectedURL.lastPathComponent): invalid JSON")
            continue
        }
        let (text, error) = loadText(docURL)
        guard let text else {
            skipped.append(error ?? docURL.lastPathComponent)
            continue
        }
        let outcome = await pipeline.run(text, today: options.today)
        var rep = score(fields: outcome.fields, expected: expected, name: "\(dir.lastPathComponent)/\(docURL.lastPathComponent)")
        rep.warnings = outcome.warnings
        reports.append(rep)
        if options.verbose {
            print("\n--- \(rep.name) extracted:")
            for f in outcome.fields {
                print("  [\(f.confidence.rawValue)] \(f.kind.rawValue): \(f.displayValue)  (\(f.origin.rawValue), \(f.source.map { "\($0.pageLabel) \($0.match.rawValue)" } ?? "no source"))")
            }
        }
    }
}

func pct(_ v: Double?) -> String {
    guard let v else { return "   n/a" }
    return String(format: "%5.0f%%", v * 100)
}

print("Doxi extraction evaluation — \(provider.map { "provider: \($0.displayName)" } ?? "on-device rules only")")
print(String(repeating: "=", count: 72))
for rep in reports {
    print("\nDocument: \(rep.name)")
    for field in reportedFields {
        guard let s = rep.scores[field] else { continue }
        print("  " + field.padding(toLength: 22, withPad: " ", startingAt: 0) + pct(s.ratio))
    }
    if rep.highConfidenceErrors > 0 { print("  ⚠︎ high-confidence errors: \(rep.highConfidenceErrors)") }
    for m in rep.mistakes { print("    ✗ \(m)") }
    for w in rep.warnings { print("    ! \(w)") }
}

var totals: [String: FieldScore] = [:]
for rep in reports {
    for (k, v) in rep.scores {
        // Per-document average so long documents do not dominate.
        if let r = v.ratio { totals[k, default: FieldScore()].add(r) }
    }
}
print("\n" + String(repeating: "=", count: 72))
print("Overall (\(reports.count) documents, mean of per-document scores)")
for field in reportedFields {
    guard let s = totals[field] else { continue }
    print("  " + field.padding(toLength: 22, withPad: " ", startingAt: 0) + pct(s.ratio) + "  (\(Int(s.total)) docs)")
}
print("  High-confidence errors: \(reports.reduce(0) { $0 + $1.highConfidenceErrors })")
if !skipped.isEmpty {
    print("\nSkipped:")
    for s in skipped { print("  - \(s)") }
}

if let path = options.jsonOut {
    let json: [String: Any] = [
        "provider": provider?.id ?? "rules",
        "documents": reports.map { r in
            ["name": r.name, "scores": r.scores.compactMapValues { $0.ratio }, "mistakes": r.mistakes,
             "high_confidence_errors": r.highConfidenceErrors] as [String: Any]
        },
        "overall": totals.compactMapValues { $0.ratio },
        "skipped": skipped,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
        FileManager.default.createFile(atPath: path, contents: data)
        print("\nWrote \(path)")
    }
}
