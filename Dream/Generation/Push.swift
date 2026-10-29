import Foundation

// Notifications from Dream's server (docs/ServerGeneration.md, Stage 3; Server/src/push.ts): a page
// made there with nobody watching says when it's ready, when Dream has a question about it, or when
// it needs one of this iPhone's own tools, which only run with the app open.
// What a notification carries, where tapping one goes, and which of Apple's servers this build's
// token belongs to. Nothing here needs an iPhone, so Tools/tests.sh checks it on a Mac; asking,
// registering and opening are Dream/Account/Notifications.swift.

/// What a notification from Dream's server carries beside its alert (contract.ts, PushPayload):
/// the page, and the job making it while the server has it.
struct PushPayload: Equatable, Sendable {
    enum Kind: String, Sendable {
        /// The page is made.
        case done
        /// Questions wait on an answer.
        case asking
        /// The page waits on one of this iPhone's tools (a connected service, a journey), which
        /// runs once the page is open again, asking first as it always does (DeviceTools.swift).
        case device
    }

    let page: UUID
    let job: String
    let kind: Kind

    /// From a notification's userInfo. Nil for anything that isn't one of Dream's pages.
    init?(_ userInfo: [AnyHashable: Any]) {
        guard let page = (userInfo["page"] as? String).flatMap(UUID.init(uuidString:)),
              let job = userInfo["job"] as? String, !job.isEmpty,
              let kind = (userInfo["kind"] as? String).flatMap(Kind.init) else { return nil }
        self.page = page
        self.job = job
        self.kind = kind
    }

    init(page: UUID, job: String, kind: Kind) {
        self.page = page
        self.job = job
        self.kind = kind
    }

    /// The job making it, as the shelf follows one.
    var serverJob: ServerJob { ServerJob(id: job, page: page) }
}

/// Where tapping a notification goes: in the app, a saved page (SavedSurface) or one still being
/// made (FormingPage).
enum PushOpening<Saved, Forming> {
    /// The finished page, saved here under its id.
    case page(Saved)
    /// The page still being made, as the shelf shows it.
    case forming(Forming)
    /// Neither is here: one started on another iPhone, or forgotten since.
    case shelf

    /// The page if it's saved, whatever the notification said, since it may have finished since;
    /// the page being made if it's still started here, whose screen follows it again and puts its
    /// question, or the call to this iPhone's tools it waits on, in front of the user; the shelf
    /// otherwise.
    static func destination(for payload: PushPayload?, saved: (UUID) -> Saved?, forming: (UUID) -> Forming?) -> PushOpening {
        guard let payload else { return .shelf }
        if let page = saved(payload.page) { return .page(page) }
        if let page = forming(payload.page) { return .forming(page) }
        return .shelf
    }
}

extension PushOpening: Equatable where Saved: Equatable, Forming: Equatable {}

/// Which APNs a device token is for. A build signed for development gets tokens only the sandbox
/// takes; TestFlight and the App Store, production's.
enum PushEnvironment: String, Sendable {
    case sandbox, production

    /// This build's, from the provisioning profile Xcode embeds when it signs for development or
    /// ad hoc. The App Store and TestFlight embed none, and are production.
    static let current = of(profile: Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision").flatMap { try? Data(contentsOf: $0) })

    /// From a provisioning profile: a signed message with the profile's property list inside it,
    /// whose entitlements say which APNs the app is signed for.
    static func of(profile: Data?) -> PushEnvironment {
        guard let profile,
              let start = profile.range(of: Data("<?xml".utf8)),
              let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: profile[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return .production }
        return entitlements["aps-environment"] as? String == "development" ? .sandbox : .production
    }
}

extension Data {
    /// A device token as Dream's server takes it: lowercase hex.
    var hexToken: String { map { String(format: "%02x", $0) }.joined() }
}
