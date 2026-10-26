import Foundation
import Observation
import StoreKit

/// The signed-in account's plan, as Dream's server counts it (`GET /api/usage`), and buying Dream
/// Plus with StoreKit 2. Every purchase, renewal and restore is sent to the server as the App
/// Store signed it, so the server's allowance follows; the App Store also tells the server
/// directly (App Store Server Notifications), which covers renewals while the app is closed.
@MainActor @Observable
final class Plan {
    static let shared = Plan()

    struct Status: Decodable, Equatable {
        struct Pages: Decodable, Equatable {
            let today: Int
            let perDay: Int
            let month: Int
            let perMonth: Int
        }

        struct Subscription: Decodable, Equatable {
            let product: String
            /// Milliseconds since 1970.
            let expiresAt: Double
            let renews: Bool?
        }

        struct Allowance: Decodable, Equatable {
            let pagesPerDay: Int
            let pagesPerMonth: Int
        }

        let plan: String
        let pages: Pages
        /// When more pages come, in seconds since 1970.
        let resetsAt: Double
        /// The account's id, given to StoreKit with each purchase so it's tied to this account.
        let accountToken: String
        let subscription: Subscription?
        let plans: [String: Allowance]

        var isPlus: Bool { plan == "plus" }
        var free: Allowance? { plans["free"] }
        var plus: Allowance? { plans["plus"] }
        var pagesLeftToday: Int { max(0, min(pages.perDay - pages.today, pages.perMonth - pages.month)) }
    }

    /// Dream Plus offered at the moment the allowance ran out, with the server's reason.
    struct Offer: Identifiable {
        let id = UUID()
        let reason: String
    }

    private(set) var status: Status?
    var offer: Offer?
    /// What went wrong with a purchase or restore, in plain words.
    private(set) var problem: String?

    private var started = false
    private var observers: [NSObjectProtocol] = []

    /// Listens for purchases made anywhere (another device, Ask to Buy, a renewal while open)
    /// from launch, as StoreKit asks, and for the allowance running out.
    func start() {
        guard !started else { return }
        started = true
        Task.detached(priority: .background) {
            for await update in Transaction.updates {
                await Plan.shared.handle(update)
            }
        }
        observers.append(NotificationCenter.default.addObserver(forName: Allowance.didRunOut, object: nil, queue: .main) { note in
            let reason = note.userInfo?["message"] as? String ?? ""
            let upgrade = note.userInfo?["upgrade"] as? Bool ?? false
            Task { @MainActor in Plan.shared.ranOut(reason: reason, upgrade: upgrade) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: Session.didChange, object: nil, queue: .main) { _ in
            Task { @MainActor in await Plan.shared.signedInOrOut() }
        })
        Task { await signedInOrOut() }
    }

    private func signedInOrOut() async {
        guard Session.isSignedIn else {
            status = nil
            return
        }
        await sendEntitlements()
        await refresh()
    }

    private func ranOut(reason: String, upgrade: Bool) {
        Analytics.send(.limitReached(kind: "pages"))
        Task { await refresh() }
        // A subscriber who's used a day's pages is told so where they are; there's nothing to sell them.
        if upgrade, offer == nil { offer = Offer(reason: reason) }
    }

    /// The plan and pages used, from the server.
    func refresh() async {
        guard let request = request("api/usage", method: "GET") else { return }
        if let fresh: Status = await send(request) { status = fresh }
    }

    // MARK: - Buying

    /// What StoreKit is given with a purchase: this account, so the App Store's notifications
    /// and the server agree on whose subscription it is.
    var purchaseOptions: Set<Product.PurchaseOption> {
        guard let token = status?.accountToken, let account = UUID(uuidString: token) else { return [] }
        return [.appAccountToken(account)]
    }

    /// After the store view's purchase: a verified transaction goes to the server, then is finished.
    func completed(_ result: Result<Product.PurchaseResult, any Error>) async {
        problem = nil
        switch result {
        case .success(.success(let verification)):
            if case .verified(let transaction) = verification { Analytics.send(.subscriptionStarted(product: transaction.productID)) }
            await handle(verification)
        case .success(.pending):
            problem = "Your purchase is waiting for approval. Dream Plus starts once it's approved."
        case .success(.userCancelled):
            break
        case .failure:
            problem = "The App Store couldn't complete that. Try again in a moment."
        @unknown default:
            break
        }
    }

    /// Asks the App Store for this Apple Account's purchases again, and sends them to the server.
    func restore() async {
        problem = nil
        do {
            try await AppStore.sync()
        } catch StoreKitError.userCancelled {
            return
        } catch {
            problem = "The App Store couldn't restore purchases just now. Try again in a moment."
            return
        }
        let found = await sendEntitlements()
        await refresh()
        if !found { problem = "There's no Dream Plus subscription on this Apple Account." }
    }

    /// Sends what this Apple Account has bought, and reads the plan again: after the store's own
    /// restore button, say.
    func resync() async {
        guard Session.isSignedIn else { return }
        await sendEntitlements()
        await refresh()
    }

    private func handle(_ verification: VerificationResult<Transaction>) async {
        // StoreKit checks the App Store's signature on the phone; the server checks it again.
        guard case .verified(let transaction) = verification else { return }
        if Products.all.contains(transaction.productID), Session.isSignedIn {
            guard await post([verification.jwsRepresentation]) else { return }
        }
        await transaction.finish()
    }

    /// Sends the subscriptions this Apple Account has now. Returns whether there were any.
    @discardableResult
    private func sendEntitlements() async -> Bool {
        var signed: [String] = []
        for await verification in Transaction.currentEntitlements {
            if case .verified(let transaction) = verification, Products.all.contains(transaction.productID) {
                signed.append(verification.jwsRepresentation)
            }
        }
        guard !signed.isEmpty else { return false }
        await post(Array(signed.prefix(10)))
        return true
    }

    /// Gives the server signed transactions; it checks them with Apple's certificates.
    @discardableResult
    private func post(_ signedTransactions: [String]) async -> Bool {
        guard var request = request("api/appstore/transactions", method: "POST"),
              let body = try? JSONSerialization.data(withJSONObject: ["signedTransactions": signedTransactions]) else { return false }
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let fresh: Status = await send(request) else { return false }
        status = fresh
        return true
    }

    // MARK: - Server

    private func request(_ path: String, method: String) -> URLRequest? {
        guard let base = ServerAddress.dream, Session.isSignedIn else { return nil }
        var request = URLRequest(url: base.appending(path: path), timeoutInterval: 20)
        request.httpMethod = method
        Session.authorize(&request)
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async -> T? {
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            if let message = ChatCompletions.errorMessage(in: data), request.httpMethod == "POST" { problem = message }
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
