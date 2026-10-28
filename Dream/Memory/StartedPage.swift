import SwiftData
import SwiftUI

/// A page started on Dream's server that isn't on the shelf yet. Kept so a page the app leaves
/// mid-way (closed, killed, or just its screen left) is found again: by its job while the server
/// has it, or from sync once it's done (docs/ServerGeneration.md). It goes once the page is saved.
@Model
final class StartedPage {
    /// The job's id on Dream's server, which its events are read from.
    var jobID = ""
    /// The id the finished page is kept under, here and in sync.
    var pageID = UUID()
    /// What the user asked for, in their words.
    var intent = ""
    /// The photo it started from, as the page will keep it.
    @Attribute(.externalStorage) var photoData: Data?
    var startedAt = Date()
    /// Why it couldn't be made, once it couldn't.
    var failure: String?
    /// When the server turned out no longer to have the job, so the page is coming by sync.
    var lostAt: Date?

    init(_ job: ServerJob, intent: String, photoData: Data?) {
        jobID = job.id
        pageID = job.page
        self.intent = intent
        self.photoData = photoData
    }

    var job: ServerJob { ServerJob(id: jobID, page: pageID) }
}

/// A started page as screens pass it around: a value, since its record goes once the page is made.
struct FormingPage: Hashable {
    let job: ServerJob
    let intent: String
    let photoData: Data?
    let startedAt: Date

    init(_ started: StartedPage) {
        job = started.job
        intent = started.intent
        photoData = started.photoData
        startedAt = started.startedAt
    }

    static func == (a: FormingPage, b: FormingPage) -> Bool { a.job == b.job }
    func hash(into hasher: inout Hasher) { hasher.combine(job) }
}

/// Follows every page being made on Dream's server, whether its screen is open or not: one
/// composer for each, which the page's screen and its tile on the shelf both show. A page that
/// finishes is saved under its id; one whose job the server no longer has comes by sync.
@MainActor @Observable
final class ServerPages {
    static let shared = ServerPages()

    /// The composers following pages, by the pages' ids.
    private(set) var following: [UUID: Composer] = [:]
    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// After this long without its job on the server or its page from sync, a page is given up on.
    private static let patience: TimeInterval = 10 * 60

    private var context: ModelContext? { container?.mainContext }

