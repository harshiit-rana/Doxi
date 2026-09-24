# Extraction evaluation

`doxi-eval` runs labelled documents through the same extraction pipeline the app
uses and reports accuracy per document and per field.

```sh
cd DoxiCore
swift run doxi-eval ../Evaluation/datasets/real                       # on-device rules
ANTHROPIC_API_KEY=… swift run doxi-eval --provider anthropic ../Evaluation/datasets/real
swift run doxi-eval --verbose --json ../Evaluation/reports/latest.json ../Evaluation/datasets/*
```

Example output:

```text
Document: real/freelance_contract_01.pdf
  Document type           100%
  Parties                 100%
  Effective date          100%
  End date                100%
  Total amount            100%
  Payments                 67%
  Notice period           100%
  Renewal                 100%
  Source matching          94%
    ✗ Payments: expected 3, matched 2, got ["₹40,000@2026-10-15", "₹40,000@none"]
```

**Source matching** is the share of extracted facts whose source span is an exact or
normalised match of document text that contains the value. **High-confidence
errors** counts values shown as "High confidence" that disagree with the label —
the number that matters most for trust.

## Datasets

| Folder | What it is |
|---|---|
| `datasets/real/` | **The evaluation set that counts.** 10–15 real documents from your own work (anonymise names, account numbers, Aadhaar/PAN as needed). Git-ignored by default so client documents are never committed by accident. |
| `datasets/synthetic-temporary/` | **Temporary**, written by the development agent to exercise the harness before real documents exist. The rules were developed against these, so their scores say little about real-world accuracy. Replace, don't extend. |
| `datasets/synthetic-holdout/` | Four more synthetic documents written *after* the rules and never tuned on. A slightly fairer sanity check than the set above, but still synthetic. |

Current rule-only results (for orientation only — not a real accuracy estimate):

| Field | synthetic-temporary (10 docs, tuned on) | synthetic-holdout (4 docs, not tuned on) |
|---|---|---|
| Document type | 100% | 75% |
| Parties | 100% | 92% |
| Effective date | 100% | 50% |
| End date | 100% | 50% |
| Total amount | 100% | 100% |
| Payments | 100% | 62% |
| Notice period | 100% | 50% |
| Renewal | 100% | 100% |
| Source matching | 100% | 100% |
| High-confidence errors | 0 | 1 |

## Adding a real document

1. Put the file in `datasets/real/`: `.pdf`, `.jpg/.png/.heic` (a WhatsApp photo is ideal),
   or `.txt`. PDFs and images need macOS (PDFKit + Vision, the same OCR path as the app);
   on Linux use `.txt`.
2. Write `name.expected.json` next to it **by reading the document yourself**. Never
   copy values from Doxi's output — that would make the extractor grade itself.

```json
{
  "document_type": "freelance_agreement",
  "parties": ["ABC Technologies Private Limited", "Harshit Rana"],
  "effective_date": "2026-09-15",
  "end_date": "2026-12-15",
  "total_amount": 80000,
  "payments": [
    {"amount": 40000, "due_date": "2026-10-15"},
    {"amount": 40000, "due_date": "2026-11-15", "recurrence": null}
  ],
  "notice_period_days": 30,
  "renewal_automatic": false,
  "identifiers": ["29AABCA1234F1Z5"]
}
```

Rules for labels:

- Leave a key out to not score that field.
- `null` means "the document does not contain this": the field is correct only if
  nothing was extracted (e.g. `"renewal_automatic": null` for no renewal clause).
- Dates are ISO `YYYY-MM-DD`, amounts are plain numbers in the document's currency.
- A payment's `due_date` is `null` when the document gives no calendar date
  ("on delivery"); relative dates should be labelled with the date a person would
  compute (e.g. 15 days after a 05/09/2026 invoice → `2026-09-20`).
- `document_type` is one of: `freelance_agreement`, `service_agreement`, `contract`,
  `nda`, `invoice`, `quotation`, `vendor_agreement`, `rental_agreement`,
  `payment_schedule`, `purchase_order`, `business_letter`, `other`.
