import BackgroundTasks
import Observation
import SwiftData
import SwiftUI

/// Makes new pages apart from any screen, so a page goes on being made when the user goes back
/// to the shelf, opens another page, or leaves the app. Pages being made show on the shelf, with
/// Dream's light moving through them, and are saved there when they're done.
///
/// Apple's models make every page on the iPhone or on Private Cloud Compute, so there's no job on
/// a server to come back to. Leaving the app hands the work to iOS as a continued-processing task
/// (`BackgroundPage`), which shows its progress on the Lock Screen and lets it finish.
@MainActor @Observable
final class PageMaker {
    static let shared = PageMaker()

    /// A page being made, as screens pass it around.
    struct Making: Identifiable, Hashable {
        let id: UUID
        let intent: String
        let photoData: Data?
        let startedAt: Date
        /// The page this one goes on from, and what it starts from there (`Prompts.goingOn`).
        var parent: UUID? = nil
        var carrying: [String] = []
        /// Where it was asked from, for analytics: typed, suggestion, follow_up, explore or launch.
        var source = "typed"
    }

    /// Pages being made, newest first, until they're saved.
    private(set) var pages: [Making] = []
    /// What's making each page, which its screen and tile show.
    private(set) var composers: [UUID: Composer] = [:]
    /// Pages made while they were being watched, or not: the saved page for each, so an open
    /// screen can carry on with it.
    private(set) var made: [UUID: SavedSurface] = [:]

    private var container: ModelContainer?
    private var images: [UUID: CGImage] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func start(_ container: ModelContainer) {
        self.container = container
        // The gap check reads what was made in the last few hours (GapCheck.recentPages).
        GapCheck.recentPages = {
            let since = Date.now.addingTimeInterval(-3 * 3600)
            var recent = FetchDescriptor<SavedSurface>(predicate: #Predicate { $0.updatedAt > since }, sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
            recent.fetchLimit = 3
            return ((try? container.mainContext.fetch(recent)) ?? []).map { "\($0.surface.title) (asked as \"\($0.intent)\")" }
        }
        // And the earlier pages about the same things, with what was found for them (PageGraph.swift).
        GapCheck.relatedPages = { request in
            let nodes = PageGraph.pages(in: container.mainContext).map(\.node)
            return PageGraph.related(toRequest: request, in: nodes).map(PageGraph.described)
        }
    }

    /// Starts a page for a request, and returns it.
    @discardableResult
    func begin(intent: String, image: CGImage?, parent: UUID? = nil, carrying: [String] = [], source: String = "typed") -> Making {
        let making = Making(id: UUID(), intent: intent, photoData: image.flatMap { UIImage(cgImage: $0).jpegData(compressionQuality: 0.8) }, startedAt: .now,
                            parent: parent, carrying: carrying, source: source)
        // A sum, or a saved page asked again with other numbers, is there at once, with no model.
        if image == nil, let page = madeAtOnce(making) {
            made[making.id] = page
            return making
        }
        pages.insert(making, at: 0)
        images[making.id] = image
        run(making)
        return making
    }

    func composer(for page: Making) -> Composer? { composers[page.id] }

    /// The page for a request that needs no model (Effort.swift): a sum Dream works out itself
    /// (InstantPage), or a saved calculation made again with the request's numbers (PageReuse).
    /// Saved straight away. Nil when the request needs a model, or the page wouldn't pass the
    /// checker as it stands.
    private func madeAtOnce(_ page: Making) -> SavedSurface? {
        guard let container else { return nil }
        let started = Date()
        let context = container.mainContext
        var made: (surface: Surface, level: Effort.Level, model: String)?
        if FeatureFlag.instantPages.isOn, let surface = InstantPage.make(for: page.intent) {
            made = (surface, .instant, "Dream")
        } else if FeatureFlag.pageReuse.isOn {
            for saved in PageGraph.pages(in: context).prefix(300) {
                if let surface = PageReuse.adapt(saved.surface, asked: saved.intent, for: page.intent) {
                    made = (surface, .reused, saved.modelName)
                    break
                }
            }
        }
        guard var (surface, level, model) = made else { return nil }
        // What the model's pages go through, so a page made here is held to the same bar.
        let problems = Checker.checkLogic(&surface).filter { $0.kind == .needsModel }
        guard problems.isEmpty else {
            Build.trace("[Dream] \(level.rawValue) page didn't pass the checker; writing it instead")
            return nil
        }
        _ = Checker.checkBlocks(&surface)
        let saved = SavedSurface(intent: page.intent, surface: surface, modelName: model,
                                 log: ["Request: \(page.intent)", "Level: \(level.rawValue)", String(format: "Made at once in %.2fs", Date().timeIntervalSince(started))])
        saved.history = [PageTurn(.asked, page.intent)]
        saved.parentID = page.parent
        context.insert(saved)
        try? context.save()
        let run = Analytics.Run(level: level.rawValue, source: page.source)
        Analytics.send(.pageRequested(withPhoto: false, run: run))
        Analytics.send(.pageBuilt(Analytics.Shape(surface), model: level == .instant ? "none" : "reused", seconds: Date().timeIntervalSince(started), run: run))
        return saved
    }

    /// Why a page couldn't be made, once it couldn't.
    func failure(of page: Making) -> String? {
        if case .failed(let message) = composers[page.id]?.phase { return message }
        return nil
    }

    /// Makes a page that failed again, in place.
    func retry(_ page: Making) {
        guard tasks[page.id] == nil else { return }
        run(page)
    }

    /// Stops making a page and forgets it.
    func discard(_ page: Making) {
        tasks[page.id]?.cancel()
        tasks[page.id] = nil
        composers[page.id]?.asking.cancel()
        composers[page.id]?.consent.cancel()
        composers[page.id] = nil
        images[page.id] = nil
        pages.removeAll { $0.id == page.id }
    }

    private func run(_ page: Making) {
        let composer = Composer()
        composers[page.id] = composer
        let image = images[page.id]
        tasks[page.id] = Task { @MainActor in
            let background = BackgroundPage(page: page, composer: composer) { [weak self] in self?.tasks[page.id]?.cancel() }
            await composer.compose(intent: page.intent, image: image, carrying: page.carrying, source: page.source)
            background.finish(success: composer.phase == .done)
            tasks[page.id] = nil
            guard composer.phase == .done, let surface = composer.surface, let container else { return }
            let context = container.mainContext
            let saved = SavedSurface(intent: page.intent, surface: surface, modelName: composer.modelName, log: composer.log)
            saved.photoData = page.photoData
            saved.history = [PageTurn(.asked, page.intent, answers: surface.answers ?? [])]
            saved.parentID = page.parent
            saved.found = composer.understood
            saved.subjects = composer.subjects
            context.insert(saved)
            try? context.save()
            Memory.learn(from: page.intent, answers: surface.answers ?? [], in: context)
            made[page.id] = saved
            images[page.id] = nil
            withAnimation(.smooth) { pages.removeAll { $0.id == page.id } }
        }
    }
}

/// A page carrying on while Dream is in the background, through iOS's continued-processing
/// tasks: iOS shows it on the Lock Screen and in the Dynamic Island with its progress, the user
/// can stop it there, and it ends when the page does. Started as each page starts, while Dream is
/// in front, as iOS asks.
@MainActor
final class BackgroundPage {
    private static let prefix = (Bundle.main.bundleIdentifier ?? "xyz.onlychan.Dream") + ".page."
    /// The task iOS gave for each page, once it started it.
    private static var running: [String: BGContinuedProcessingTask] = [:]
    private static var composers: [String: Composer] = [:]
    private static var stops: [String: () -> Void] = [:]

