#!/usr/bin/env python3
"""Auto's bench (Server/src/router.ts, Server/README.md "Routing"): every candidate model makes the
same pages through Dream's real pipeline and a local server, Grok 4.7 scores them against the same
rubric and ground truth, and the matrix says which model is good enough for what. It spends real
money: the whole matrix cost about $6 on 2026-10-27.

With `npx wrangler dev --port 8792 --ip 127.0.0.1` running in Server/ (DEV_LOGIN=1 and the real
keys in .dev.vars, as README.md says):

  Tools/router-bench/bench.py build                  the Mac bench, as Tools/bench-many.sh builds it
  Tools/router-bench/bench.py accounts CONFIG…       a dev account per page, plus the judge's and the
                                                     probe's; add the ids it prints to PLUS_ACCOUNTS
                                                     in .dev.vars and restart, so they may think at
                                                     any level
  Tools/router-bench/bench.py run [-p N] CONFIG[:REQUEST]…
                                                     make the pages, one config at a time, N at once
                                                     (default all; 4 for Sarvam's and Workers AI's
                                                     models, which limit requests a minute; a page
                                                     turned away with 3021 is the limit, so run it
                                                     again on its own)
  Tools/router-bench/bench.py judge [REQUEST…]       score the pages made (Grok 4.7 thinking low, ~$0.40)
  Tools/router-bench/bench.py matrix                 made, mean score, median time and mean cost,
                                                     by config and category
  Tools/router-bench/bench.py probe                  what Clef and the table pick for each request

Never edit Server/src while pages are being made: `wrangler dev` reloads on any change there and
cuts the streams in flight. Each page has its own account, so its cost is that account's usage (a
rerun on the same account counts from where it was). Results go in $ROUTER_BENCH (default
/private/tmp/dream-router-bench). Keys come from the login Keychain (service dream) and are never
printed.
"""
import base64, concurrent.futures as cf, glob, json, os, random, re, sqlite3, statistics, subprocess, sys, time, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
D1 = ROOT / "Server/.wrangler/state/v3/d1/miniflare-D1DatabaseObject"
HOME = Path(os.environ.get("ROUTER_BENCH", "/private/tmp/dream-router-bench"))
BASE = os.environ.get("DREAM_SERVER", "http://127.0.0.1:8792")
BIN = HOME / "dream-bench"
PHOTOS = Path(__file__).resolve().parent / "photos"
# Monstera deliciosa, from Wikimedia Commons (File:Monstera_deliciosa3.jpg), fetched rather than kept here.
PLANT = "https://upload.wikimedia.org/wikipedia/commons/thumb/0/04/Monstera_deliciosa3.jpg/960px-Monstera_deliciosa3.jpg"

# Two or three requests in each of Dream's kinds of page: (category, request, photo).
REQUESTS = {
    "m1": ("money", "EMI calculator for a ₹40 lakh home loan at 8.6% for 20 years, and how much interest I'll pay in total", None),
    "m2": ("money", "split a $184 dinner bill between 5 friends with an 18% tip, where one of them only had a $12 drink", None),
    "s1": ("science", "derive the quadratic formula step by step", None),
    "s2": ("science", "explain time dilation in special relativity with the Lorentz factor", None),
    "l1": ("lists", "packing list for a 5-day winter trek in Ladakh", None),
    "l2": ("lists", "a weekly habit tracker for drinking water, reading and exercise", None),
    "w1": ("live", "what's the US dollar to rupee rate right now? convert $750", None),
    "w2": ("live", "who won the most recent Formula 1 Grand Prix, and what are the championship standings now?", None),
    "p1": ("photo", "split this bill between the 4 of us; I didn't have a lassi or a coffee", "receipt.jpg"),
    "p2": ("photo", "solve these and show the steps", "worksheet.jpg"),
    "p3": ("photo", "what plant is this and how do I look after it?", "plant.jpg"),
    "h1": ("language", "मेरे ₹50,000 पर 5 साल में 12% सालाना चक्रवृद्धि ब्याज से कितना बनेगा?", None),
    "h2": ("language", "प्रकाश संश्लेषण कैसे काम करता है? बच्चों के लिए समझाइए", None),
    "t1": ("language", "சென்னையிலிருந்து ஊட்டிக்கு 3 நாள் பயணத் திட்டம்", None),
    "f1": ("figures", "simulate a pendulum where I can change the length and gravity", None),
    "f2": ("figures", "show me a water molecule in 3D and explain its bond angle", None),
}

