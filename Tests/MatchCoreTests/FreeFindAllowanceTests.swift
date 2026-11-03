import XCTest
@testable import MatchCore

final class FreeFindAllowanceTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func testNewAllowanceHasTwoFreeFinds() {
        XCTAssertEqual(FreeFindAllowance().remaining(on: date(4, 9), calendar: calendar), 2)
    }

    func testConsumingStopsAtZeroForTheDay() {
        var allowance = FreeFindAllowance()
        XCTAssertTrue(allowance.consume(on: date(4, 9), calendar: calendar))
        XCTAssertEqual(allowance.remaining(on: date(4, 9), calendar: calendar), 1)
        XCTAssertTrue(allowance.consume(on: date(4, 18), calendar: calendar))
        XCTAssertEqual(allowance.remaining(on: date(4, 23, 59), calendar: calendar), 0)
        XCTAssertFalse(allowance.consume(on: date(4, 23, 59), calendar: calendar))
        XCTAssertEqual(allowance.used, 2)
    }

    func testAllowanceRefillsAtLocalMidnight() {
        var allowance = FreeFindAllowance()
        allowance.consume(on: date(4, 22), calendar: calendar)
        allowance.consume(on: date(4, 23), calendar: calendar)
        XCTAssertEqual(allowance.remaining(on: date(5, 0), calendar: calendar), 2)
        XCTAssertTrue(allowance.consume(on: date(5, 0, 1), calendar: calendar))
        XCTAssertEqual(allowance.remaining(on: date(5, 8), calendar: calendar), 1)
        XCTAssertEqual(allowance.day, date(5, 0))
    }

    func testAllowanceRoundTripsThroughJSON() throws {
        var allowance = FreeFindAllowance()
        allowance.consume(on: date(4, 9), calendar: calendar)
        let decoded = try JSONDecoder().decode(
            FreeFindAllowance.self,
            from: JSONEncoder().encode(allowance)
        )
        XCTAssertEqual(decoded, allowance)
    }
}