    private let identifier: String

    init(page: PageMaker.Making, composer: Composer, onStop: @escaping () -> Void) {
        // A new identifier each time, since iOS takes one handler per identifier for good and a
        // page made again (Try again) needs its own.
        identifier = Self.prefix + UUID().uuidString
        Self.composers[identifier] = composer
        Self.stops[identifier] = onStop
        #if os(iOS)
        guard !ProcessInfo.processInfo.isiOSAppOnMac else { return }
        // Each page's task is registered under its own identifier just before it's asked for:
        // iOS takes continued-processing handlers registered while the app runs, but only for
        // the identifier itself, never the wildcard in Info.plist.
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
            MainActor.assumeIsolated { Self.started(task) }
        }
        guard registered else { return }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "Making a page", subtitle: page.intent)
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Build.trace("[Dream] No background time for this page: \(error.localizedDescription)")
        }
        #endif
    }

    private static func started(_ task: BGContinuedProcessingTask) {
        guard let composer = composers[task.identifier] else {
            task.setTaskCompleted(success: true)
            return
        }
        running[task.identifier] = task
        task.progress.totalUnitCount = 100
        task.expirationHandler = {
            // Stopped from the Lock Screen, or iOS needed the time: the page stays on the shelf
            // to try again.
            Task { @MainActor in stops[task.identifier]?() }
        }
        follow(task, composer)
    }

    /// Keeps the Lock Screen's progress and words in step with the work.
    private static func follow(_ task: BGContinuedProcessingTask, _ composer: Composer) {
        withObservationTracking {
            _ = composer.phase
            _ = composer.surface?.blocks.count
        } onChange: {
            Task { @MainActor in
                guard running[task.identifier] != nil else { return }
                task.progress.completedUnitCount = Int64(composer.progress * 100)
                task.updateTitle(composer.surface.flatMap { $0.title.isEmpty ? nil : $0.title } ?? "Making a page", subtitle: composer.stage.label)
                follow(task, composer)
            }
        }
    }

    func finish(success: Bool) {
        Self.composers[identifier] = nil
        Self.stops[identifier] = nil
        guard let task = Self.running.removeValue(forKey: identifier) else { return }
        task.progress.completedUnitCount = 100
        task.setTaskCompleted(success: success)
    }
}