# What a right page has, for the judge.
TRUTH = {
    "m1": "EMI on ₹40,00,000 at 8.6% a year for 240 months is ₹34,966.51; total paid ₹83,91,962; total interest ₹43,91,962.",
    "m2": "Fair split: the drink-only friend pays $12 × 1.18 = $14.16; each of the other four pays ($184 − $12) × 1.18 / 4 = $50.74; total $217.12. (An even split, ignoring the drink, is wrong.)",
    "s1": "x = (−b ± √(b² − 4ac)) / 2a, derived by completing the square on ax² + bx + c = 0.",
    "s2": "γ = 1/√(1 − v²/c²); moving clocks run slow: Δt = γ Δt₀. γ ≥ 1, e.g. γ ≈ 1.155 at 0.5c, ≈ 7.09 at 0.99c.",
    "l1": "Ladakh in winter: −10 to −25 °C, high altitude (3,500 m+): layering, down jacket, thermal base layers, insulated boots, acclimatisation, altitude sickness, permits, sunscreen and glasses.",
    "l2": "A weekly tracker for water, reading and exercise: days of the week, a way to tick each habit, ideally totals or streaks.",
    "w1": "The rate must come from a live/exchange-rate tool call in the log; the conversion is $750 × that rate. A rate stated with no tool call is made up.",
    "w2": "The winner and standings can only be known from a web search or read in the log; any results stated without one are invented and score 0 for correctness.",
    "p1": "The photo is a Bengaluru restaurant bill: Masala Dosa 2×160=320, Paneer Butter Masala 340, Butter Naan 4×60=240, Veg Biryani 290, Sweet Lassi 3×90=270, Filter Coffee 2×70=140, Gulab Jamun 2×110=220; subtotal 1,820; CGST 2.5% 45.50, SGST 2.5% 45.50, service charge 10% 182; total ₹2,093. The asker had no lassi or coffee: the shared food (₹1,410) is split 4 ways and the drinks (₹410) among the other 3, taxes and service in proportion: asker ≈ ₹405.37, each other ≈ ₹562.54, total ₹2,093.",
    "p2": "The photo is a worksheet: Q1 2x² − 7x + 3 = 0 → x = 3 or x = 1/2. Q2 ladder 13 m, foot 5 m from the wall → height 12 m. Q3 sum of the first 20 terms of the AP 3, 7, 11, … → S₂₀ = 820.",
    "p3": "The photo shows Monstera deliciosa (Swiss cheese plant): bright indirect light, water when the top few cm of soil are dry, humidity, support pole, toxic to pets.",
    "h1": "Asked in Hindi; the page should be in Hindi. ₹50,000 at 12% compounded yearly for 5 years → ₹88,117.08, interest ₹38,117.08.",
    "h2": "Asked in Hindi for children; the page should be in simple Hindi. Photosynthesis: 6CO₂ + 6H₂O + light → C₆H₁₂O₆ + 6O₂, chlorophyll, leaves.",
    "t1": "Asked in Tamil; the page should be in Tamil. A 3-day itinerary from Chennai to Ooty (about 560 km, 9–10 h by road, or train to Mettupalayam then the Nilgiri Mountain Railway): Botanical Garden, Ooty Lake, Doddabetta Peak, Pykara, Coonoor.",
    "f1": "Period T = 2π√(L/g) for small swings; an interactive pendulum with length and gravity controls.",
    "f2": "Water is bent, H–O–H bond angle ≈ 104.5°, two lone pairs on oxygen (VSEPR, tetrahedral electron geometry). A 3D model should show it.",
}

