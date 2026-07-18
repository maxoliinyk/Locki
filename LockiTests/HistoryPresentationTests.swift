//
//  HistoryPresentationTests.swift
//  LockiTests
//
//  Created by Max Oliinyk on 18.07.2026.
//

import Foundation
import Testing
@testable import Locki

@Suite("History presentation")
struct HistoryPresentationTests {
    @Test("Zero distance uses metres instead of centimetres")
    func zeroDistanceUsesMetres() {
        #expect(0.0.formattedDistance(locale: testLocale) == "0 m")
    }

    @Test("Sub-metre distances round to whole metres")
    func subMetreDistancesUseWholeMetres() {
        #expect(0.01.formattedDistance(locale: testLocale) == "0 m")
        #expect(0.49.formattedDistance(locale: testLocale) == "0 m")
        #expect(0.5.formattedDistance(locale: testLocale) == "1 m")
        #expect(0.99.formattedDistance(locale: testLocale) == "1 m")
    }

    @Test("Distance changes from metres to kilometres at one kilometre")
    func distanceUnitBoundary() {
        #expect(1.0.formattedDistance(locale: testLocale) == "1 m")
        #expect(999.4.formattedDistance(locale: testLocale) == "999 m")
        #expect(999.5.formattedDistance(locale: testLocale) == "1,000 m")
        #expect(1_000.0.formattedDistance(locale: testLocale) == "1 km")
        #expect(1_250.0.formattedDistance(locale: testLocale) == "1.3 km")
    }

    @Test("Invalid distance values safely display zero metres")
    func invalidDistancesDisplayZero() {
        #expect((-1.0).formattedDistance(locale: testLocale) == "0 m")
        #expect(Double.nan.formattedDistance(locale: testLocale) == "0 m")
        #expect(Double.infinity.formattedDistance(locale: testLocale) == "0 m")
    }

    @Test("Day range follows a daylight-saving calendar day")
    func daylightSavingDayRange() throws {
        let calendar = try berlinCalendar()
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 12)))
        let range = HistoryPeriod.day.range(containing: date, now: date, calendar: calendar)

        #expect(range.interval.duration == 23 * 3_600)
        #expect(calendar.component(.day, from: range.interval.start) == 29)
        #expect(calendar.component(.day, from: range.interval.end) == 30)
    }

    @Test("Week range respects the calendar locale")
    func localizedWeekStart() throws {
        let dateComponents = DateComponents(year: 2026, month: 7, day: 15, hour: 12)
        let usCalendar = gregorianCalendar(locale: Locale(identifier: "en_US"), timeZone: .gmt)
        let germanCalendar = gregorianCalendar(locale: Locale(identifier: "de_DE"), timeZone: .gmt)
        let date = try #require(usCalendar.date(from: dateComponents))

        let usRange = HistoryPeriod.week.range(containing: date, now: date, calendar: usCalendar)
        let germanRange = HistoryPeriod.week.range(containing: date, now: date, calendar: germanCalendar)

        #expect(usCalendar.component(.day, from: usRange.interval.start) == 12)
        #expect(germanCalendar.component(.day, from: germanRange.interval.start) == 13)
    }

    @Test("Month range includes leap day")
    func leapMonthRange() throws {
        let calendar = gregorianCalendar(locale: testLocale, timeZone: .gmt)
        let date = try #require(calendar.date(from: DateComponents(year: 2024, month: 2, day: 15)))
        let range = HistoryPeriod.month.range(containing: date, now: date, calendar: calendar)

        #expect(calendar.dateComponents([.day], from: range.interval.start, to: range.interval.end).day == 29)
        #expect(calendar.component(.month, from: range.interval.end) == 3)
    }

    @Test("Period navigation crosses years and does not advance beyond now")
    func periodNavigationBoundaries() throws {
        let calendar = gregorianCalendar(locale: testLocale, timeZone: .gmt)
        let december = try #require(calendar.date(from: DateComponents(year: 2025, month: 12, day: 15)))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 20)))
        let january = HistoryPeriod.month.date(byAdvancing: december, value: 1, now: now, calendar: calendar)

        #expect(calendar.component(.year, from: january) == 2026)
        #expect(calendar.component(.month, from: january) == 1)
        #expect(HistoryPeriod.month.canAdvance(from: december, now: now, calendar: calendar))
        #expect(!HistoryPeriod.month.canAdvance(from: january, now: now, calendar: calendar))
        #expect(HistoryPeriod.month.date(byAdvancing: january, value: 1, now: now, calendar: calendar) == now)
    }

    @Test("Future selections clamp to the current period")
    func futureSelectionClampsToNow() throws {
        let calendar = gregorianCalendar(locale: testLocale, timeZone: .gmt)
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 18, hour: 12)))
        let future = try #require(calendar.date(byAdding: .day, value: 10, to: now))
        let range = HistoryPeriod.day.range(containing: future, now: now, calendar: calendar)
        let previous = HistoryPeriod.day.date(
            byAdvancing: future,
            value: -1,
            now: now,
            calendar: calendar
        )

        #expect(calendar.isDate(range.anchor, inSameDayAs: now))
        #expect(calendar.isDate(range.interval.start, inSameDayAs: now))
        #expect(previous == now)
    }

    @Test("All-time range uses the earliest history date and current time")
    func allTimeRange() throws {
        let calendar = gregorianCalendar(locale: testLocale, timeZone: .gmt)
        let earliest = try #require(calendar.date(from: DateComponents(year: 2024, month: 2, day: 29, hour: 8)))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 18, hour: 12)))
        let range = HistoryPeriod.all.range(
            containing: now,
            earliestDate: earliest,
            now: now,
            calendar: calendar
        )

        #expect(range.interval.start == earliest)
        #expect(range.interval.end == now)
        #expect(!HistoryPeriod.all.canAdvance(from: earliest, now: now, calendar: calendar))
        #expect(range.title(locale: testLocale) == "All Time")
    }

    @Test("Range titles omit time-of-day values")
    func rangeTitlesContainDatesOnly() throws {
        let calendar = gregorianCalendar(locale: testLocale, timeZone: .gmt)
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 18, hour: 12)))

        for period in [HistoryPeriod.day, .week, .month, .year] {
            let title = period.range(containing: date, now: date, calendar: calendar).title(locale: testLocale)
            #expect(!title.contains(":"))
            #expect(!title.contains("00"))
        }
    }

    private var testLocale: Locale { Locale(identifier: "en_US") }

    private func berlinCalendar() throws -> Calendar {
        try gregorianCalendar(
            locale: Locale(identifier: "de_DE"),
            timeZone: #require(TimeZone(identifier: "Europe/Berlin"))
        )
    }

    private func gregorianCalendar(locale: Locale, timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        return calendar
    }
}
