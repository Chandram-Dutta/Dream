import Foundation
import FoundationModels

for d in [0.1, 1e-5, 0.0001, 1e15, 1e16, 1.5e20, 123456789012345.6, 2.5, -0.0, 1.0/3.0, 9007199254740992.0, 18014398509481984.0, 36028797018963968.0, 1e300, 5e-324, 100.0, 1e-4, 0.00012, 1234567.25, 1e21, 1e22, 4.35e17] {
    print(d.description, String(d))
}
print(Locale.current.identifier, Locale.current.currency?.identifier ?? "-", Locale.current.currencySymbol ?? "-", Locale.current.measurementSystem)
for text in ["{\"a\": \"hel", "{\"a\": 12", "{\"a\": [1, 2", "{\"a\": \"x\", \"b\": tr", "{\"a\": \"x\", \"b\""] {
    do {
        let c = try GeneratedContent(json: text)
        print("parsed", text, "->", c.jsonString)
    } catch {
        print("failed", text, error)
    }
}
