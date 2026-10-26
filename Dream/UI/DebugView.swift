import FoundationModels
import SwiftUI

/// What happened behind the scenes: which model ran, the generation log, and the raw template.
struct DebugView: View {
    let surface: Surface?
    let values: [String: Double]
    let log: [String]
    let modelName: String
    @AppStorage("provider") private var provider = Composer.Provider.xai.rawValue
    @AppStorage("xaiModel") private var xaiModel = Composer.xaiModelID
    @State private var xaiKey = ""
    @State private var hasXAIKey = XAILanguageModel.savedKey != nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Last used", value: modelName.isEmpty ? "—" : modelName)
                    LabeledContent("Private Cloud Compute", value: String(describing: PrivateCloudComputeLanguageModel().availability))
                    Picker("Model", selection: $provider) {
                        Text("Grok").tag(Composer.Provider.xai.rawValue)
                        Text("Private Cloud Compute").tag(Composer.Provider.privateCloud.rawValue)
                    }
                    if provider == Composer.Provider.xai.rawValue {
                        SecureField(hasXAIKey ? "xAI API key saved" : "xAI API key", text: $xaiKey)
                            .textContentType(.password)
                            .onSubmit {
                                Keychain.save(xaiKey, for: "xai")
                                hasXAIKey = XAILanguageModel.savedKey != nil
                                xaiKey = ""
                            }
                        TextField("Grok model", text: $xaiModel)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                } header: {
                    Text("Model")
                } footer: {
                    Text("Grok sends requests to xAI with your API key, kept in the Keychain. Private Cloud Compute needs an entitlement Apple grants on request. If the chosen model can't be used, Dream tries the other one.")
                }
                ShareServerSettings()
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
