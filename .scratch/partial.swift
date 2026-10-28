import Foundation
import FoundationModels

let texts = [
    "", " ", "{", "{\"", "{\"ti", "{\"title\"", "{\"title\":", "{\"title\": ", "{\"title\": \"", "{\"title\": \"Hel",
    "{\"title\": \"He\\", "{\"title\": \"He\\n", "{\"title\": \"He\\u00", "{\"title\": \"He\\u00e9", "{\"title\": \"x\",", "{\"title\": \"x\", ",
    "{\"a\": 1", "{\"a\": 1.", "{\"a\": 1.5", "{\"a\": -", "{\"a\": 1e", "{\"a\": 1e5", "{\"a\": 1e-", "{\"a\": t", "{\"a\": true", "{\"a\": nul", "{\"a\": null",
    "{\"a\": [", "{\"a\": [1,", "{\"a\": [\"x", "{\"a\": [{", "{\"a\": [{\"b\": 1}", "{\"a\": [{\"b\": 1},", "{\"a\": {\"b\"", "{\"a\": {\"b\": [",
    "{\"a\": 1}", "{\"a\": 1} trailing", "{\"a\": 1}}", "[1, 2", "\"str", "12", "{\"a\": 01}", "{\"a\": \"x\"\n", "{\"a\": \"x\" \"b\": 2}",
    "{'a': 1}", "{\"a\": 1, }", "{\"a\": [1, ]}", "{\"a\": \"tab\there\"}", "{\"a\": \"\\q\"}", "{\"a\": 1.0}", "{\"a\": 12345678901234567890}",
    "{\"a\": \"x\", \"a\": \"y\"}", "  {\"a\": 1}", "```json\n{\"a\": 1}", "{\"a\": \"\\ud83d", "{\"a\": \"\\ud83d\\ude00\"}", "{\"a\": [1, 2]",
    "{\"a\": {}", "{\"a\": []", "{\"a\": [[1, 2", "{\"a\": [\"x\", \"y", "{\"a\": tru", "{\"a\": f", "{\"a\": false",
]
for text in texts {
    do {
        let c = try GeneratedContent(json: text)
        print(text.debugDescription, "->", c.jsonString)
    } catch {
        print(text.debugDescription, "-> FAIL")
    }
}
