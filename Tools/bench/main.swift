import Foundation

// Runs the composer on this Mac's on-device model and prints what came out, so prompt and
// checker changes can be judged without the app. Build and run with Tools/bench.sh.
// Settings go as "-name value": "-strategy onePass", "-provider xai" (with XAI_API_KEY set).

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
await run(arguments.isEmpty ? defaultRequests : arguments)
