import Foundation

// Runs the composer on this Mac and prints what came out, so prompt and checker changes can be
// judged without the app. Build and run with Tools/bench.sh. It uses Grok, with XAI_API_KEY set
// (bench.sh reads it from the login Keychain). Settings go as "-name value", like "-xaiModel grok-4.7".

let defaultRequests = [
    "what is compound interest",
    "split a restaurant bill between friends, with tip",
    "who was Ada Lovelace",
    "is it worth buying solar panels for my house",
]

@MainActor func run(_ requests: [String]) async {
    var problemCount = 0
    for request in requests {
        print("\n==================== \(request)")
        let composer = Composer()
        await composer.compose(intent: request)
        guard let surface = composer.surface, surface.hasLogic else { continue }
        print(surface.logicSummary)
        let evaluation = surface.evaluate(surface.initialValues)
        print("At the starting values:")
        for output in surface.outputs {
            print("  \(output.label): \(surface.display(output.name, evaluation.values[output.name]))")
        }
        var check = surface
        problemCount += Checker.checkLogic(&check).filter { $0.kind == .needsModel }.count
    }
    print("\nUnresolved calculation problems across all requests: \(problemCount)")
}

// "-name value" pairs are settings (UserDefaults reads them); everything else is a request.
var arguments: [String] = []
var remaining = Array(CommandLine.arguments.dropFirst())[...]
while let argument = remaining.popFirst() {
    if argument.hasPrefix("-") { _ = remaining.popFirst() } else { arguments.append(argument) }
}
// The bench has no one to ask, so questions are printed and left to the model. "-memory
// 'Home city=Pune; Diet=Vegetarian'" stands in for what the app remembers about the user.
var remembered: [Remembered] = []
if let memory = UserDefaults.standard.string(forKey: "memory") {
    remembered = memory.split(separator: ";").compactMap { pair in
        let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.count == 2 ? Remembered(topic: parts[0], detail: parts[1]) : nil
    }
    Recall.source = .fixed(remembered)
}
// "-signIn https://mcp.linear.app/mcp" tries a sign-in as far as it can go without a browser:
// discovery, registering Dream with the server's sign-in service as a real sign-in would, and
// the page it would open. Nothing is saved on this Mac.
if let address = UserDefaults.standard.string(forKey: "signIn") {
    await BenchConnections.trySignIn(address)
    exit(0)
}
// "-mcp https://mcp.deepwiki.com/mcp" connects servers for the run (several, separated by
// spaces), offered the way the app offers them. "-mcpReads all", or a list of tool names,
// stands in for the user saying tools whose servers don't mark them only read. "-pickOnly 1"
// shows which tools each request would be offered, without running the model.
if let servers = UserDefaults.standard.string(forKey: "mcp") {
    await BenchConnections.connect(servers.split(separator: " ").map(String.init), reads: UserDefaults.standard.string(forKey: "mcpReads") ?? "", remembered: remembered)
}
if UserDefaults.standard.bool(forKey: "pickOnly") {
    BenchConnections.showPicks(arguments)
    exit(0)
}
await run(arguments.isEmpty ? defaultRequests : arguments)
