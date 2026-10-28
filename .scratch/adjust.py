import json, sys

root = sys.argv[1] + "/Server/test/golden/cases/"

def edit(name, change):
    path = root + name
    data = json.load(open(path))
    change(data)
    with open(path, "w") as out:
        json.dump(data, out, ensure_ascii=False, indent=2)
        out.write("\n")

def lists(d):
    cols = d["wire"]["collections"]
    by_label = {c["label"]: c for c in cols}
    order = ["", " Expenses ", "Budget list", "Groceries", "Second groceries", "Fifth list"]
    d["wire"]["collections"] = [by_label[label] for label in order]
    # A second list of one name, and the budget list renamed, within the four kept.
    d["wire"]["collections"] = [by_label[""], by_label[" Expenses "], by_label["Groceries"], by_label["Second groceries"], by_label["Budget list"], by_label["Fifth list"]]

edit("lists-collections.json", lists)
