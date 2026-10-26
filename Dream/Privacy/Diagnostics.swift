import Foundation
import MetricKit

/// Crash, hang and slow-launch reports, from MetricKit, sent to Dream's server
/// (`POST /api/diagnostics`, Server/src/diagnostics.ts) while the user lets Dream improve
/// (ImproveDream.swift). iOS gathers them on the phone and hands them over at most once a day,
/// or at the next launch after a crash.
///
/// A report says which version of Dream and iOS, which kind of iPhone, and where in the code it
/// happened, as stack frames (binary names and offsets, symbolicated later with the build's
/// dSYM). It carries no account, no region, and nothing anyone asked for or saw: an exception's
/// message is left out, since it can quote the app's data.
final class Diagnostics: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = Diagnostics()

    @MainActor private var isListening = false

    /// What couldn't be sent, kept for the next launch: a file for each upload, a few at most.
    private static var pending: URL {
        URL.cachesDirectory.appending(path: "Diagnostics", directoryHint: .isDirectory)
    }
    private static let maxPending = 10

    /// What the server takes in one upload (Server/src/metrickit.ts), with room to spare.
    static let maxReports = 20
    static let maxUploadBytes = 200_000
    /// A stack bigger than this is cut down to the thread that crashed or hung, or left out.
    static let maxStackBytes = 64_000

    @MainActor func start() {
        guard !isListening else { return }
        MXMetricManager.shared.add(self)
        isListening = true
        Task.detached { await Self.sendPending() }
    }

    @MainActor func stop() {
        guard isListening else { return }
        MXMetricManager.shared.remove(self)
        isListening = false
        try? FileManager.default.removeItem(at: Self.pending)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let reports = payloads.flatMap(Report.all)
        guard !reports.isEmpty, ImproveDream.isOn else { return }
        Task.detached { await Self.send(reports) }
    }

    // MARK: - Sending

    struct Upload: Codable {
        var format = 1
        var reports: [Report]
    }

    /// Reports as uploads the server takes: at most `maxReports` and `maxUploadBytes` each.
    static func uploads(_ reports: [Report]) -> [Data] {
        let encoder = JSONEncoder()
        func encoded(_ reports: [Report]) -> Data? { try? encoder.encode(Upload(reports: reports)) }
        var bodies: [Data] = []
        var batch: [Report] = []
        for report in reports {
            let bigger = batch + [report]
            if !batch.isEmpty, bigger.count > maxReports || (encoded(bigger)?.count ?? .max) > maxUploadBytes {
                if let body = encoded(batch) { bodies.append(body) }
                batch = [report]
            } else {
                batch = bigger
            }
        }
        if !batch.isEmpty, let body = encoded(batch) { bodies.append(body) }
        return bodies
    }

    private static func send(_ reports: [Report]) async {
        for body in uploads(reports) where ImproveDream.isOn {
            if await !post(body) { keep(body) }
        }
    }

    private static func keep(_ body: Data) {
        let manager = FileManager.default
        try? manager.createDirectory(at: pending, withIntermediateDirectories: true)
        guard ((try? manager.contentsOfDirectory(at: pending, includingPropertiesForKeys: nil)) ?? []).count < maxPending else { return }
        try? body.write(to: pending.appending(path: "\(UUID().uuidString).json"), options: .atomic)
    }

    private static func sendPending() async {
        guard ImproveDream.isOn, let files = try? FileManager.default.contentsOfDirectory(at: pending, includingPropertiesForKeys: nil) else { return }
        for file in files {
            guard let body = try? Data(contentsOf: file) else { continue }
            guard await post(body) else { return }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Anonymous: no session and no cookies, so a report can't be tied to anyone.
    private static func post(_ body: Data) async -> Bool {
        guard let base = ServerAddress.dream else { return false }
        var request = URLRequest(url: base.appending(path: "api/diagnostics"), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (_, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return false }
        // A report the server refuses won't be accepted later either.
        return (200..<500).contains(status) && status != 429
    }
}

extension Diagnostics {
    /// One crash, hang or slow launch, as the server stores it.
    struct Report: Codable {
        enum Kind: String, Codable {
            case crash, hang, launch
        }

        var kind: Kind
        var app: String
        var build: String
        var os: String
        var device: String
        var testFlight: Bool
        /// The day or so MetricKit's payload covers, in seconds since 1970.
        var start: Int
        var end: Int
        /// How long a hang or launch took, in seconds.
        var duration: Double?
        var exceptionType: Int?
        var exceptionCode: Int?
        var signal: Int?
        /// An Objective-C exception's name and class, like NSRangeException; never its message.
        var exceptionName: String?
        var exceptionClass: String?
        var terminationReason: String?
        /// MetricKit's call stack tree, as it gives it.
        var stack: JSONValue?

        static func all(in payload: MXDiagnosticPayload) -> [Report] {
            let start = Int(payload.timeStampBegin.timeIntervalSince1970)
            let end = Int(payload.timeStampEnd.timeIntervalSince1970)
            func report(_ kind: Kind, _ diagnostic: MXDiagnostic, stack: MXCallStackTree?) -> Report {
                let meta = diagnostic.metaData
                return Report(kind: kind, app: diagnostic.applicationVersion, build: meta.applicationBuildVersion,
                              os: meta.osVersion, device: meta.deviceType, testFlight: meta.isTestFlightApp,
                              start: start, end: end, stack: stack.flatMap(trimmed))
            }
            var reports: [Report] = []
            for crash in payload.crashDiagnostics ?? [] {
                var item = report(.crash, crash, stack: crash.callStackTree)
                item.exceptionType = crash.exceptionType?.intValue
                item.exceptionCode = crash.exceptionCode?.intValue
                item.signal = crash.signal?.intValue
                item.exceptionName = crash.exceptionReason?.exceptionName
                item.exceptionClass = crash.exceptionReason?.className
                item.terminationReason = crash.terminationReason.map { String($0.prefix(200)) }
                reports.append(item)
            }
            for hang in payload.hangDiagnostics ?? [] {
                var item = report(.hang, hang, stack: hang.callStackTree)
                item.duration = hang.hangDuration.converted(to: .seconds).value
                reports.append(item)
            }
            for launch in payload.appLaunchDiagnostics ?? [] {
                var item = report(.launch, launch, stack: launch.callStackTree)
                item.duration = launch.launchDuration.converted(to: .seconds).value
                reports.append(item)
            }
            return reports
        }

        /// The stack as MetricKit gives it, or only the thread that crashed or hung if the whole
        /// tree is too big; nil if even that is.
        private static func trimmed(_ tree: MXCallStackTree) -> JSONValue? {
            let data = tree.jsonRepresentation()
            guard var value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
            if data.count <= maxStackBytes { return value }
            guard case .object(var object) = value, case .array(let stacks) = object["callStacks"] else { return nil }
            object["callStacks"] = .array(stacks.filter { $0["threadAttributed"] == .bool(true) })
            value = .object(object)
            guard let smaller = try? JSONEncoder().encode(value), smaller.count <= maxStackBytes else { return nil }
            return value
        }
    }
}
