import CoreGraphics
import Foundation

// New pages made on Dream's server (docs/ServerGeneration.md, Stage 1). The page loop runs there,
// whether or not anyone watches; the composer starts it, follows its events (ServerCompose.swift)
// and shows them through the same state as a page made here. Changes to a page are still made
// here (Composer.edit).

extension Composer {
    /// Starts a new page on Dream's server, and follows it until it's over or this is stopped.
    @discardableResult
    func composeOnServer(intent: String, image: CGImage?, through transport: (any ComposeTransport)? = nil) async -> ServerWatch.Ending {
        let started = Date()
        let page = UUID()
        var progress = PageProgress(intent: intent)
        progress.note("Request: \(intent)\(image == nil ? "" : " (with photo)")")
        progress.note("Made on Dream's server")
        show(progress, job: nil)
        asking.start()
        Analytics.send(.pageRequested(withPhoto: image != nil))
        guard let transport = transport ?? ComposeClient.dream else {
            progress.end("Sign in to make pages.")
            show(progress, job: nil)
            return .failed
        }
        let context = await Prompts.context(for: intent)
        let job: ServerJob
        do {
            let id = try await transport.start(ComposeStart(intent: intent, image: image, page: page, context: context))
            job = ServerJob(id: id, page: page)
        } catch {
            progress.note("Failed: \(error.localizedDescription)")
            progress.end(error.localizedDescription)
            show(progress, job: nil)
            countFailure(error, changing: false, since: started)
            return .failed
        }
        progress.note("Job \(job.id), for page \(page.uuidString)")
        show(progress, job: job)
        onJob?(job)
        return await follow(job, from: progress, since: started, through: transport)
    }

    /// Follows a page already started on Dream's server from its first event: one the app left
    /// mid-way, or that the screen was closed on. What's there so far comes in a rush, then the
    /// rest as it happens.
    @discardableResult
    func watch(_ job: ServerJob, intent: String, since started: Date, through transport: (any ComposeTransport)? = nil) async -> ServerWatch.Ending {
        var progress = PageProgress(intent: intent)
        progress.note("Request: \(intent)")
        progress.note("Following job \(job.id) on Dream's server again, for page \(job.page.uuidString)")
        show(progress, job: job)
        asking.start()
        guard let transport = transport ?? ComposeClient.dream else {
            progress.end("Sign in to see this page.")
            show(progress, job: job)
            return .failed
        }
        return await follow(job, from: progress, since: started, through: transport)
    }

    /// Shows how a page on the server ended when it ended some other way: it came by sync, or
    /// the server lost it.
    func show(ending job: ServerJob, intent: String, with surface: Surface?, model: String = "", failure: String? = nil) {
        var progress = PageProgress(intent: intent)
        if let failure { progress.end(failure) } else { progress.finish(surface, model: model) }
        show(progress, job: job)
    }

    private func follow(_ job: ServerJob, from progress: PageProgress, since started: Date, through transport: any ComposeTransport) async -> ServerWatch.Ending {
        let watch = ServerWatch(job: job, progress: progress, transport: transport)
        watch.onChange = { [weak self] progress in self?.show(progress, job: job) }
        watch.ask = { [weak self] questions in
            guard let self else { return questions.map(\.leftToDream) }
            return await self.answer(questions)
        }
        self.watch = watch
        let ending = await watch.run()
        if self.watch === watch { self.watch = nil }
        switch ending {
        case .done:
            if let locale = surface?.locale { Languages.remember(locale.language) }
            countFinished(changing: false, since: started)
        case .failed:
            countFailure(ServerPageFailure(), changing: false, since: started)
        case .gone, .stopped:
            break
        }
        return ending
    }

    /// The server's questions: those about what Dream remembers are answered at once, and the rest
    /// wait on the screen, as when the page is made here.
    private func answer(_ questions: [Question]) async -> [Answer] {
        let known = await GapCheck.remembered(questions)
        return await asking.ask(questions, knowing: known)
    }
}

/// A page the server couldn't make. What it said can quote the request, so it's never counted.
private struct ServerPageFailure: Error {}
