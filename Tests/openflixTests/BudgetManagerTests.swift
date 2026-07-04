import XCTest
@testable import openflix

final class BudgetManagerTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openflix-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func dateString(daysAgo: Int = 0) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone.current
        return fmt.string(from: Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!)
    }

    private func writeHistory(_ history: [String: BudgetManager.DailySpend]) throws {
        let data = try JSONEncoder().encode(history)
        try data.write(to: tempDir.appendingPathComponent("daily_spend.json"))
    }

    func testMonthToDateSumsOnlyCurrentMonth() async throws {
        let today = dateString()
        let monthPrefix = String(today.prefix(7))
        let firstOfMonth = "\(monthPrefix)-01"
        var history: [String: BudgetManager.DailySpend] = [
            "2020-01-15": .init(date: "2020-01-15", totalUSD: 99.0, generationCount: 10),
        ]
        history[firstOfMonth] = .init(date: firstOfMonth, totalUSD: 1.25, generationCount: 2)
        history[today] = .init(date: today, totalUSD: 2.5, generationCount: 5)
        try writeHistory(history)
        let manager = BudgetManager(directory: tempDir)
        let monthly = await manager.monthToDateSpend()
        // today and firstOfMonth may be the same day (on the 1st) — sum accordingly
        let expected = today == firstOfMonth ? 2.5 : 3.75
        XCTAssertEqual(monthly, expected, accuracy: 0.0001)
    }

    func testLegacySingleDayFileIsMigrated() async throws {
        let today = dateString()
        let legacy = BudgetManager.DailySpend(date: today, totalUSD: 4.2, generationCount: 7)
        let data = try JSONEncoder().encode(legacy)
        try data.write(to: tempDir.appendingPathComponent("daily_spend.json"))

        let manager = BudgetManager(directory: tempDir)
        let spend = await manager.loadSpend()
        XCTAssertEqual(spend.totalUSD, 4.2, accuracy: 0.0001)
        XCTAssertEqual(spend.generationCount, 7)
        let monthly = await manager.monthToDateSpend()
        XCTAssertEqual(monthly, 4.2, accuracy: 0.0001)
    }

    func testRecordSpendAccumulatesAndPersistsHistory() async throws {
        let manager = BudgetManager(directory: tempDir)
        await manager.recordSpend(amount: 0.5)
        await manager.recordSpend(amount: 0.25)
        let spend = await manager.loadSpend()
        XCTAssertEqual(spend.totalUSD, 0.75, accuracy: 0.0001)
        XCTAssertEqual(spend.generationCount, 2)

        // A fresh instance reads the same history back from disk
        let reloaded = BudgetManager(directory: tempDir)
        let monthly = await reloaded.monthToDateSpend()
        XCTAssertEqual(monthly, 0.75, accuracy: 0.0001)
    }

    func testPreFlightDeniesWhenMonthlyLimitExceeded() async throws {
        let earlier = dateString(daysAgo: 1)
        let today = dateString()
        // Only include the earlier day if it's still in the current month
        var history: [String: BudgetManager.DailySpend] = [
            today: .init(date: today, totalUSD: 6.0, generationCount: 3),
        ]
        if earlier.prefix(7) == today.prefix(7) {
            history[earlier] = .init(date: earlier, totalUSD: 3.0, generationCount: 2)
        } else {
            history[today] = .init(date: today, totalUSD: 9.0, generationCount: 5)
        }
        try writeHistory(history)

        let manager = BudgetManager(directory: tempDir)
        try await manager.saveConfig(.init(monthlyLimitUSD: 10.0))

        let denied = await manager.preFlightCheck(estimatedCost: 2.0)  // 9 + 2 > 10
        guard case .denied(let reason) = denied else {
            return XCTFail("Expected .denied, got \(denied)")
        }
        XCTAssertTrue(reason.contains("Monthly spend"))

        let approved = await manager.preFlightCheck(estimatedCost: 0.5)  // 9 + 0.5 <= 10
        guard case .approved = approved else {
            return XCTFail("Expected .approved, got \(approved)")
        }
    }

    func testPreFlightDeniesPerGenerationLimit() async throws {
        let manager = BudgetManager(directory: tempDir)
        try await manager.saveConfig(.init(perGenerationMaxUSD: 1.0))
        let result = await manager.preFlightCheck(estimatedCost: 1.5)
        guard case .denied(let reason) = result else {
            return XCTFail("Expected .denied, got \(result)")
        }
        XCTAssertTrue(reason.contains("per-generation limit"))
    }
}