# The candidates: (catalogue id, thinking level). A model that doesn't think ignores the level.
CONFIGS = {
    "g47l": ("grok-4.7", "low"),
    "g47h": ("grok-4.7", "high"),
    "g420": ("grok-4.20-fast", "low"),
    "dsl": ("deepseek-v4.1-flash", "low"),
    "dsn": ("deepseek-v4.1-flash", "none"),
    "sds": ("sarvam-deepseek-v4.1-flash", "low"),
    "glmf": ("glm-5.3-flash", "low"),
    "sglm": ("sarvam-glm-5.3", "low"),
    "s105": ("sarvam-105b", "low"),
    "gemma": ("sarvam-gemma-4", "low"),
}

RUBRIC = """You are grading pages made by an app called Dream. For each request a model builds one interactive page: blocks of text, facts, lists, equations, inputs (sliders, fields) and outputs computed from formulas. You'll see several pages for the same request, each made by a different model, labelled A, B, C…, with a log of what it did (tool calls: lookup = Wikipedia, live = live data like exchange rates and weather, search/read = web search and reading pages; "Fixed:"/"Problem:" lines are an automatic checker's notes).

Score each page from 0 to 10 as the sum of:
- correct (0–4): facts, formulas, and the numbers at the starting values are right. Use the ground truth. For live facts: anything not backed by a live/search/read tool call in that page's log is invented and gets 0 here. For a photo: the page must reflect what the photo actually shows.
- fit (0–2): does exactly what was asked, honouring every constraint, written in the language the request was written in.
- useful (0–2): complete; interactive where that helps (inputs that change results).
- clear (0–2): well organised, explains, uses equations for maths.
A page that wasn't made scores 0. Be strict and consistent across pages; compare them with each other.

Answer only with JSON: {"A": {"correct": n, "fit": n, "useful": n, "clear": n, "score": n, "note": "under 20 words"}, "B": …}"""


def account(cfg, req):
    return f"rb-{cfg}-{req}"


def load(name, default):
    path = HOME / name
    return json.loads(path.read_text()) if path.exists() else default


def save(name, value, private=False):
    old = os.umask(0o077) if private else None
    (HOME / name).write_text(json.dumps(value, indent=1))
    if old is not None:
        os.umask(old)


def keychain(name):
    return subprocess.run(["security", "find-generic-password", "-a", name, "-s", "dream", "-w"], capture_output=True, text=True).stdout.strip()


def session(name):
    with urllib.request.urlopen(urllib.request.Request(f"{BASE}/api/dev/session?user={name}", method="POST"), timeout=30) as response:
        return json.load(response)


def database():
    """The local D1, for reading usage while `wrangler dev` runs."""
    file = [p for p in glob.glob(str(D1 / "*.sqlite")) if not p.endswith("metadata.sqlite")][0]
    try:
        db = sqlite3.connect(f"file:{file}?mode=ro", uri=True)
        db.execute("SELECT 1 FROM usage LIMIT 1")
        return db
    except sqlite3.OperationalError:
        # Read-only can't open a WAL database the server hasn't opened yet (it has no -shm file to
        # read); a plain connection makes one, and only reads.
        return sqlite3.connect(file)


def spent(db, user):
    """This month's recorded cost of an account, in millionths of a dollar."""
    row = db.execute("SELECT cost_micros FROM usage WHERE user_id = ? AND length(period) = 7", (user,)).fetchone()
    return row[0] if row else 0


def post(path, body, token, key):
    request = urllib.request.Request(f"{BASE}{path}", data=json.dumps(body).encode(), method="POST",
                                     headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}", "X-Dream-Key": key})
    with urllib.request.urlopen(request, timeout=300) as response:
        return json.load(response)


def photo(name):
    if name != "plant.jpg":
        return PHOTOS / name
    path = HOME / "photos" / name
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["curl", "-sfL", "-A", "DreamBench/1.0", "-o", str(path), PLANT], check=True)
    return path


# MARK: - Making pages

def build():
    """The Mac bench, built by Tools/bench-many.sh with no requests, into $ROUTER_BENCH."""
    HOME.mkdir(parents=True, exist_ok=True)
    env = {**os.environ, "TMPDIR": str(HOME)}
    env.pop("DREAM_SERVER", None)
    subprocess.run([str(ROOT / "Tools/bench-many.sh"), str(HOME / "build")], env=env, check=True)
    print(BIN)


