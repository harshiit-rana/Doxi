import XCTest
@testable import DoxiCore

final class DateParserTests: XCTestCase {
    private func dates(_ s: String, monthFirst: Bool = false) -> [String] {
        DateParser.mentions(in: s, preferMonthFirst: monthFirst).map(\.date.isoString)
    }

    func testIndianNumericDefaultsToDayFirst() {
        XCTAssertEqual(dates("Dated 05/10/2026"), ["2026-10-05"])
        XCTAssertEqual(dates("on 15-10-2026"), ["2026-10-15"])
        XCTAssertEqual(dates("on 15.10.2026."), ["2026-10-15"])
        XCTAssertEqual(dates("on 15/10/26"), ["2026-10-15"])
    }

    func testAmbiguityIsFlagged() {
        let m = DateParser.mentions(in: "05/10/2026").first
        XCTAssertEqual(m?.ambiguous, true)
        XCTAssertEqual(DateParser.mentions(in: "15/10/2026").first?.ambiguous, false)
        XCTAssertEqual(DateParser.mentions(in: "10/10/2026").first?.ambiguous, false)
    }

    func testMonthFirstWhenOnlyReadingPossible() {
        let m = DateParser.mentions(in: "10/15/2026").first
        XCTAssertEqual(m?.date.isoString, "2026-10-15")
        XCTAssertEqual(m?.monthFirst, true)
    }

    func testPreferMonthFirstReinterpretsAmbiguousDates() {
        XCTAssertEqual(dates("05/10/2026", monthFirst: true), ["2026-05-10"])
    }

    func testWrittenForms() {
        XCTAssertEqual(dates("15th October 2026"), ["2026-10-15"])
        XCTAssertEqual(dates("15 Oct, 2026"), ["2026-10-15"])
        XCTAssertEqual(dates("the 1st day of September, 2026"), ["2026-09-01"])
        XCTAssertEqual(dates("October 15, 2026"), ["2026-10-15"])
        XCTAssertEqual(dates("Sept 3rd 2026"), ["2026-09-03"])
        XCTAssertEqual(dates("15-Oct-2026"), ["2026-10-15"])
        XCTAssertEqual(dates("2026-10-15"), ["2026-10-15"])
    }

    func testInvalidDatesRejected() {
        XCTAssertEqual(dates("31/02/2026"), [])
        XCTAssertEqual(dates("Invoice No. 2026/10/15A"), [])
        XCTAssertEqual(dates("version 1.2.3"), [])
    }

    func testMultipleDates() {
        XCTAssertEqual(dates("from 15/09/2026 to 15/12/2026"), ["2026-09-15", "2026-12-15"])
    }

    func testCalendarArithmetic() {
        let jan31 = CalendarDate(year: 2026, month: 1, day: 31)!
        XCTAssertEqual(jan31.adding(months: 1).isoString, "2026-02-28")
        XCTAssertEqual(CalendarDate(year: 2028, month: 1, day: 31)!.adding(months: 1).isoString, "2028-02-29")
        XCTAssertEqual(jan31.adding(days: 30).isoString, "2026-03-02")
        XCTAssertEqual(CalendarDate(year: 2026, month: 12, day: 15)!.adding(days: -30).isoString, "2026-11-15")
        XCTAssertEqual(jan31.days(until: CalendarDate(year: 2026, month: 3, day: 2)!), 30)
        XCTAssertEqual(CalendarDate(year: 2026, month: 10, day: 5)!.numericString, "05/10/2026")
    }

    func testRelativeDates() {
        let m = RelativeDateParser.mentions(in: "payable within 30 days of signing of this Agreement").first
        XCTAssertEqual(m?.spec.offset, Duration(value: 30, unit: .days))
        XCTAssertEqual(m?.spec.after, true)
        XCTAssertEqual(m?.spec.anchor, .signing)

        let inv = RelativeDateParser.mentions(in: "due fifteen (15) days from the date of invoice").first
        XCTAssertEqual(inv?.spec.offset.value, 15)
        XCTAssertEqual(inv?.spec.anchor, .invoiceDate)

        let before = RelativeDateParser.mentions(in: "at least 60 days prior to the expiry of this Agreement").first
        XCTAssertEqual(before?.spec.after, false)
        XCTAssertEqual(before?.spec.anchor, .endDate)
    }

    func testRelativeDateDerivationShowsBase() {
        var spec = RelativeDateSpec(offset: Duration(value: 30, unit: .days), after: true, anchor: .effectiveDate, anchorText: "the Effective Date")
        XCTAssertNil(spec.derivedDate)
        spec.baseDate = CalendarDate(year: 2026, month: 9, day: 15)
        XCTAssertEqual(spec.derivedDate?.isoString, "2026-10-15")
        XCTAssertEqual(DateValue.relative(spec).formatted, "15/10/2026 (30 days after the Effective Date: base 15/09/2026)")
    }

    func testDurations() {
        XCTAssertEqual(DurationParser.parseSingle("thirty (30) days"), Duration(value: 30, unit: .days))
        XCTAssertEqual(DurationParser.parseSingle("one month"), Duration(value: 1, unit: .months))
        XCTAssertEqual(DurationParser.parseSingle("2 weeks'"), Duration(value: 2, unit: .weeks))
        XCTAssertEqual(DurationParser.parseSingle("30 days' written notice"), Duration(value: 30, unit: .days))
        XCTAssertNil(DurationParser.parseSingle("holidays"))
    }
}
