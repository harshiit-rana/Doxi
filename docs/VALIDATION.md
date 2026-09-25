# Doxi Phase 1 — validation report

_Last updated: 2026-09-25. Everything below was run by the development agent in CI
(GitHub Actions: Ubuntu + macOS 15 / Xcode 26.3 / iOS 26.2 simulator) or in a Linux
container. **No physical iPhone or iPad and no real-world documents were available.**
Nothing on this page should be read as real-document validation._

```text
DOXI PHASE 1 VALIDATION

Build:                       PASS  (app, share extension, unit and UI test targets; Xcode 26.3, iOS 26.2 SDK; no warnings in Doxi sources)
Unit tests (DoxiCore):       PASS  — 131 tests, Linux and macOS
Reader integration (macOS):  PASS  — 6 tests: real PDFKit + Vision on generated text PDFs, scans, a sideways scan, a blank page, corrupt/empty files
App tests (simulator):       see "App and UI tests" below
End-to-end UI test:          see "App and UI tests" below

Real documents tested:       0   ← the real evaluation set has not been supplied yet

Extraction accuracy — rules only, SYNTHETIC documents (not a real-world estimate):
                         holdout-2 first run   holdout-2 after fixes   dev set (tuned)
  Parties                        75%                  100%                 100%
  Dates                         100%                  100%                 100%
  Amounts                       100%                  100%                 100%
  Payment schedules              57%                  100%                 100%
  Renewals                      100%                  100%                 100%
  Notice periods                100%                  100%                 100%
  Obligations                    n/a                   n/a                 100% (2 docs labelled)
  Source matching               100%                  100%                 100%
  Document type                  60%                   80%                 100%
  High-confidence errors          1                     1                    0

Search:            PASS in unit tests and (see below) the simulator run; not tested on device
Notifications:     planning logic PASS in tests; delivery on a device NOT TESTED
Share Extension:   builds and embeds; inbox import logic tested; on-device share flow NOT TESTED
```

## What was actually run

| Area | How it was validated | Result |
|---|---|---|
| Build | `xcodegen generate` + `xcodebuild test` on macOS 15, iOS 26.2 simulator | Pass |
| Core logic | `swift test` (Linux + macOS) | Pass |
| OCR + highlight geometry | Generated PDFs with text drawn at known coordinates; real PDFKit/Vision read them; the highlight must cover the drawn text rectangle and not the neighbouring line | Pass (text PDF, 2-page scan, sideways scan) |
| Blank page / corrupt / empty PDF | Reader integration tests | Handled without crash; blank page produces a warning and no text |
| Extraction semantics | 13 false-positive tests: total vs advance vs deposit vs penalty vs example vs already-paid vs monthly; signing/effective/expiry/invoice/due/reference/example dates; relative deadlines vs notice periods | Pass after fixes |
| Party matching | The four scenarios from the plan (clear, alias, surname-only, no match) + first-name collision | Pass after fix |
| Confirmation rules | Unverified/pending/rejected never create obligations; edited values drive obligations while the source still shows the document text | Pass |
| Reminders | Offsets 30/14/7/0, past dates skipped, completed/received/cancelled/dismissed get none, recurring occurrences, 64-notification limit (60 scheduled), stable IDs | Pass (planning logic); real delivery not tested |
| Search | Company, partial word, ₹ amount in 5 formats, month, full date, document type, OCR-only phrase, no-results | Pass |
| Performance | See below | Measured |
| Security/privacy | Code audit (below) | Issues fixed |

## Bugs found and fixed during validation

Critical (would give wrong or unsupported information):
1. **Derived dates were stored as if written in the document.** "Within 30 days of invoice", "5th of each month" and "a period of 11 months" produced plain dates. Fixed: stored as calculated, with the base date and rule shown ("Calculated: 30 days after invoice, base date 15/09/2026").
2. **A surname or first name alone matched the user automatically** ("Rana", "Harshit Mehta"). Fixed: a single shared word only makes the party a candidate, and Doxi asks.
3. **Tapping a field in the document screen did not open its source** (simulator E2E run; both sheet and push attempts failed when triggered from a Button inside a List row). Fixed by making the rows `NavigationLink`s; see the UI-test status below.
4. **Already-paid amounts became payment obligations** ("has paid a security deposit", "received with thanks"). Fixed.
5. **Document type was non-deterministic on short documents** (NDA vs contract tie decided by dictionary order). Fixed with a deterministic tie-break.