    /// At launch: picks up every page left mid-way, and does again on coming back to the app.
    static func start(_ container: ModelContainer) {
        let pages = shared
        guard pages.container == nil else { return }
        pages.container = container
        // Signing out erases them with everything else.
        LocalData.erasers.append { context in
            ServerPages.shared.stopAll()
            for started in (try? context.fetch(FetchDescriptor<StartedPage>())) ?? [] { context.delete(started) }
        }
        let center = NotificationCenter.default
        pages.observers = [
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ServerPages.shared.resume() }
            },
            center.addObserver(forName: Session.didChange, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    if Session.isSignedIn { ServerPages.shared.resume() } else { ServerPages.shared.stopAll() }
                }
            },
        ]
        pages.resume()
    }

    // MARK: - Starting and following

    /// Starts a new page on Dream's server. The composer follows it whether or not the screen
    /// that asked stays open, and its job is kept as soon as the server has it.
    func begin(intent: String, image: CGImage?) -> Composer {
        let composer = Composer()
        let photo = image.flatMap { UIImage(cgImage: $0).jpegData(compressionQuality: 0.8) }
        composer.onJob = { [weak self, weak composer] job in
            guard let self, let composer, let context = self.context else { return }
            context.insert(StartedPage(job, intent: intent, photoData: photo))
            try? context.save()
            self.following[job.page] = composer
        }
        run(composer) { await composer.composeOnServer(intent: intent, image: image) }
        return composer
    }

    /// The composer following a started page: the one already following it, or a new one that
    /// picks it up from its first event. One that failed says why.
    func composer(for forming: FormingPage) -> Composer {
        if let composer = following[forming.job.page] { return composer }
        let composer = Composer()
        guard let started = record(forming.job.page) else {
            composer.show(ending: forming.job, intent: forming.intent, with: nil, failure: "This page isn't here anymore.")
            return composer
        }
        if let failure = started.failure {
            composer.show(ending: started.job, intent: started.intent, with: nil, failure: failure)
            return composer
        }
        follow(started, with: composer)
        return composer
    }

    /// A page that failed, started again as a new page.
    func retry(_ forming: FormingPage) -> Composer {
        discard(forming.job.page)
        return begin(intent: forming.intent, image: forming.photoData.flatMap { UIImage(data: $0)?.cgImage })
    }

    /// Lets go of a started page: stops following it and forgets it.
    func discard(_ page: UUID) {
        if let composer = following[page] {
            tasks[ObjectIdentifier(composer)]?.cancel()
            following[page] = nil
        }
        forget(page)
    }

    /// Follows every started page nothing follows yet, and has those something follows read their
    /// events again, since a line can die while the app is away: at launch, on coming back to the
    /// app, and on signing in.
    func resume() {
        guard let context, Session.isSignedIn else { return }
        for started in (try? context.fetch(FetchDescriptor<StartedPage>())) ?? [] {
            if let composer = following[started.pageID] {
                composer.watch?.reconnect()
                continue
            }
            if page(started.pageID) != nil {
                // It came by sync while nothing followed it.
                context.delete(started)
                continue
            }
            guard started.failure == nil else { continue }
            if let lost = started.lostAt, Date.now.timeIntervalSince(lost) > Self.patience {
                started.failure = "Dream's server lost this page. Try again."
                continue
            }
            follow(started)
        }
        try? context.save()
    }

    private func follow(_ started: StartedPage, with given: Composer? = nil) {
        let composer = given ?? Composer()
        let job = started.job
        let intent = started.intent
        let since = started.startedAt
        following[job.page] = composer
        run(composer) { await composer.watch(job, intent: intent, since: since) }
    }

    private func run(_ composer: Composer, _ work: @escaping () async -> ServerWatch.Ending) {
        let key = ObjectIdentifier(composer)
        tasks[key] = Task {
            let ending = await work()
            self.tasks[key] = nil
            self.ended(composer, ending)
        }
    }

    private func stopAll() {
        for task in tasks.values { task.cancel() }
        tasks = [:]
        following = [:]
    }

    // MARK: - Ending

    private func ended(_ composer: Composer, _ ending: ServerWatch.Ending) {
        // A page that failed before the server had it left nothing to keep.
        guard let job = composer.job else { return }
        switch ending {
        case .done:
            keep(composer)
            release(job.page, from: composer)
        case .failed:
            if case .failed(let message) = composer.phase, let started = record(job.page) {
                started.failure = message
                try? context?.save()
            }
            release(job.page, from: composer)
        case .gone:
            if let started = record(job.page), started.lostAt == nil {
                started.lostAt = .now
                try? context?.save()
            }
            Task { await arrive(job, for: composer) }
        case .stopped:
            release(job.page, from: composer)
        }
    }

    /// The page a composer finished on the server, saved under its id: the one here already if
    /// sync brought it first, or saved now. Called as the page ends, and by its screen if that's
    /// first to see it end; both get the same page.
    @discardableResult
    func keep(_ composer: Composer) -> SavedSurface? {
        guard composer.phase == .done, let job = composer.job, let surface = composer.surface, let context else { return nil }
        let started = record(job.page)
        let saved: SavedSurface
        if let existing = page(job.page) {
            saved = existing
            if saved.photoData == nil, let photo = started?.photoData { saved.photoData = photo }
        } else {
            // Erased meanwhile, by signing out: nothing to keep it for.
            guard let started else { return nil }
            saved = SavedSurface(intent: started.intent, surface: surface, modelName: composer.modelName, log: composer.log)
            saved.id = job.page
            saved.photoData = started.photoData
            saved.history = [PageTurn(.asked, started.intent, answers: surface.answers ?? [])]
            context.insert(saved)
        }
        if let started { context.delete(started) }
        try? context.save()
        removeTwins(of: saved)
        // This iPhone asked, so what the user answered is remembered here.
        if let started { Memory.learn(from: started.intent, answers: surface.answers ?? [], in: context) }
        return saved
    }

    /// A page whose job the server no longer has finished a while ago, and is in the account: a
    /// round of sync brings it. If it doesn't come, it's looked for again on coming back to the
    /// app, and given up on after a while (`resume`).
    private func arrive(_ job: ServerJob, for composer: Composer) async {
        for wait in [0, 3, 10, 30] {
            try? await Task.sleep(for: .seconds(wait))
            guard following[job.page] === composer else { return }
            await Sync.shared.roundNow()
            if let saved = page(job.page) {
                composer.show(ending: job, intent: saved.intent, with: saved.surface, model: saved.modelName)
                forget(job.page)
                release(job.page, from: composer)
                return
            }
        }
        release(job.page, from: composer)
    }

    private func release(_ page: UUID, from composer: Composer) {
        if following[page] === composer { following[page] = nil }
    }

    // MARK: - Stored

    private func record(_ page: UUID) -> StartedPage? {
        var descriptor = FetchDescriptor<StartedPage>(predicate: #Predicate { $0.pageID == page })
        descriptor.fetchLimit = 1
        return try? context?.fetch(descriptor).first
    }

    /// The saved page under this id, if it's here.
    func page(_ id: UUID) -> SavedSurface? {
        context.flatMap { Sync.page(id.uuidString, in: $0) }
    }

    private func forget(_ page: UUID) {
        guard let started = record(page) else { return }
        context?.delete(started)
        try? context?.save()
    }

    /// Two pages under one id, if sync brought the page in just as it was saved here: the others
    /// go, as sync's own change, so no deletion goes out for the id they share.
    private func removeTwins(of saved: SavedSurface) {
        guard let container else { return }
        let id = saved.id
        let kept = saved.persistentModelID
        let context = ModelContext(container)
        context.author = Sync.author
        let twins = (try? context.fetch(FetchDescriptor<SavedSurface>(predicate: #Predicate { $0.id == id }))) ?? []
        guard twins.count > 1 else { return }
        for twin in twins where twin.persistentModelID != kept { context.delete(twin) }
        try? context.save()
    }
}
