import Foundation

/// Free rally finds per day. The count refills at local midnight.
public struct FreeFindAllowance: Codable, Equatable, Sendable {
    public static let dailyLimit = 2

    /// Start of the local day `used` belongs to.
    public private(set) var day: Date
    public private(set) var used: Int

    public init(day: Date = .distantPast, used: Int = 0) {
        self.day = day
        self.used = used
    }

    public func remaining(on date: Date, calendar: Calendar = .current) -> Int {
        guard calendar.isDate(day, inSameDayAs: date) else {
            return Self.dailyLimit
        }
        return max(0, Self.dailyLimit - used)
    }

    /// Uses one free find. Returns false when none are left today.
    @discardableResult
    public mutating func consume(on date: Date, calendar: Calendar = .current) -> Bool {
        guard remaining(on: date, calendar: calendar) > 0 else {
            return false
        }
        if !calendar.isDate(day, inSameDayAs: date) {
            day = calendar.startOfDay(for: date)
            used = 0
        }
        used += 1
        return true
    }
}