def accounts(cfgs):
    HOME.mkdir(parents=True, exist_ok=True)
    found = load("sessions.json", {})
    names = [account(cfg, req) for cfg in cfgs for req in REQUESTS] + ["rb-judge", "rb-route"]
    for name in names:
        made = session(name)
        found[name] = {"user": made["user"], "token": made["token"]}
    save("sessions.json", found, private=True)
    print(",".join(found[name]["user"] for name in names))


def make(cfg, req, token, key, before):
    model, effort = CONFIGS[cfg]
    _, text, picture = REQUESTS[req]
    args = [str(BIN), "-provider", "dream", "-shareServer", BASE, "-xaiModel", model, "-thinking", effort]
    if picture:
        args += ["-image", str(photo(picture))]
    # XAI_API_KEY=off: a page that fails isn't quietly finished by Grok with the developer's own key.
    env = {**os.environ, "DREAM_SESSION": token, "DREAM_WEB_KEY": key, "XAI_API_KEY": "off", "TMPDIR": str(HOME)}
    (HOME / "out" / cfg).mkdir(parents=True, exist_ok=True)
    started = time.time()
    try:
        done = subprocess.run(args + [text], env=env, capture_output=True, text=True, timeout=900)
        body, code = done.stdout + done.stderr, done.returncode
    except subprocess.TimeoutExpired as error:
        body, code = error.stdout.decode() if isinstance(error.stdout, bytes) else (error.stdout or ""), "timeout"
    seconds = time.time() - started
    (HOME / "out" / cfg / f"{req}.txt").write_text(f"{body}\n#WALL {seconds:.1f}s exit={code} before={before}\n")
    return cfg, req, seconds


def run(names, parallel):
    found, key, db = load("sessions.json", {}), keychain("web"), database()
    for group in names:
        jobs = [tuple(group.split(":"))] if ":" in group else [(group, req) for req in REQUESTS]
        print(f"== {group}", flush=True)
        with cf.ThreadPoolExecutor(max_workers=parallel or len(jobs)) as pool:
            futures = []
            for cfg, req in jobs:
                user = found[account(cfg, req)]
                futures.append(pool.submit(make, cfg, req, user["token"], key, spent(db, user["user"])))
                # Every page comes from this Mac, and web search is limited per address: spread them out.
                time.sleep(4)
            for future in cf.as_completed(futures):
                cfg, req, seconds = future.result()
                print(f"{cfg} {req} {seconds:.0f}s", flush=True)


# MARK: - Scoring

def metrics():
    found, db, out = load("sessions.json", {}), database(), {}
    for cfg in CONFIGS:
        for req in REQUESTS:
            path = HOME / "out" / cfg / f"{req}.txt"
            if not path.exists():
                continue
            text = path.read_text()
            done = re.search(r"\[Dream\] Done in ([\d.]+)s", text)
            failed = re.search(r"\[Dream\] Failed: (.*)", text)
            before = int((re.search(r"before=(\d+)", text) or [0, 0])[1])
            out[f"{cfg}/{req}"] = {
                "made": bool(done) and not failed,
                "seconds": float(done.group(1)) if done else None,
                "failure": failed.group(1)[:160] if failed else (None if done else "no page"),
                "problems": len(re.findall(r"^\[Dream\] Problem:", text, re.M)),
                "cost": (spent(db, found[account(cfg, req)]["user"]) - before) / 1e6,
            }
    save("metrics.json", out)
    return out


def excerpt(path, limit=5000):
    lines = [line for line in path.read_text().splitlines() if not re.match(r"^\[Dream/\w+\] (request:|first text after|done after)", line) and not line.startswith("#WALL") and "Unresolved calculation problems" not in line]
    body = "\n".join(lines)
    return body if len(body) <= limit else body[:limit] + "\n…(cut)"


