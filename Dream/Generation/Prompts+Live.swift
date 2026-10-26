import Foundation

// Sources, actions and live data (ROADMAP.md, workstream 7).

extension Prompts {
    /// How to show live values and offer actions.
    static var liveRules: String {
        """
        Live data: the weather, exchange rates, and how far or how long it is between places all change, so Dream fetches them and keeps them current on the screen. Never type such numbers yourself, and never put them on a slider.
        - Fetch each with the live tool before building. It returns the values now, each named like weather.rainChance. Write your text to agree with them.
        - Show each value you use with an input whose role is live and whose source is that name; start it at the value. Show it in a hero or a metric. Live values need no question and no other inputs. Formulas use them like any input, like amount * rate.
        - A yes or no that rests on them, like whether to take an umbrella, is an output with format toggle calculated from them, like rainChance >= 40, shown as the hero, so it changes when they do.
        - Text stays true only where it shows values live: in paragraphs and items, write {name} rather than a live number. The title and summary never change, so leave live numbers, and answers that rest on them, out of both: say what the screen tells, like Whether you'll need an umbrella tomorrow.
        - For a what-if, like a rate that might change, add a separate adjustable input with the same source; it starts at the live value.
        - Use current location for where the user is; otherwise the place they name.
        Actions: when the request is a plan the user will act on, offer to do it with one tap: a calendarEvent in their calendar, a reminder, or directions in Maps. Usually one, the step the plan needs most. Define it in actions and show it with an action block whose ref is its name, after what it's about. Its text can use {name} for live values and results. Nothing happens until the user taps it.
        """
    }

    /// The date and time now, which days like "this Saturday" are counted from.
    static func liveContext(now: Date = .now) -> [String] {
        let english = Locale(identifier: "en_US")
        let day = now.formatted(.dateTime.weekday(.wide).day().month(.wide).year().locale(english))
        let time = now.formatted(.dateTime.hour().minute().locale(english))
        return ["Now it's \(day), \(time), where the user is."]
    }

    /// An action in a few words, for pointing at its button.
    static func describeAction(_ name: String, in surface: Surface) -> String {
        guard let action = surface.action(name) else { return "'\(name)'" }
        let title = action["title"].isEmpty ? action["place"] : action["title"]
        return "\(action.kind) \"\(title)\""
    }
}

extension Surface {
    /// Sources and actions in the outline's shorthand, so the model sees what the screen reads
    /// and can do when it changes it.
    var liveOutline: [String] {
        var lines: [String] = []
        if let sources, !sources.isEmpty {
            lines.append("sources (fetched with the live tool; fetch again to change one):")
            for source in sources {
                let asked = source.parameters.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                let fields = source.fields.map { "\(source.name).\($0.name)" }.joined(separator: ", ")
                lines.append("- \(source.name): \(source.kind), \(asked); fields \(fields)")
            }
        }
        if let actions, !actions.isEmpty {
            lines.append("actions:")
            for action in actions {
                let fields = action.isConnection ? action.connectionOutline : action.fields.sorted { $0.key < $1.key }.map { "\($0.key) \"\($0.value)\"" }.joined(separator: ", ")
                lines.append("- \(action.name): \(action.kind), \(fields)")
            }
        }
        return lines
    }
}
