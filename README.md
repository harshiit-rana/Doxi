# Doxi — Phase 1

**Every document you sign knows what you agreed to.**

Doxi is a native iPhone/iPad app for Indian freelancers and small agencies. Phase 1 turns a
contract, NDA, invoice or business letter into verified, source-linked facts and tracked
obligations:

```
Capture → Read text → Extract → Show source → Verify → Confirm → Obligation → Reminder → Search
```

Phase 1 only. Signing, PDF editing, templates, conversions, subscriptions, cloud sync,
AI Q&A and India-specific workflows are intentionally **not** built (see *Not in Phase 1*).

## What works

| Step | Implementation |
|---|---|
| Scan | `VNDocumentCameraViewController` (page detection, perspective correction, crop, multi-page) → page review (reorder, rotate, enhance, delete) → PDF |
| Import | Files picker for PDFs and images (images become PDFs). "Open in Doxi" for PDFs. |
| Share-in | Share Extension (`ShareExtension/`) saves PDFs/images from WhatsApp etc. into an App Group inbox; the app imports and processes them when it becomes active. |
| Storage | PDFs in Application Support with `FileProtectionType.complete`; SwiftData for records; optional Face ID / passcode lock. |
| Text + locations | PDFKit text with per-line PDF ranges for text PDFs; Vision OCR (`.accurate`, rotation retries) with line/fragment boxes for scans (`DoxiReader`). |
| Deterministic extraction | Dates (DD/MM/YYYY default, written dates, US-order detection), ₹/Rs./INR amounts incl. lakh/crore and amounts in words, relative dates ("within 30 days of signing"), durations, GSTIN/PAN/Aadhaar (Verhoeff, masked), parties, effective/end dates, term length, notice period, renewal, totals, instalments, recurring rent/retainers, deliverables, clause locations. |
| LLM extraction | `ExtractionProvider` protocol. Claude via the Anthropic Messages API (structured JSON output, key in Keychain, off by default, explicit per-document send). Apple's on-device model (iOS 26+) where available. |
| Source matching | Every model value must come with a verbatim quote; `SourceMatcher` finds it (exact → normalised → fuzzy OCR-tolerant) and checks the value is inside it. Otherwise the field is **Unverified**. |
| Confidence | High / Medium / Low / Unverified from *how* the fact was found (rule strength, rules+AI agreement, quote match, OCR quality, ambiguous date format, conflicts) — never from the model's say-so. |
| Review | Every field shows value, confidence, notes and its quote; tap to open the PDF at that spot with the text highlighted. Confirm / edit / reject each field, resolve conflicts, add missing details manually. |
| Identity | One-time profile (name, business, aliases, GSTIN). Parties are matched to it; if not exactly one clear match, Doxi asks "Who are you in this document?" and remembers the answer per document. |
| Obligations | Built only from accepted fields: payments (with owed-to-me / I-owe direction), renewal, contract end, notice deadline (derived, with its base shown), deliverables. Statuses upcoming/pending/overdue/received/completed/cancelled/dismissed; recurring obligations advance to the next occurrence. Nothing is ever marked received automatically. |
| Reminders | `UserNotifications`, configurable offsets (30/14/7/3/1/0 days) and time; nearest 60 of iOS's 64-notification limit are scheduled and re-planned on every launch/change. Permission denial is surfaced with a link to Settings. |
| Dashboard | Overdue, upcoming (30/90 days), Owed to me / I owe from confirmed open payments, documents needing review, processing status. |
| Search | Local search over filenames, OCR/PDF text, parties, amounts in any format (₹80,000 / 80k / 0.8 lakh), months and dates, document types, obligations; results show matched details and obligation status and open the document. |

## Repository layout

```
DoxiCore/                  Swift package — all Phase 1 logic, builds and tests on Linux and macOS
  Sources/DoxiCore/        text model + source spans, deterministic extraction, LLM contract + Anthropic
                           provider, source matching, confidence, merging, party matching, obligations,
                           recurrence, reminder planning, search
  Sources/DoxiReader/      PDFKit text + Vision OCR (Apple platforms), shared by the app and doxi-eval
  Sources/DoxiEval/        evaluation command-line tool
  Tests/DoxiCoreTests/     unit tests
App/                       SwiftUI app: SwiftData models, services, views
ShareExtension/            share-sheet extension
AppTests/                  app-level tests (in-memory SwiftData)
Evaluation/                datasets + instructions (see Evaluation/README.md)
project.yml                XcodeGen project definition
```

