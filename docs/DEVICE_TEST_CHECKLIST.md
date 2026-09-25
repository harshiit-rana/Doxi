# Device test checklist (manual)

These checks need a physical iPhone/iPad, real documents or real notification
delivery, so CI cannot cover them. Record results in `docs/VALIDATION.md`.

Setup: install a Debug or TestFlight build, set a development team and a real
App Group ID in `project.yml`, and complete the identity setup with your real
name, business name and aliases.

## 1. Capture
- [ ] Scan a 3-page paper contract with the camera. Pages are detected, cropped and deskewed.
- [ ] In the page review: reorder pages, rotate one, enhance one, delete one, then "Save PDF". The resulting document has the expected page order.
- [ ] Cancel the scanner halfway. No document is created and no error is shown.
- [ ] Import a text PDF, a multi-page scanned PDF, a JPEG and a HEIC photo from Files.
- [ ] Cancel the Files picker. No error.
- [ ] Import a password-protected PDF. You get a clear message; nothing crashes.

## 2. Share Extension
- [ ] WhatsApp → a PDF → Share → Doxi. The sheet says "Saved to Doxi".
- [ ] WhatsApp → a photo of an invoice → Share → Doxi.
- [ ] Share a non-document (a contact or link). You get a clear "only PDFs and images" message.
- [ ] Open Doxi. The shared documents appear, are processed, and a banner confirms the import.
- [ ] Force-quit Doxi before opening it after sharing. The files are still imported on the next launch.

## 3. OCR and source highlighting (for every extracted field)
- [ ] Tap the field. The original opens on the right page, and the highlight covers text that actually supports the value.
- [ ] Text PDF: the highlight hugs the exact words.
- [ ] Scanned PDF / photo: the highlight box sits on the right line.
- [ ] Same amount twice (e.g. total and a penalty): the total field highlights the total, not the penalty.
- [ ] Same sentence on two pages: the highlight goes to the page named, or the note says the text appears more than once.
- [ ] Rotated/sideways scan: the page shows upright after processing and highlights line up.
- [ ] A payment whose due date is on a different line shows two quotes, and each opens its own place.

## 4. Review, identity and obligations
- [ ] Your name in the document: you are matched automatically, with "Matched to your profile".
- [ ] Only your surname / first name in the document: Doxi asks "Who are you in this document?".
- [ ] You are neither party: choose "Neither / Other"; payments show "Not my payment".
- [ ] Confirm an Unverified field: an extra prompt asks you to check it yourself.
- [ ] Edit ₹40,000 to ₹45,000 and confirm. The obligation shows ₹45,000, and the source still shows what the document says.
- [ ] Leave some fields unchecked and finish. Only confirmed fields create obligations.
- [ ] Run extraction again on a confirmed document. It stays tracked and its reminders continue.

## 5. Notifications (set a due date 1–2 days ahead by editing a payment)
- [ ] First confirmation asks for notification permission.
- [ ] A day-of reminder arrives at the configured time; tapping it opens the document.
- [ ] Mark the payment received before its reminder. The reminder does not arrive.
- [ ] Cancel an obligation. Its reminders stop.
- [ ] Recurring rent: mark this month paid. The next month's due date and reminders appear.
- [ ] Deny notification permission. Home and Settings explain that reminders cannot alert you and link to Settings.
- [ ] Change the default reminder time in Settings. Pending reminders move.

## 6. Search
- [ ] Company name, person name, ₹ amount in several formats, a month, a full date, the document type, an OCR-only phrase, an obligation title. Each result opens the correct document.

## 7. Failure cases
- [ ] Airplane mode + "Improve with Claude": a clear network message; on-device results remain.
- [ ] Invalid API key: "The API key was rejected".
- [ ] A 100+ page PDF: progress shows "Reading page X of Y"; memory stays reasonable (check in Xcode's memory gauge); no crash.
- [ ] A blank page and a very poor photo: warnings are shown; nothing is invented.

## 8. Privacy and security
- [ ] App lock on: backgrounding and returning requires Face ID or passcode.
- [ ] With cloud extraction off (default), no network traffic occurs while importing and processing (check with a proxy or the network gauge).
- [ ] A document processed with Claude says so on its detail and review screens.

## 9. iPad
- [ ] Portrait and landscape: all tabs are usable, sheets and the PDF viewer size correctly, and the Share Extension works.