Medium:
6. Source matching picked the first occurrence of repeated text. It now prefers the occurrence that contains the value, then the page the model named, then context; remaining ties are shown to the user ("appears 2 times…").
7. A payment whose amount and due date sit on different lines highlighted only the amount. Fields now carry every supporting span, and all of them are shown.
8. OCR digit confusions ("O1/12/2026", "50,OOO", "Payrnent") broke dates, amounts and quote matching. Now repaired for parsing, while quotes still show the scanned text.
9. Payment-schedule tables, "Net 30" terms, numbered multi-party lists and "₹X in two parts" were not understood.
10. Re-running extraction on a confirmed document dropped it back to "needs review", which silently stopped its reminders.
11. Sideways scans were read correctly but left displayed sideways.
12. Search re-normalised every document on every keystroke (11 s for 500 documents in a debug build). Now 0.06 s, using keys precomputed at import.
13. The SwiftData store (which holds OCR text) used default file protection; it is now `completeUnlessOpen` (and existing stores are moved).
14. The onboarding cover and storage alert used `.constant` bindings, which can leave SwiftUI's presentation state stale.

Minor:
15. Cancelling the Files picker could show an error alert.
16. Invoice and letter dates were labelled "Effective date" (now "Document date"; a quotation's end date is "Valid until").
17. Confirming an Unverified field now asks for explicit confirmation.
18. Reading progress ("Reading page 3 of 12") is shown while OCR runs.
19. The Claude API call uses an ephemeral URL session (no cache or cookies on disk).

## Known remaining issues (not fixed)

- **Real-world accuracy is unknown.** All accuracy numbers come from synthetic documents written by the agent. The rules were tuned on the development set and on holdout-2 after its first run.
- Notice periods phrased without the word "notice" ("inform at least 30 days before expiry") are missed.
- Deadlines like "the website will go live by 20/11/2026" are not treated as an end date or obligation.
- Classification of borderline types (service agreement vs contract, freelance vs contract) is a judgement call; there is 1 high-confidence document-type error on holdout-2.
- No reminders after a payment becomes overdue (it stays visible as Overdue on Home).
- Tables with multi-line cells, multi-column layouts, handwriting and non-English text are not handled.
- Cloud (Claude) extraction has never been run against the live API in this project (no key available); only request/response handling with mocked responses is tested.
- The Apple on-device model provider compiles against the iOS 26 SDK but has never run.

## Performance (measured)

| Measurement | Environment | Result |
|---|---|---|
| Read a 60-page text PDF | macOS runner, debug | 0.04 s |
| Extract fields from the 60-page PDF | macOS runner, debug | 0.21 s |
| OCR a scanned page (Vision, accurate) | macOS runner | ~1.8 s/page |
| Extract an 11.5k-character contract | Linux, debug | 0.14 s |
| Build search keys for 500 documents (once, at import) | Linux, debug | 1.2 s total |
| Search 500 documents | Linux, debug | 0.06 s (was 11 s) |
| Plan reminders for 1,000 obligations | Linux, debug | 0.06 s |
| Memory on large PDFs | — | not measured (needs a device; per-page autorelease added) |

## Security and privacy audit

- No API keys or secrets in source or git history (searched for key patterns). The Anthropic key is stored in the Keychain (`WhenUnlockedThisDeviceOnly`).
- No logging of document content (`print`/`NSLog`/`os_log` absent from app and library code).
- Documents: Application Support with `FileProtectionType.complete`. Store: `completeUnlessOpen`. Share inbox files: `complete`, deleted after import (also on failure).
- Temporary files: only in the DEBUG-only UI-test harness.
- Network: only the optional Claude call (`api.anthropic.com`), which is off by default, per document or opt-in, and disclosed in the UI; it sends recognised text, not the file.
- UI-test support code is compiled only in DEBUG and runs only with the `-uitest` launch argument.

## What is needed to finish validation

1. Add 10–15 real, anonymised documents with hand-written labels to `Evaluation/datasets/real/` (see `Evaluation/README.md`) and run `swift run doxi-eval ../Evaluation/datasets/real` on a Mac.
2. Work through `docs/DEVICE_TEST_CHECKLIST.md` on an iPhone and an iPad.
3. Optionally run the evaluation with `--provider anthropic` to measure the cloud extractor.
