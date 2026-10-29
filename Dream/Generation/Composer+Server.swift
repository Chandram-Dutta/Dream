import CoreGraphics
import Foundation

// Pages and changes made on Dream's server (docs/ServerGeneration.md). The page loop runs there,
// whether or not anyone watches; the composer starts it, follows its events (ServerCompose.swift),
// runs the tools only this iPhone can (DeviceTools.swift), and shows it all through the same state
// as a page made here. The server counts these pages itself (page_requested, page_built,
// page_failed), so nothing here counts them again.

extension Composer {
    /// Starts a new page on Dream's server, and follows it until it's over or this is stopped.
    @discardableResult
    func composeOnServer(intent: String, image: CGImage?, through transport: (any ComposeTransport)? = nil) async -> ServerWatch.Ending {
        let page = UUID()
        var progress = PageProgress(intent: intent)
        progress.note("Request: \(intent)\(image == nil ? "" : " (with photo)")")
        progress.note("Made on Dream's server")
        show(progress, job: nil)
        asking.start()
        suggestConnections(for: intent)
        guard let transport = transport ?? ComposeClient.dream else {
            progress.end("Sign in to make pages.")
            show(progress, job: nil)
            return .failed
        }
        let (context, here) = await aboutTheUser(intent)
        var start = ComposeStart(intent: intent, image: image, page: page, context: context)
        start.here = here
        start.deviceTools = offerDeviceTools(for: intent, changing: nil).definitions
        return await begin(start, page: page, from: progress, through: transport)
    }

    /// Starts a change to the page kept under `page` on Dream's server, and follows it until it's
    /// over or this is stopped. The page stays on screen as it was while the change is written,
    /// unless it's made again, which forms as a new page does.
    @discardableResult
    func changeOnServer(_ change: PageChange, intent: String, image: CGImage?, page: UUID, through transport: (any ComposeTransport)? = nil) async -> ServerWatch.Ending {
        let progress = beginChange(change, intent: intent)
        if change.kind == .again { suggestConnections(for: intent) }
        guard let transport = transport ?? ComposeClient.dream else {
            var failed = progress
            failed.end("Sign in to change pages.")
            show(failed, job: nil)
            return .failed
        }
        let (context, here) = await aboutTheUser(intent)
        var start = ComposeStart(changing: change, intent: intent, image: image, page: page, context: context)
        start.here = here
        start.deviceTools = offerDeviceTools(for: change.request(intent), changing: change.kind == .again ? nil : change.base).definitions
        return await begin(start, page: page, from: progress, through: transport)
    }

    /// What this iPhone tells the server about the user with a request: the lines it adds below
    /// it, and where they are, when they've already let Dream know, which a line says by name.
    private func aboutTheUser(_ intent: String) async -> (context: [String], here: ComposeStart.Here?) {
        let here = await Places.hereIfAllowed().map(ComposeStart.Here.init)
        return (await Prompts.context(for: intent, in: here?.name), here)
    }

    /// Shows a change as begun, at once, so the screen that asked never sees it idle.
    @discardableResult
    func beginChange(_ change: PageChange, intent: String) -> PageProgress {
        self.change = change
        var progress = PageProgress(change: change, intent: intent)
        progress.note(change.line)
        progress.note("Made on Dream's server")
        show(progress, job: nil)
        asking.start(keeping: change.kind == .again ? nil : change.answers)
        return progress
    }

    /// Follows a page or change already started on Dream's server from its first event: one the
    /// app left mid-way, or that the screen was closed on. What's there so far comes in a rush,
    /// then the rest as it happens. Calls to this iPhone's tools run before (`ran`) aren't run
    /// again.
    @discardableResult
    func watch(_ job: ServerJob, intent: String, change: PageChange? = nil, ran: Set<String> = [], through transport: (any ComposeTransport)? = nil) async -> ServerWatch.Ending {
        self.change = change
        var progress = change.map { PageProgress(change: $0, intent: intent) } ?? PageProgress(intent: intent)
        progress.note(change?.line ?? "Request: \(intent)")
        progress.note("Following job \(job.id) on Dream's server again, for page \(job.page.uuidString)")
        show(progress, job: job)
        if let change, change.kind != .again { asking.start(keeping: change.answers) } else { asking.start() }
        guard let transport = transport ?? ComposeClient.dream else {
            progress.end("Sign in to see this page.")
            show(progress, job: job)
            return .failed
        }
        // The same tools as when it started, so a call the model makes now finds its tool.
        let request = change?.request(intent) ?? intent
        _ = offerDeviceTools(for: request, changing: change.flatMap { $0.kind == .again ? nil : $0.base }, ran: ran)
        return await follow(job, from: progress, through: transport)
    }

    /// Shows how a page on the server ended when it ended some other way: it came by sync, or
    /// the server lost it.
    func show(ending job: ServerJob, intent: String, with surface: Surface?, model: String = "", failure: String? = nil) {
        var progress = change.map { PageProgress(change: $0, intent: intent) } ?? PageProgress(intent: intent)
        if let failure { progress.end(failure) } else { progress.finish(surface, model: model) }
        show(progress, job: job)
    }

    private func begin(_ start: ComposeStart, page: UUID, from progress: PageProgress, through transport: any ComposeTransport) async -> ServerWatch.Ending {
        var progress = progress
        let job: ServerJob
        do {
            job = ServerJob(id: try await transport.start(start), page: page)
        } catch {
            progress.note("Failed: \(error.localizedDescription)")
            progress.end(error.localizedDescription)
            show(progress, job: nil)
            return .failed
        }
        progress.note("Job \(job.id), for page \(page.uuidString)")
        show(progress, job: job)
        onJob?(job)
        return await follow(job, from: progress, through: transport)
    }

    private func follow(_ job: ServerJob, from progress: PageProgress, through transport: any ComposeTransport) async -> ServerWatch.Ending {
        let watch = ServerWatch(job: job, progress: progress, transport: transport)
        watch.onChange = { [weak self] progress in self?.show(progress, job: job) }
        watch.ask = { [weak self] questions in
            guard let self else { return questions.map(\.leftToDream) }
            return await self.answer(questions)
        }
        let devices = self.devices
        watch.runTool = { call in await devices?.run(call) }
        devices?.onNote = { [weak watch] line in watch?.note(line) }
        self.watch = watch
        let ending = await watch.run()
        if self.watch === watch { self.watch = nil }
        devices?.onNote = nil
        if ending == .done, let locale = surface?.locale { Languages.remember(locale.language) }
        return ending
    }

    /// The server's questions: those about what Dream remembers are answered at once, and the rest
    /// wait on the screen, as when the page is made here.
    private func answer(_ questions: [Question]) async -> [Answer] {
        let known = await GapCheck.remembered(questions)
        return await asking.ask(questions, knowing: known)
    }
}
