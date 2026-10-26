import Foundation

struct Evaluation {
    /// Inputs and outputs by name. Outputs that couldn't be calculated are NaN.
    var values: [String: Double]
    var errors: [String: String]
}

struct ChartPoint: Identifiable {
    let x: Double
    let y: Double
    var id: Double { x }
}

extension Surface {
    /// `records` are the user's entries in the surface's collections, for totals like
    /// `sum(expenses.amount)`.
    func evaluate(_ given: [String: Double], records: [String: [Record]] = [:]) -> Evaluation {
        var values: [String: Double] = [:]
        for input in inputs where values[input.name] == nil {
            values[input.name] = given[input.name] ?? input.initial
        }
        let formulas = Dictionary(outputs.map { ($0.name, $0.formula) }, uniquingKeysWith: { first, _ in first })
        var errors: [String: String] = [:]
        var resolving: Set<String> = []

        var columns: [String: [Double]] = [:]
        func column(_ name: String) -> [Double]? {
            if let known = columns[name] { return known }
            let found = self.column(name, in: records)
            columns[name] = found
            return found
        }

        func resolve(_ name: String) throws -> Double {
            if let known = values[name] { return known }
            guard let formula = formulas[name] else {
                if let constant = Expr.constants[name] { return constant }
                if columnNames.contains(name) { throw FormulaError("'\(name)' is a list; total it with sum(\(name)), avg, min, max, count or last") }
                throw FormulaError("'\(name)' isn't an input or output")
            }
            guard resolving.insert(name).inserted else { throw FormulaError("'\(name)' depends on itself") }
            defer { resolving.remove(name) }
            let value = try FormulaCache.parse(formula).evaluate(resolve, column: column)
            values[name] = value
            return value
        }

        for output in outputs where values[output.name] == nil {
            do {
                _ = try resolve(output.name)
            } catch {
                errors[output.name] = "\(error)"
                values[output.name] = .nan
            }
        }
        // Each total too, so an equation worked through with live numbers can show it.
        if !recordCollections.isEmpty {
            values.merge(totals(in: records)) { current, _ in current }
        }
        return Evaluation(values: values, errors: errors)
    }

    /// How `output` changes as `inputName` sweeps its range, holding everything else at `given`.
    func series(of output: String, over inputName: String, given: [String: Double], records: [String: [Record]] = [:]) -> [ChartPoint] {
        guard let input = input(inputName) else { return [] }
        let range = input.safeRange
        let span = range.upperBound - range.lowerBound
        // Enough samples that a few cycles of a wave stay smooth.
        let count = input.format == .integer && span <= 60 ? Int(span) + 1 : 120
        guard count > 1 else { return [] }
        return (0..<count).compactMap { index in
            let x = range.lowerBound + span * Double(index) / Double(count - 1)
            var values = given
            values[inputName] = x
            guard let y = evaluate(values, records: records).values[output], y.isFinite else { return nil }
            return ChartPoint(x: x, y: y)
        }
    }

    /// Every input an output depends on, directly or through other outputs.
    func inputs(feeding name: String) -> Set<String> {
        var seen: Set<String> = []
        var found: Set<String> = []
        func walk(_ name: String) {
            guard seen.insert(name).inserted else { return }
            if input(name) != nil {
                found.insert(name)
                return
            }
            guard let output = output(name), let expr = try? FormulaCache.parse(output.formula) else { return }
            expr.names.forEach(walk)
        }
        walk(name)
        return found
    }
}
