import StoreKit
import SwiftUI

/// The account's plan, for the account screen: pages used today, the model that makes them and
/// how long it thinks (the same picks as the chip by the composer, ModelPicker.swift), Dream Plus,
/// restoring purchases, and managing the subscription in the system's own sheet.
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
                let options = ModelOptions(status)
                if !options.models.isEmpty {
                    ModelRow(options: options)
                }
                ThinkingRow(options: options)
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

/// The model that makes pages, picked from the ones the plan offers, each with a line on what it's
/// good for (Auto among them, when the server offers it); with only one, the one theirs are made with.
private struct ModelRow: View {
    let options: ModelOptions
    @AppStorage(ModelChoice.key) private var picked = ""

    var body: some View {
        if let current = options.model(picked: picked) {
            if options.canChooseModel {
                Picker("Model", selection: Binding(get: { current.id }, set: { id in
                    if let model = options.models.first(where: { $0.id == id }) { picked = options.stored(model) }
                })) {
                    ForEach(options.models) { model in
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
                LabeledContent("Model", value: current.name)
            }
        }
    }
}

/// How long the model thinks before it answers, from the levels the server offers this account.
/// Longer takes more time and suits harder questions. Not beside Auto, which picks its own.
private struct ThinkingRow: View {
    let options: ModelOptions
    @AppStorage(ModelChoice.key) private var picked = ""
    @AppStorage(ThinkingChoice.key) private var level = ThinkingChoice.standard

    var body: some View {
        if options.hasThinking(with: options.model(picked: picked)), let shown = ThinkingChoice.shown(level, among: options.levels) {
            Picker("Thinking", selection: Binding(get: { shown }, set: { level = $0 })) {
                ForEach(options.levels, id: \.self) { each in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ThinkingChoice.name(each))
                        Text(ThinkingChoice.note(each))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(each)
                }
            }
            .pickerStyle(.navigationLink)
        }
    }
}
