import SwiftUI

/// Web search, in Under the hood: the key that shows Dream's server it's this app asking, and,
/// for trying a server under `wrangler dev`, a server other than the sharing one.
struct WebSearchSettings: View {
    @AppStorage("webServer") private var server = ""
    @State private var key = ""
    @State private var hasKey = Keychain.read("web") != nil

    var body: some View {
        Section {
            SecureField(hasKey ? "Web search key saved" : "Web search key", text: $key)
                .textContentType(.password)
                .onSubmit {
                    Keychain.save(key, for: "web")
                    hasKey = Keychain.read("web") != nil
                    key = ""
                }
            TextField(WebService.base?.host() ?? "The sharing server", text: $server)
                .keyboardType(.URL)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !server.isEmpty, ServerAddress.normalized(server) == nil {
                Text("That doesn't look like a server address. Use its https address, like dream-share.example.workers.dev.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Web search")
        } footer: {
            Text("Dream searches the web and reads pages through its own server, for whoever's signed in. The iPhone shows the server it's Dream with App Attest; this key does the same where that isn't set up, and also reaches the model through the server. The key stays in the Keychain. Searches are written to carry only what a question is about, leaving out what Dream knows about you. An empty server uses the sharing server.")
        }
    }
}