Architecture: **Views → services (`AppServices`, `DocumentProcessor`, `ObligationService`,
`NotificationScheduler`) → DoxiCore domain + pipeline → DoxiReader (OCR/PDF text) → SwiftData.**
Views never call OCR or model providers directly.

## Build and run

Requires Xcode 15.3+ (Xcode 26 for the Apple on-device model), iOS 17+.

```sh
brew install xcodegen
xcodegen generate
open Doxi.xcodeproj
```

Set your development team, and if you change the bundle identifier also change
`APP_GROUP_ID` in `project.yml` (the app and the share extension must share the App Group).

Core tests and evaluation (macOS or Linux):

```sh
cd DoxiCore
swift test
swift run doxi-eval ../Evaluation/datasets/synthetic-temporary ../Evaluation/datasets/synthetic-holdout
```

CI (`.github/workflows/ci.yml`) runs the core tests and evaluation on Linux and builds and
tests the app on a macOS runner.

### Cloud extraction (optional)

Settings → Cloud AI → enable, paste an Anthropic API key (stored in the Keychain). Then use
**Improve with Claude** on a document's Review screen, or enable "Use for every new document".
Only the recognised text is sent, and the app says so on the document. Default model:
`claude-opus-5` (changeable in Settings).

## Privacy

- Scanning, OCR, rule-based extraction, search and reminders run on the device.
- Documents are stored in the app's private container with complete file protection.
- Cloud extraction is off by default, per-document and disclosed; the file itself is never uploaded.
- No API keys are bundled. Doxi does not use documents for training.
- Doxi identifies and organises what a document says; it does not give legal advice.

## Testing

- `DoxiCore/Tests`: dates (Indian/US order, written, relative), amounts (₹, Rs., INR,
  lakh/crore, words), identifiers, deterministic extraction on contracts/rent/invoices,
  source matching (exact/normalised/fuzzy/page hints/boxes/rotation), OCR line assembly,
  party matching and payment direction, pipeline merging/conflicts/hallucination handling,
  Anthropic request/response/error mapping (mocked transport), obligations, recurrence,
  money totals, reminder planning (offsets, 64 limit, recurrence, stable IDs), search.
- `DoxiCore/Tests/DoxiReaderTests` (macOS): real PDFKit/Vision reading of generated text PDFs, scans, sideways scans and blank pages, with highlight rectangles checked against where the text was drawn.
- `AppTests`: SwiftData round-trips, identity matching (including documents imported before onboarding), review → obligations, edited values, reminders only for confirmed open obligations, re-extraction, share-inbox import and cleanup, corrupt imports.
- `AppUITests`: the full workflow end to end in the simulator (see docs/VALIDATION.md).
- `Evaluation/`: per-document, per-field accuracy. **The real-document set still needs to
  be supplied** — see `Evaluation/README.md`.

## Validation status

See **[docs/VALIDATION.md](docs/VALIDATION.md)** for what has been tested, how, and the bugs found.
In short: the build, 125 core tests, 6 PDFKit/Vision integration tests, 11 app tests and a full end-to-end UI test in the
iOS simulator pass in CI. **No real documents and no physical device have been tested yet.** Accuracy figures so far come
from synthetic documents only. Use `docs/DEVICE_TEST_CHECKLIST.md` and `Evaluation/README.md` to finish validation.

## Known limitations

- The evaluation set is synthetic until real documents are added; accuracy on real,
  messy documents is not yet measured. Rule-based results on the held-out synthetic set
  are noticeably lower than on the development set (see `Evaluation/README.md`).
- The rules read English documents; Hindi and other languages are not handled.
- Tables that OCR splits oddly, multi-column layouts and handwriting will reduce accuracy.
- Overdue payments stay visible but do not get extra reminders after the due date.
- iPad uses the same (adaptive) layout as iPhone; a dedicated iPad layout is future work.
- There is no data model for multiple user identities or teams.

## Not in Phase 1

Electronic signing, PDF editing/annotation, document templates or creation, file
conversions, subscriptions/paywall, advanced iPad layouts, GST/Aadhaar/PAN workflows,
DigiLocker, multi-party signing, cloud sync, AI Q&A. None of these have placeholder screens.
