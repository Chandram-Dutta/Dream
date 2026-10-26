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
        Connections.registerLive()
    }

    /// What the screen would do with a surface's connected services: read each source again,
    /// as a pull does, and show the buttons for write tools as they'd read.
    static func showLive(_ surface: Surface) async {
        for collection in surface.recordCollections where collection.source != nil {
            print("List \(collection.name) is filled from \(collection.source ?? "")")
        }
        for source in surface.liveSources where source.isConnection {
            do {
                let reading = try await LiveSources.read(source, again: true)
                print("Read \(source.name) again, as a pull would:")
                for (input, value) in surface.liveValues(reading, from: source.name).sorted(by: { $0.key < $1.key }) {
                    print("  \(input) = \(value.plain)")
                }
                for (collection, entries) in surface.serviceRecords(reading, from: source.name) {
                    let title = surface.collection(collection)?.titleField?.name ?? ""
                    print("  \(collection): \(entries.count) entries (\(entries.compactMap { $0[title]?.textValue }.joined(separator: ", ")))")
                }
            } catch {
                print("Couldn't read \(source.name) again: \(error.localizedDescription)")
            }
        }
        let performer = ConnectionPerformer()
        for action in surface.actions ?? [] where action.isConnection {
            let resolved = ResolvedAction(name: action.name, kind: action.kind, text: action.fields, start: nil, hasTime: false, minutes: nil)
            print("Button \(action.name): “\(performer.sentence(resolved))”\(performer.needsConfirmation(resolved) ? ", asks first" : "") — \(performer.details(resolved).joined(separator: "; "))")
        }
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