def judge(reqs):
    found, key, made = load("sessions.json", {}), keychain("web"), metrics()
    scores = load("scores.json", {})
    for req in reqs or list(REQUESTS):
        # Only pages that were made, anonymised and shuffled; the rest score 0 without asking.
        cfgs = [cfg for cfg in CONFIGS if made.get(f"{cfg}/{req}", {}).get("made")]
        random.Random(f"dream-{req}").shuffle(cfgs)
        labels = {chr(65 + i): cfg for i, cfg in enumerate(cfgs)}
        pages = "\n\n".join(f"=== Page {label} ===\n{excerpt(HOME / 'out' / cfg / f'{req}.txt')}" for label, cfg in labels.items())
        body = {"model": "grok-4.7", "reasoning_effort": "low", "temperature": 0, "response_format": {"type": "json_object"},
                "messages": [{"role": "system", "content": RUBRIC}, {"role": "user", "content": f"Request: {REQUESTS[req][1]}\nGround truth: {TRUTH[req]}\n\n{pages}"}]}
        content = post("/api/model", body, found["rb-judge"]["token"], key)["choices"][0]["message"]["content"]
        graded = json.loads(content[content.index("{"): content.rindex("}") + 1])
        for grade in graded.values():
            # Now and then the judge gives the parts without their sum.
            if isinstance(grade, dict) and not isinstance(grade.get("score"), (int, float)):
                grade["score"] = sum(grade.get(part, 0) for part in ("correct", "fit", "useful", "clear"))
        scores[req] = {labels[label]: grade for label, grade in graded.items() if label in labels}
        save("scores.json", scores)
        print(req, {cfg: grade.get("score") for cfg, grade in scores[req].items()}, flush=True)


def matrix():
    made, scores = metrics(), load("scores.json", {})
    categories = list(dict.fromkeys(category for category, _, _ in REQUESTS.values()))

    def cell(cfg, reqs):
        runs = [(req, made[f"{cfg}/{req}"]) for req in reqs if f"{cfg}/{req}" in made]
        if not runs:
            return "—"
        quality = statistics.mean(scores.get(req, {}).get(cfg, {}).get("score", 0) if run["made"] else 0 for req, run in runs)
        times = [run["seconds"] for _, run in runs if run["made"] and run["seconds"]]
        cost = statistics.mean(run["cost"] for _, run in runs)
        return f"{sum(run['made'] for _, run in runs)}/{len(runs)} · {quality:.1f} · {statistics.median(times):.0f}s · {cost * 100:.1f}¢" if times else f"0/{len(runs)}"

    print("| config | " + " | ".join(categories) + " | all |\n|---|" + "---|" * (len(categories) + 1))
    for cfg, (model, effort) in CONFIGS.items():
        row = [cell(cfg, [req for req, (category, _, _) in REQUESTS.items() if category == want]) for want in categories]
        print(f"| {model} {effort} | " + " | ".join(row + [cell(cfg, list(REQUESTS))]) + " |")


def probe():
    """What /api/route answers for each request (with DEV_LOGIN it carries Clef's signals), and how fast."""
    found, key = load("sessions.json", {}), keychain("web")
    for req, (category, text, picture) in REQUESTS.items():
        body = {"request": text}
        if picture:
            # As the app sends it: at most 768 pixels on the longer side.
            small = HOME / f"small-{picture}"
            subprocess.run(["sips", "-Z", "768", str(photo(picture)), "--out", str(small)], capture_output=True)
            body.update(hasImage=True, image="data:image/jpeg;base64," + base64.b64encode(small.read_bytes()).decode())
        started = time.time()
        answer = post("/api/route", body, found["rb-route"]["token"], key)
        signals = answer.get("signals") or {}
        print(f"{req:3} {category:8} → {answer['category']:8} {answer['difficulty']:4} {answer['model']} · {answer['effort']:5} "
              f"(topic {signals.get('topic')}, fresh {signals.get('fresh', 0):.2f}, foreign {signals.get('foreign', 0):.2f}, "
              f"difficulty {signals.get('difficulty', 0):.2f}) {time.time() - started:.2f}s")


if __name__ == "__main__":
    command, rest = (sys.argv[1] if len(sys.argv) > 1 else "help"), sys.argv[2:]
    parallel = int(rest[1]) if rest[:1] == ["-p"] else None
    rest = rest[2:] if parallel else rest
    actions = {"build": build, "accounts": lambda: accounts(rest), "run": lambda: run(rest, parallel), "judge": lambda: judge(rest), "matrix": matrix, "probe": probe}
    if command not in actions:
        sys.exit(__doc__)
    actions[command]()
