import Foundation

/// Converts a model response into field drafts, locating every value in the
/// document. Values that cannot be located are kept but marked unverified.
public struct LLMFieldMapper {
    let matcher: SourceMatcher

    public init(matcher: SourceMatcher) {
        self.matcher = matcher
    }

    public func map(_ r: LLMExtractionResponse) -> [ExtractedFieldDraft] {
        var out: [ExtractedFieldDraft] = []

        if let dt = r.documentType, let raw = dt.value?.value, let type = DocumentType(loose: raw) {
            out.append(draft(.documentType, .documentType(type), dt.sourceQuote, dt.page))
        }
        if let t = r.title, let raw = t.value?.value.trimmed(), !raw.isEmpty {
            out.append(draft(.title, .text(raw), t.sourceQuote, t.page))
        }
        for p in r.parties ?? [] where !p.name.trimmed().isEmpty {
            out.append(draft(.party, .party(PartyValue(name: p.name.trimmed(), role: p.role?.trimmed().nilIfEmpty)), p.sourceQuote, p.page))
        }
        if let e = r.effectiveDate, let v = dateValue(e.value?.value, text: nil) {
            out.append(draft(.effectiveDate, .date(v), e.sourceQuote, e.page))
        }
        if let e = r.endDate, let v = dateValue(e.value?.value, text: e.value?.value) {
            out.append(draft(.endDate, .date(v), e.sourceQuote, e.page))
        }
        if let n = r.renewal, n.automatic != nil || n.summary != nil || n.renewalTerm != nil {
            let term = n.renewalTerm.flatMap(DurationParser.parseSingle)
            let summary = (n.summary ?? n.sourceQuote ?? "Renewal terms").trimmed()
            out.append(draft(.renewal, .renewal(RenewalValue(automatic: n.automatic, term: term, summary: summary)), n.sourceQuote, n.page))
        }
        if let n = r.noticePeriod, let raw = n.value?.value, let d = DurationParser.parseSingle(raw) {
            out.append(draft(.noticePeriod, .duration(d), n.sourceQuote, n.page))
        }
        if let t = r.totalAmount, let raw = t.amount?.value, let m = AmountParser.parseLoose(raw, defaultCurrency: currency(t.currency)) {
            out.append(draft(.totalAmount, .money(m), t.sourceQuote, t.page))
        }
        for p in r.payments ?? [] {
            let amount = p.amount.flatMap { AmountParser.parseLoose($0.value, defaultCurrency: currency(p.currency)) }
            let due = dateValue(p.dueDate, text: p.dueDateText)
            guard amount != nil || due != nil else { continue }
            var notes: [String] = []
            if due == nil, let text = p.dueDateText?.trimmed(), !text.isEmpty { notes.append("Due: \(text) (no calendar date could be derived).") }
            let rec = p.recurrence.flatMap(RecurrenceFrequency.init(loose:)).map { Recurrence(frequency: $0) }
            let value = PaymentValue(amount: amount, due: due, label: p.description?.trimmed().nilIfEmpty ?? "Payment", recurrence: rec,
                                     payer: p.payer?.trimmed().nilIfEmpty, payee: p.payee?.trimmed().nilIfEmpty)
            var d = draft(.payment, .payment(value), p.sourceQuote, p.page)
            d.notes.append(contentsOf: notes)
            out.append(d)
        }
        for o in r.obligations ?? [] where !o.description.trimmed().isEmpty {
            let due = dateValue(o.dueDate, text: o.dueDateText)
            let rec = o.recurrence.flatMap(RecurrenceFrequency.init(loose:)).map { Recurrence(frequency: $0) }
            let category = ObligationCategory(loose: o.category ?? o.description)
            let value = ObligationValue(summary: o.description.trimmed(), responsibleParty: o.responsibleParty?.trimmed().nilIfEmpty,
                                        due: due, recurrence: rec, category: category == .payment ? .other : category)
            out.append(draft(.obligation, .obligation(value), o.sourceQuote, o.page))
        }
        for c in r.clauses ?? [] {
            guard let cat = ClauseCategory(loose: c.category) else { continue }
            let summary = (c.summary ?? c.sourceQuote ?? cat.displayName).trimmed()
            out.append(draft(.clause, .clause(ClauseValue(category: cat, summary: summary)), c.sourceQuote, c.page))
        }
        return out
    }

    func currency(_ s: String?) -> String {
        guard let s = s?.trimmed().uppercased(), !s.isEmpty else { return "INR" }
        if s == "₹" || s == "RS" || s == "RS." || s == "RUPEES" { return "INR" }
        return s.count == 3 ? s : "INR"
    }

    /// Reads an ISO/explicit date, else a relative phrase.
    func dateValue(_ explicit: String?, text: String?) -> DateValue? {
        if let e = explicit?.trimmed(), !e.isEmpty, let d = CalendarDate(iso: e) ?? DateParser.mentions(in: e, preferMonthFirst: matcher.preferMonthFirst).first?.date {
            return DateValue(date: d)
        }
        for candidate in [text, explicit] {
            if let t = candidate, let rel = RelativeDateParser.mentions(in: t).first {
                return .relative(rel.spec)
            }
        }
        return nil
    }

    func draft(_ kind: FieldKind, _ value: FieldValue, _ quote: String?, _ page: LooseString?) -> ExtractedFieldDraft {
        let pageIndex = page.flatMap { Int($0.value) }.map { $0 - 1 }
        var notes: [String] = []
        var span: SourceSpan?
        var verified: Bool?
        var occurrences = 1

        if let q = quote, let match = matcher.locate(quote: q, page: pageIndex, value: value, kind: kind) {
            occurrences = match.equallyGoodOccurrences
            switch matcher.verify(value, in: match.range) {
            case .verified:
                verified = true
                span = matcher.span(for: match.range, quality: match.quality)
            case .notApplicable:
                span = matcher.span(for: match.range, quality: match.quality)
            case .notFound:
                verified = false
                if let vm = matcher.locateValue(value, page: pageIndex, kind: kind) {
                    occurrences = vm.equallyGoodOccurrences
                    span = matcher.span(for: matcher.sentence(around: vm.range), quality: .valueOnly)
                    verified = true
                    notes.append("The AI's quote did not contain this value; it was found elsewhere in the document.")
                } else {
                    span = matcher.span(for: match.range, quality: match.quality)
                    notes.append("The quoted text was found, but it does not contain this value.")
                }
            }
            if match.quality == .fuzzy { notes.append("The source text matched approximately (possible OCR errors).") }
        } else if let vm = matcher.locateValue(value, page: pageIndex, kind: kind) {
            occurrences = vm.equallyGoodOccurrences
            span = matcher.span(for: matcher.sentence(around: vm.range), quality: .valueOnly)
            verified = true
            notes.append("The AI's quote was not found; the value was located in the document.")
        } else {
            notes.append("This could not be found in the document text.")
        }
        if occurrences > 1, let s = span {
            notes.append("This text appears \(occurrences) times in the document; the highlighted place (\(s.pageLabel)) may not be the one meant.")
        }
        return ExtractedFieldDraft(kind: kind, value: value, origin: .llm, source: span, notes: notes, valueVerifiedInSource: verified)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
