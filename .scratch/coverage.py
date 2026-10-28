import glob, json, re, sys

root = sys.argv[1]
messages = set()
for path in glob.glob(root + "/Server/test/golden/expected/*.json"):
    d = json.load(open(path))
    for k in ["logic", "citations", "blocks"]:
        if k in d:
            for i in d[k]["issues"]:
                messages.add(i["message"])
    for i in d.get("sourcing", []):
        messages.add(i["message"])

templates = []
for path in sorted(glob.glob(root + "/Dream/Engine/Checker*.swift")) + [root + "/Dream/Engine/Live+Connections.swift"]:
    text = open(path).read()
    for match in re.finditer(r'(?:fixed|problem|warning)\((".*?")\)|message: (".*?")\)', text):
        literal = match.group(1) or match.group(2)
        templates.append((path.split("/")[-1], literal))

def pattern(literal):
    body = literal[1:-1]
    # Interpolations, possibly nested, become wildcards.
    out = ""
    i = 0
    while i < len(body):
        if body.startswith("\\(", i):
            depth = 0
            j = i + 1
            while j < len(body):
                if body[j] == "(":
                    depth += 1
                elif body[j] == ")":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            out += ".*"
            i = j + 1
        else:
            out += re.escape(body[i].replace("\\", "") if body[i] == "\\" else body[i])
            i += 1
    return "^" + out.replace('\\\\"', '"') + "$"

missing = []
for file, literal in templates:
    try:
        regex = re.compile(pattern(literal), re.S)
    except re.error:
        missing.append((file, literal + "  (pattern error)"))
        continue
    if not any(regex.search(m) for m in messages):
        missing.append((file, literal))
print(f"{len(templates) - len(missing)} of {len(templates)} message templates seen")
for file, literal in missing:
    print(" ", file, literal[:150])
