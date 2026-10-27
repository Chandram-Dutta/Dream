import StoreKit
import SwiftUI

/// The account's plan, for the account screen: pages used today, the model that makes them, how
/// long it thinks (Dream Plus picks), Dream Plus, restoring purchases, and managing the
/// subscription in the system's own sheet.
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
                if let models = status.models, !models.isEmpty {
                    ModelRow(models: models, canPick: status.isPlus && models.count > 1)
                }
                if let levels = status.thinking, !levels.isEmpty {
                    ThinkingRow(levels: levels)
                }
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

/// The model that makes pages. Dream Plus picks from the server's list, each with a line on what
/// it's good for; everyone else sees the one theirs are made with.
private struct ModelRow: View {
    let models: [Plan.Status.ModelOption]
    let canPick: Bool
    @AppStorage(ModelChoice.key) private var picked = ""

    var body: some View {
        // The default is the first; a pick the server no longer offers falls back to it.
        let current = models.first { $0.id == picked } ?? models[0]
        if canPick {
            Picker("Model", selection: Binding(get: { current.id }, set: { picked = $0 == models[0].id ? "" : $0 })) {
                ForEach(models) { model in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name)
                        Text(model.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(model.id)
                }
            }
            .pickerStyle(.navigationLink)
        } else {
            LabeledContent("Model", value: models[0].name)
        }
    }
}

/// How long the model thinks before it answers, for Dream Plus, from the levels the server
/// offers this account. Longer takes more time and suits harder questions.
private struct ThinkingRow: View {
    let levels: [String]
    @AppStorage(ThinkingChoice.key) private var level = "low"

    var body: some View {
        Picker("Thinking", selection: Binding(get: { levels.contains(level) ? level : "low" }, set: { level = $0 })) {
            ForEach(levels, id: \.self) { each in
                let (name, note) = Self.describe(each)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(each)
            }
        }
        .pickerStyle(.navigationLink)
    }

    private static func describe(_ level: String) -> (String, String) {
        switch level {
        case "none": ("Off", "Answers at once, without thinking first")
        case "low": ("Low", "Quickest pages")
        case "medium": ("Medium", "A little more care")
        case "high": ("High", "Thinks longer, for hard questions")
        case "max": ("Max", "As long as it needs")
        default: (level.capitalized, "")
        }
    }
}
