"""A stand-in for Dream's page loop on the server, for trying the app's side on this Mac: the three
routes of Server/src/compose/contract.ts, playing scripted events instead of calling a model.

  POST /api/compose                   starts a job; the request picks the script (below)  → { id }
  GET  /api/compose/:id/events?after  server-sent events after `after`, then new ones as they happen
  POST /api/compose/:id/answers       the user's answers, which a job asking questions waits on
  GET  /mock/jobs/:id                 what the job was sent: the request (its photo's size, not the
                                      photo), the answers, and how often its events were read

Scripts, by a word in the request: "ask" waits on a question; "fail" fails; "drop" drops the first
reading of its events after three; "slow" spaces its events out. Anything else makes a bill split.
Every request needs a session (Authorization: Bearer …), as the real routes do. An unknown job is 404.

Usage: python3 Tools/compose-mock.py 8790      (Tools/compose-check.sh starts it on its own)
"""
import base64, json, sys, threading, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs


def block(id, kind, ref="", text="", title=""):
    return {"id": id, "kind": kind, "title": title, "text": text, "ref": ref, "over": "", "items": [], "children": []}


def page(blocks):
    """A bill split, as the app's Surface encodes it, with the first `blocks` blocks."""
    return {
        "title": "Dinner split",
        "summary": "₹2,400 between 3 friends.",
        "symbol": "fork.knife",
        "accent": "green",
        "mode": "use",
        "inputs": [
            {"name": "bill", "label": "Bill", "format": "currency", "initial": 2400, "min": 0, "max": 20000, "step": 50, "options": []},
            {"name": "people", "label": "People", "format": "integer", "initial": 3, "min": 1, "max": 20, "step": 1, "options": []},
        ],
        "outputs": [{"name": "share", "label": "Each pays", "formula": "bill / people", "format": "currency"}],
        "blocks": [
            block("hero", "hero", ref="share"),
            block("controls", "section", title="Your bill"),
            block("how", "paragraph", text="Each pays the bill divided by the number of people: {share}."),
        ][:blocks],
        "related": ["How much to tip in India"],
    }


QUESTION = {"text": "Is the tip in the bill?", "topic": "Tip", "options": ["Yes", "No"], "allowsTyping": False, "isPersonal": False}


def script(request):
    """The events a job plays, in order, each with how long to wait before it."""
    words = request.lower()
    gap = 0.4 if "slow" in words else 0.05
    steps = [
        (gap, {"type": "phase", "phase": "researching"}),
        (gap, {"type": "trace", "kind": "lookup", "text": "Tipping"}),
        (gap, {"type": "log", "line": "Lookup: Tipping"}),
        (gap, {"type": "trace", "kind": "search", "text": "tipping at restaurants in India"}),
        (gap, {"type": "trace", "kind": "read", "text": "livemint.com"}),
    ]
    if "fail" in words:
        return steps + [(gap, {"type": "failed", "message": "The model's safety filters blocked this request."})]
    if "ask" in words:
        steps += [(gap, {"type": "asking", "questions": [QUESTION]}), ("answers", None)]
    steps += [
        (gap, {"type": "phase", "phase": "composing"}),
        (gap, {"type": "surface", "surface": {"title": "Dinner sp"}}),
        (gap, {"type": "surface", "surface": page(1)}),
        (gap, {"type": "surface", "surface": page(2)}),
        (gap, {"type": "phase", "phase": "fixing"}),
        (gap, {"type": "log", "line": "Fixed: placed every input"}),
        (gap, {"type": "surface", "surface": page(3)}),
        (gap, {"type": "done", "surface": page(3), "model": "mock-model"}),
    ]
    return steps


class Job:
    def __init__(self, body):
        self.id = uuid.uuid4().hex
        self.body = body
        self.events = []
        self.answers = []
        self.readings = []
        self.over = False
        self.changed = threading.Condition()
        self.drops = 1 if "drop" in body.get("request", "").lower() else 0
        threading.Thread(target=self.play, daemon=True).start()

    def add(self, event):
        with self.changed:
            event = {"seq": len(self.events) + 1, **event}
            if event["type"] == "done":
                event["pageID"] = self.body["pageID"]
            self.events.append(event)
            self.over = event["type"] in ("done", "failed")
            self.changed.notify_all()

    def play(self):
        for wait, event in script(self.body.get("request", "")):
            if wait == "answers":
                # Nobody answering for a while means "You choose", as on the server.
                with self.changed:
                    self.changed.wait_for(lambda: self.answers, timeout=20)
                continue
            time.sleep(wait)
            self.add(event)


JOBS = {}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        sys.stderr.write("mock: " + format % args + "\n")

    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def signed_in(self):
        if (self.headers.get("Authorization") or "").startswith("Bearer "):
            return True
        self.reply(401, {"error": "Sign in to make pages."})
        return False

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(length) or b"{}")

    def parts(self):
        return [part for part in urlparse(self.path).path.split("/") if part]

    def do_POST(self):
        parts = self.parts()
        if not self.signed_in():
            return
        if parts == ["api", "compose"]:
            body = self.body()
            missing = [key for key in ("request", "locale", "pageID") if key not in body]
            if missing:
                return self.reply(400, {"error": "Missing " + ", ".join(missing)})
            job = Job(body)
            JOBS[job.id] = job
            return self.reply(200, {"id": job.id})
        if len(parts) == 4 and parts[:2] == ["api", "compose"] and parts[3] == "answers":
            job = JOBS.get(parts[2])
            if not job:
                return self.reply(404, {"error": "No such page."})
            answers = self.body().get("answers", [])
            with job.changed:
                job.answers.append(answers)
                job.changed.notify_all()
            return self.reply(200, {"ok": True})
        self.reply(404, {"error": "Not found."})

    def do_GET(self):
        parts = self.parts()
        if parts[:2] == ["mock", "jobs"] and len(parts) == 3:
            job = JOBS.get(parts[2])
            if not job:
                return self.reply(404, {"error": "No such job."})
            sent = dict(job.body)
            if sent.get("image"):
                sent["image"] = f"{len(base64.b64decode(sent['image']))} bytes of JPEG"
            return self.reply(200, {"request": sent, "answers": job.answers, "readings": job.readings, "events": len(job.events)})
        if len(parts) == 4 and parts[:2] == ["api", "compose"] and parts[3] == "events":
            if not self.signed_in():
                return
            job = JOBS.get(parts[2])
            if not job:
                return self.reply(404, {"error": "No such page."})
            after = int(parse_qs(urlparse(self.path).query).get("after", ["0"])[0])
            job.readings.append(after)
            return self.stream(job, after)
        self.reply(404, {"error": "Not found."})

    def stream(self, job, after):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        sent = 0
        drop = job.drops > 0
        job.drops = max(0, job.drops - 1)
        try:
            while True:
                with job.changed:
                    job.changed.wait_for(lambda: job.over or len(job.events) > after, timeout=2)
                    pending = job.events[after:]
                    over = job.over
                if not pending:
                    if over:
                        return
                    self.wfile.write(b": heartbeat\n\n")
                    self.wfile.flush()
                    continue
                for event in pending:
                    self.wfile.write(f"data: {json.dumps(event)}\n\n".encode())
                    self.wfile.flush()
                    after = event["seq"]
                    sent += 1
                    if drop and sent == 3:
                        # The line drops, mid-page.
                        return
                if over and after >= len(job.events):
                    return
        except (BrokenPipeError, ConnectionResetError):
            return


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8790
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"compose mock on http://127.0.0.1:{port}", flush=True)
    server.serve_forever()
