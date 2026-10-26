import Foundation

// Connected services on the bench: servers registered with -mcp, and sign-in up to the browser.

@MainActor
enum BenchConnections {
    static func connect(_ addresses: [String], reads: String, remembered: [Remembered]) async {
        let trusted = Set(reads.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        var connections: [Connection] = []
        for address in addresses {
            do {
                let url = try ConnectionStore.endpoint(from: address)
                var connection = Connection(url: url, name: url.host() ?? address)
                let description = try await ConnectionSessions.shared.describe(url, id: connection.id)
                connection.name = description.name
                connection.tools = description.tools.map { tool in
                    var tool = tool
                    tool.userSaysReadsOnly = trusted.contains("all") || trusted.contains(tool.name)
                    return tool
                }
                connections.append(connection)
                print("Connected \(connection.name) (\(url.absoluteString)):")
                for tool in connection.tools {
                    let hint = tool.readOnlyHint.map { $0 ? "reads" : "writes" } ?? "no hint"
                    print("  \(tool.name): \(hint)\(tool.userSaysReadsOnly ? ", treated as reading" : "")\(tool.isRepresentable ? "" : ", inputs can't be represented")")
                }
            } catch {
                print("Couldn't connect \(address): \(error.localizedDescription)")
            }
        }
        let fixed = connections
        Connections.source = Connections.Source(
            connections: { fixed },
            call: { connection, tool, arguments in try await ConnectionSessions.shared.call(connection, tool: tool, arguments: arguments) },
            personalDetails: { remembered.map(\.detail) })
    }

    static func showPicks(_ requests: [String]) {
        for request in requests {
            let picked = ToolPicker.pick(for: request, from: Connections.readingTools)
            print("\(request) → \(picked.isEmpty ? "nothing" : picked.map { "\($0.connection.name) \($0.tool.name)" }.joined(separator: ", "))")
        }
    }

    static func trySignIn(_ address: String) async {
        do {
            let url = try ConnectionStore.endpoint(from: address)
            let id = UUID()
            let challenge: [String: String]
            do {
                _ = try await ConnectionSessions.shared.describe(url, id: id)
                print("\(url.absoluteString) answered without a sign-in.")
                return
            } catch let challenged as Challenged {
                challenge = challenged.headers
                print("Challenge: \(challenge.first { $0.key.lowercased() == "www-authenticate" }?.value ?? "(none)")")
            }
            let plan = try await SignIn.plan(for: url, challenge: challenge)
            print("Resource: \(plan.resource)\nIssuer: \(plan.issuer)\nAuthorize: \(plan.authorizationEndpoint)\nToken: \(plan.tokenEndpoint)")
            print("Registration: \(plan.registrationEndpoint?.absoluteString ?? "none")\nScopes: \(plan.scopes.joined(separator: " "))\nReturns its issuer: \(plan.sendsIssuer)")
            let client = try await SignIn.client(for: plan, existing: nil)
            print("Registered client \(client.clientID) (\(client.authMethod)\(client.clientSecret == nil ? "" : ", with a secret"))")
            let attempt = try SignIn.attempt(plan, client: client)
            print("Sign-in page: \(attempt.url.absoluteString)")
            // A reply with the wrong state must be refused before anything is sent.
            let forged = URL(string: "\(SignIn.redirectURI.absoluteString)?code=x&state=wrong&iss=\(plan.issuer.absoluteString)")!
            do {
                _ = try await SignIn.finish(attempt, callback: forged, plan: plan, client: client)
                print("A forged reply was accepted. That's a bug.")
            } catch {
                print("A forged reply was refused: \(error.localizedDescription)")
            }
        } catch {
            print("Sign-in stopped: \(error.localizedDescription)")
        }
    }
}
