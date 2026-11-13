import FoundationModels
import SwiftUI

/// What happened behind the scenes: which model ran, the generation log, and the raw template.
struct DebugView: View {
    let surface: Surface?
    let values: [String: Double]
    let log: [String]
    let modelName: String
    @AppStorage("provider") private var provider = Composer.Provider.privateCloud.rawValue
    @AppStorage("reasoning") private var reasoning = "light"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Last used", value: modelName.isEmpty ? "—" : modelName)
                    LabeledContent("Private Cloud Compute", value: AppleModels.cloudStatus)
                    LabeledContent("On this iPhone", value: AppleModels.deviceStatus)
                    Picker("Write pages with", selection: $provider) {
                        Text("Private Cloud Compute").tag(Composer.Provider.privateCloud.rawValue)
                        Text("This iPhone").tag(Composer.Provider.onDevice.rawValue)
                    }
                    Picker("Reasoning", selection: $reasoning) {
                        Text("Light").tag("light")
                        Text("Moderate").tag("moderate")
                        Text("Deep").tag("deep")
                    }
                } header: {
                    Text("Apple Intelligence")
                } footer: {
                    Text("Every page is written by Apple's models. Private Cloud Compute runs Apple's larger model on Apple silicon servers that keep nothing; it reasons before it writes. The model on this iPhone works offline, from a shorter brief. If the chosen one can't be used, Dream uses the other.")
                }
                ShareServerSettings()
                WebSearchSettings()
                SyncSection()
                Section {
                    NavigationLink("Connections") { ConnectionsView() }
                }
                Section("Log") {
                    ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                }
                if let surface, surface.hasLogic {
                    Section("Your values") {
                        ForEach(surface.inputs, id: \.name) { input in
                            LabeledContent(input.name, value: surface.display(input.name, values[input.name] ?? input.initial))
                        }
                    }
                }
                if let template {
                    Section("Template") {
                        Text(template)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Under the hood")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if let template {
                    ToolbarItem(placement: .topBarLeading) {
                        ShareLink(item: template)
                    }
                }
            }
        }
    }

    private var template: String? {
        surface.map { json($0) }
    }

    private func json(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}
