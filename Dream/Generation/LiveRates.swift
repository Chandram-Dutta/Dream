import Foundation

// Exchange rates (ROADMAP.md, workstream 7), from ExchangeRate-API's open endpoint
// (open.er-api.com): free, no key, about 160 currencies, updated once a day. Its terms ask for
// a credit link, and for rates to be cached rather than fetched on every view, so each base
// currency is kept until the service says the next update is due.

/// How many of one currency make one of another. Parameters: from and to, as ISO codes.
struct ExchangeRateProvider: LiveProvider {
    let kind = "exchangeRate"
    let freshness: TimeInterval = 60 * 60

    func read(_ source: Source) async throws -> SourceReading {
        let from = Self.code(source["from"])
        let to = Self.code(source["to"]).isEmpty ? Currency.code : Self.code(source["to"])
        guard from.count == 3, to.count == 3 else { throw LiveError(.notFound, "Exchange rates need two currency codes, like USD and INR.") }
        let table = try await RateTables.shared.table(for: from)
        guard let rate = table.rates[to] else { throw LiveError(.notFound, "There's no rate from \(from) to \(to).") }
        let english = Locale(identifier: "en")
        func name(_ code: String) -> String { english.localizedString(forCurrencyCode: code) ?? code }
        return SourceReading(
            fields: [SourceField(name: "rate", value: rate, format: .number, meaning: "how many \(to) one \(from) buys")],
            summary: "1 \(name(from)) is \(rate.formatted(.number.precision(.significantDigits(1...6)))) \(name(to))",
            symbol: "dollarsign.arrow.circlepath",
            asOf: table.updated,
            credit: .link(text: "Rates by Exchange Rate API", url: "https://www.exchangerate-api.com"))
    }

    private static func code(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}

/// Rates from one base currency, and when they were set.
private struct RateTable: Codable {
    var rates: [String: Double]
    var updated: Date
    var nextUpdate: Date
}

/// Rate tables by base currency: in memory, and in Caches so they last between launches.
private actor RateTables {
    static let shared = RateTables()
    private var tables: [String: RateTable] = [:]

    func table(for base: String) async throws -> RateTable {
        if let table = tables[base] ?? stored(base), table.nextUpdate > .now {
            tables[base] = table
            return table
        }
        do {
            let table = try await fetch(base)
            tables[base] = table
            store(table, for: base)
            return table
        } catch {
            // Yesterday's rates beat none; the screen shows how old they are.
            if let table = tables[base] ?? stored(base) { return table }
            throw error
        }
    }

    private func fetch(_ base: String) async throws -> RateTable {
        guard base.allSatisfy({ $0.isASCII && $0.isLetter }), let url = URL(string: "https://open.er-api.com/v6/latest/\(base)") else {
            throw LiveError(.notFound, "\(base) isn't a currency code.")
        }
        struct Response: Decodable {
            let result: String
            let rates: [String: Double]?
            let time_last_update_unix: Double?
            let time_next_update_unix: Double?
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Dream/0.1 (iOS prototype)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else {
            throw LiveError(.unavailable, "Exchange rates aren't available right now.")
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data), response.result == "success", let rates = response.rates else {
            throw LiveError(.notFound, "There are no exchange rates for \(base).")
        }
        let updated = response.time_last_update_unix.map { Date(timeIntervalSince1970: $0) } ?? .now
        let next = response.time_next_update_unix.map { Date(timeIntervalSince1970: $0) } ?? updated.addingTimeInterval(86_400)
        return RateTable(rates: rates, updated: updated, nextUpdate: max(next, Date.now.addingTimeInterval(15 * 60)))
    }

    private func file(_ base: String) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appending(path: "dream-rates-\(base).json")
    }

    private func stored(_ base: String) -> RateTable? {
        guard let file = file(base), let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(RateTable.self, from: data)
    }

    private func store(_ table: RateTable, for base: String) {
        guard let file = file(base), let data = try? JSONEncoder().encode(table) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
