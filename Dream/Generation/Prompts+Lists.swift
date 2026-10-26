import Foundation

// Lists and the user's own data (ROADMAP.md, workstream 2).

extension Prompts {
    /// How to declare collections and show them as lists.
    static var listRules: String {
        """
        Lists: when the user keeps track of things (shopping, expenses, habits, packing, reading, workouts, weight), declare a collection and show it. Their entries stay on their phone; the screen holds only the list's design.
        - A collection has a camelCase plural name (groceries, expenses), a label, what one entry is called (expense), and fields. The first field names each entry, usually text. Field types: text, number, currency for money, date, done for a checkbox, choice for one of a few options, rating for 1 to 5 stars. Only the fields the user would fill in or look at.
        - Anything logged over time has a date field: entries are dated as they're added, newest first. Something done regularly, like habits, is logged once a day: each entry is a day, with a date and a done field for each habit.
        - list (ref: the collection) shows the entries; the user checks them off, edits, reorders and deletes them. add (ref: the collection) is a bar for adding entries; put it just above its list.
        - Totals over entries are outputs, and update as entries change: sum(expenses.amount), avg, min, max, count(groceries) for how many there are, count(groceries.done) for how many are checked, last(weights.value) for the latest. Show the main one as the hero. An adjustable input can set a target, like left = budget - sum(expenses.amount). Totals need no question and no other inputs.
        - starters: only entries the request itself implies, like what to pack for a beach. Leave them out when what goes in is the user's to decide, like a shopping list, and never invent their own figures, like expenses or weights.
        - A chart of entries is a data block with ref collection.field for the values (or the collection, to count entries) and over collection.field: a date to follow it over time, or a choice to compare categories. Leave its items empty.
        """
    }

    // MARK: - Talking to a list

    /// For turning what the user says into changes to their entries. Short, because the
    /// on-device model reads it first.
    static let recordInstructions = """
        You turn what the user says into changes to their lists: add new entries, change an entry's field by the entry's number, or remove entries by their numbers. Only what they asked for. Write numbers without currency symbols, dates as YYYY-MM-DD, and yes or no for a checkbox. Leave a field empty when they didn't give it.
        If they want the screen itself changed instead, like a new field or column, a chart, a total, colours or wording, answer screen and change nothing.
        """

    /// The lists, the user's entries in them (numbered as shown), and what they said. `adding`
    /// narrows it to adding to one list, from its add bar.
    static func recordRequest(_ text: String, surface: Surface, records: [String: [Record]], hasImage: Bool, adding: String? = nil, now: Date = .now) -> String {
        var lines = ["Today is \(now.formatted(.dateTime.weekday(.wide).day().month(.wide).year())), \(RecordField.day.string(from: now))."]
        lines.append("Lists:")
        for collection in surface.recordCollections where adding == nil || adding == collection.name {
            let fields = collection.fields.map { field in
                field.type == .choice ? "\(field.name) (choice of \(field.options.joined(separator: " / ")))" : "\(field.name) (\(field.type.rawValue))"
            }
            lines.append("- \(collection.name) (\"\(collection.label)\", each \(collection.anEntry)): \(fields.joined(separator: ", "))")
            // Adding doesn't need the user's other entries, so they aren't sent.
            guard adding == nil else { continue }
            let shown = collection.arranged(records[collection.name] ?? [])
            if shown.isEmpty { lines.append("  No entries yet.") }
            for (index, record) in shown.prefix(40).enumerated() {
                let values = collection.fields.compactMap { field in record[field.name].map { "\(field.name): \(field.written($0))" } }
                lines.append("  \(index + 1). \(values.joined(separator: "; "))")
            }
            if shown.count > 40 { lines.append("  …and \(shown.count - 40) older entries.") }
        }
        if let adding {
            lines.append("Add what the user gives to \(adding), one entry each.")
        }
        if hasImage {
            lines.append("The user attached a photo, like a receipt or a handwritten list. Add what it shows: each item, with its amount where there is one.")
        }
        if !text.isEmpty { lines.append("The user says: \"\(text)\"") }
        return lines.joined(separator: "\n")
    }
}
