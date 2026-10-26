import StoreKit
import SwiftUI

/// The account's plan, for the account screen: pages used today, Dream Plus, restoring
/// purchases, and managing the subscription in the system's own sheet.
struct PlanSection: View {
    @State private var showingPlans = false
    @State private var managing = false
    private let palette = Accent.indigo.palette

    var body: some View {
        let plan = Plan.shared
        Section {
            if let status = plan.status {
                PagesMeter(status: status, palette: palette)
                    .padding(.vertical, 4)
                if status.isPlus {
                    Button("Manage subscription") { managing = true }
                } else {
                    Button("See Dream Plus") { showingPlans = true }
                }
                Button("Restore purchases") { Task { await plan.restore() } }
                if let problem = plan.problem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } else {
                Text("Sign in to see how many pages you have.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(plan.status?.isPlus == true ? "Dream Plus" : "Plan")
        } footer: {
            if let subscription = plan.status?.subscription {
                let date = Date(timeIntervalSince1970: subscription.expiresAt / 1000).formatted(date: .long, time: .omitted)
                Text(subscription.renews == false ? "Dream Plus ends on \(date). It won't renew." : "Dream Plus renews on \(date). Cancel any time in Manage subscription.")
            }
        }
        .manageSubscriptionsSheet(isPresented: $managing)
        .onChange(of: managing) { if !managing { Task { await plan.refresh() } } }
        .sheet(isPresented: $showingPlans) { PlanView() }
        .task { await plan.refresh() }
    }
}
