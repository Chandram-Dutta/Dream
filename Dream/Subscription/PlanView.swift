import StoreKit
import SwiftUI

/// Dream Plus, offered when the free pages run out and from the account screen. It says what
/// changes, in numbers, and leaves the buying to the App Store's own controls: the price and how
/// it renews, restoring purchases, and the terms and privacy links.
struct PlanView: View {
    /// What ran out, as the server said it, when that's why this is showing.
    var reason: String?
    @Environment(\.dismiss) private var dismiss
    private let palette = Accent.indigo.palette

    var body: some View {
        SubscriptionStoreView(productIDs: Products.all) {
            PlanPitch(reason: reason, palette: palette)
        }
        .subscriptionStoreControlStyle(.picker)
        .subscriptionStoreButtonLabel(.multiline)
        .storeButton(.visible, for: .restorePurchases)
        .storeButton(.visible, for: .cancellation)
        .subscriptionStorePolicyDestination(url: Products.terms, for: .termsOfService)
        .subscriptionStorePolicyDestination(url: Products.privacy ?? Products.terms, for: .privacyPolicy)
        .inAppPurchaseOptions { _ in Plan.shared.purchaseOptions }
        .onInAppPurchaseCompletion { _, result in
            await Plan.shared.completed(result)
            if Plan.shared.status?.isPlus == true { dismiss() }
        }
        .containerBackground(for: .subscriptionStoreFullHeight) {
            LinearGradient(colors: [palette.accent.opacity(0.16), palette.companion.opacity(0.05), Color(.systemBackground)], startPoint: .top, endPoint: .center)
        }
        .tint(palette.accent)
        .task { await Plan.shared.refresh() }
        .onAppear { Analytics.send(.paywallShown) }
        // A restore from the store's own button reaches the server here.
        .onDisappear { Task { await Plan.shared.resync() } }
    }
}

/// What Dream Plus is: more pages and a choice of how long Dream thinks, and nothing else held back.
private struct PlanPitch: View {
    let reason: String?
    let palette: Palette

    var body: some View {
        let plan = Plan.shared
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "sparkles")
                .font(.title.weight(.semibold))
                .foregroundStyle(palette.gradient)
            VStack(alignment: .leading, spacing: 6) {
                Text("Dream Plus")
                    .font(.display(.largeTitle, weight: .bold))
                Text(reason ?? "More pages, every day.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let status = plan.status {
                if !status.isPlus {
                    PagesMeter(status: status, palette: palette)
                        .panel(palette)
                }
                Comparison(status: status, palette: palette)
            }
            if let problem = plan.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 28)
    }
}

/// The two plans side by side, in the numbers that differ.
private struct Comparison: View {
    let status: Plan.Status
    let palette: Palette

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Text("Free").foregroundStyle(.secondary)
                Text("Plus").foregroundStyle(palette.gradient)
            }
            .font(.subheadline.weight(.semibold))
            row("Pages a day", free: status.free?.pagesPerDay, plus: status.plus?.pagesPerDay)
            row("Pages a month", free: status.free?.pagesPerMonth, plus: status.plus?.pagesPerMonth)
        }
        .padding(.vertical, 4)
        Text("Plus also lets you choose how long Dream thinks before it answers, for harder questions. A change to a page counts as a page. Everything else, from web search to sharing, is the same on both.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ label: String, free: Int?, plus: Int?) -> some View {
        GridRow {
            Text(label)
            Text(free.map(String.init) ?? "–").monospacedDigit().foregroundStyle(.secondary)
            Text(plus.map(String.init) ?? "–").monospacedDigit().font(.display(.body)).foregroundStyle(palette.numberGradient)
        }
    }
}

/// Pages used today out of the day's allowance, and when more come.
struct PagesMeter: View {
    let status: Plan.Status
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(status.pages.today) of \(status.pages.perDay) pages")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Gauge(value: Double(min(status.pages.today, status.pages.perDay)), in: 0...Double(max(status.pages.perDay, 1))) {
                EmptyView()
            }
            .gaugeStyle(.accessoryLinearCapacity)
            .tint(Gradient(colors: [palette.accent, palette.companion]))
            .accessibilityLabel("Pages today")
            .accessibilityValue("\(status.pages.today) of \(status.pages.perDay)")
            Text(status.whenMore)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

extension Plan.Status {
    /// When pages come back, in the reader's own time.
    var whenMore: String {
        let date = Date(timeIntervalSince1970: resetsAt)
        let monthUsed = pages.month >= pages.perMonth
        if monthUsed {
            return "This month's \(pages.perMonth) are used. More on \(date.formatted(.dateTime.day().month(.wide)))."
        }
        let left = pagesLeftToday
        let at = date.formatted(date: .omitted, time: .shortened)
        return left == 0 ? "More at \(at)." : "\(left) left today. The count starts again at \(at)."
    }
}

extension View {
    /// Offers Dream Plus at the moment the free allowance runs out (`Plan.offer`).
    func offeringPlans() -> some View {
        modifier(PlanOffering())
    }
}

private struct PlanOffering: ViewModifier {
    @Bindable private var plan = Plan.shared

    func body(content: Content) -> some View {
        content.sheet(item: $plan.offer) { offer in
            PlanView(reason: offer.reason)
        }
    }
}
