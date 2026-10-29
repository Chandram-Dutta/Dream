import Foundation
import SwiftData

// A change made on Dream's server, landing on the page it changed (docs/ServerGeneration.md).
// The server keeps the changed page in sync under the page's id, and the phone lands it on the
// same SavedSurface, so the account holds one copy whichever comes first.

extension SavedSurface {
    /// A change made on Dream's server, kept as the page screen keeps a change it makes itself
    /// (SurfaceScreen): the changed page, the user's numbers the change left alone, and the change
    /// in the page's conversation. Landing it again, or after sync brought the server's copy
    /// first, adds nothing more, and whatever sync brought of the user's numbers gives way to
    /// theirs.
    func land(_ change: PageChange, as page: Surface, model: String, log: [String]) {
        if surface != page { surface = page }
        let kept = change.kept(after: page)
        if values != kept { values = kept }
        let turn = change.turn(for: page)
        // The server's copy may have come with the turn in it already.
        let noted = history.contains { $0.kindName == turn.kindName && $0.text == turn.text && $0.at >= change.askedAt }
        if !noted {
            history.append(turn)
            if let request = change.editRequest { editRequests.append(request) }
            generationLog.append(contentsOf: log)
        }
        if !model.isEmpty, modelName != model { modelName = model }
    }
}

extension PageChange {
    /// The change in the page's conversation, as a change made here notes it.
    func turn(for page: Surface) -> PageTurn {
        switch kind {
        case .instruction: PageTurn(.changed, text)
        case .answer: PageTurn(.answered, text, answers: (page.answers ?? []).filter { $0.question == answer?.question })
        case .again: PageTurn(.rebuilt, text, answers: page.answers ?? [])
        }
    }
}
