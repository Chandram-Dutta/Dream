// The privacy policy, terms of use and support page, linked from the app's first run and
// Account, and from App Store Connect. They read like the web viewer (page.ts). All three are
// drafts that need a lawyer's review before launch, and say so at the top; anything in
// [brackets] is still to be decided.
//
//   GET /privacy   GET /terms   GET /support

import { document } from "./page";

export type LegalPath = "/privacy" | "/terms" | "/support";

/** When the drafts last changed. */
const UPDATED = "26 October 2026";

/** Something still to be filled in or decided, marked so it can't be missed. */
const todo = (what: string) => `<mark>[${what}]</mark>`;

const PRIVACY_CONTACT = todo("privacy contact address");
const SUPPORT_CONTACT = todo("support contact address");
const COMPANY = todo("legal name and address of the company behind Dream");

const STYLE = `<style>
.draft{display:inline-flex;align-items:center;gap:8px;margin:0 0 16px;padding:7px 14px;border-radius:999px;font-size:13px;font-weight:600;
background:color-mix(in srgb,#FF8D28 16%,transparent);color:#B85400;border:.5px solid color-mix(in srgb,#FF8D28 45%,transparent)}
.draft::before{content:"";width:8px;height:8px;border-radius:50%;background:#FF8D28}
@media (prefers-color-scheme:dark){.draft{color:#FFB46B}}
.updated{margin:12px 0 0;font-size:13px;color:var(--secondary)}
.legal{display:flex;flex-direction:column;gap:12px}
.legal h2{font-family:var(--display);font-stretch:125%;font-size:22px;line-height:1.25;font-weight:600;margin:8px 0 0}
.legal h3{font-size:17px;font-weight:600;margin:0}
.legal ul{list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:10px}
.legal li{position:relative;padding-inline-start:19px}
.legal li::before{content:"";position:absolute;inset-inline-start:0;top:.62em;width:7px;height:7px;border-radius:50%;background:var(--gradient)}
.kept{display:flex;flex-direction:column;gap:10px}
.kept .item{padding:16px 18px;background:var(--wash);border:.5px solid var(--edge);border-radius:22px;display:flex;flex-direction:column;gap:6px}
.kept .meta{font-size:13px;color:var(--secondary)}
.kept .meta strong{color:var(--label);font-weight:600}
mark{background:color-mix(in srgb,#FFCC00 30%,transparent);color:inherit;border-radius:4px;padding:0 3px}
.pages{display:flex;flex-wrap:wrap;gap:8px;margin-top:8px}
.pages a{padding:10px 15px;border-radius:999px;background:var(--wash);border:.5px solid var(--edge);font-size:15px;font-weight:500}
</style>`;

interface Kept {
  what: string;
  detail: string;
  where: string;
  how: string;
}

const kept = (items: Kept[]) =>
  `<div class="kept">${items
    .map(
      (item) =>
        `<div class="item"><h3>${item.what}</h3><p>${item.detail}</p><p class="meta"><strong>Where:</strong> ${item.where} · <strong>How long:</strong> ${item.how}</p></div>`,
    )
    .join("")}</div>`;

const list = (items: string[]) => `<ul>${items.map((item) => `<li>${item}</li>`).join("")}</ul>`;

const section = (title: string, ...parts: string[]) => `<section class="legal"><h2>${title}</h2>${parts.join("")}</section>`;

const p = (text: string) => `<p>${text}</p>`;

const SERVER = "Dream's server, on Cloudflare";

const PRIVACY = [
  section(
    "The short version",
    list([
      "Your account, saved pages, lists and memory are kept on Dream's server, so they're there on every iPhone you sign in on. Dream's server can read them: they aren't end-to-end encrypted.",
      "To make a page, what you ask goes through Dream's server to an AI provider's model (today, xAI), with what's needed to answer it. You agree to this when you sign in.",
      "Once you sign in, Dream sends crash reports and usage counts, which you can turn off in Account under “Help improve Dream”. They never include what you ask, what pages say, or your lists and memory.",
      "Dream doesn't sell your data, show ads, or track you across other companies' apps and websites.",
      "You can export or delete everything from Account in the app, at any time.",
    ]),
  ),
  section(
    "Who we are",
    p(`Dream is made by ${COMPANY}, which decides how your data is used (the “controller”). Write to ${PRIVACY_CONTACT} about anything in this policy.`),
  ),
  section(
    "What Dream keeps, and for how long",
    kept([
      {
        what: "Your account",
        detail:
          "Dream's own id for you, and the id Apple gives Dream for you when you sign in with Apple. Your email only if you chose to share it, which is often a private relay address from Apple. Your name, which Apple sends once, the first time you sign in.",
        where: SERVER,
        how: "until you delete your account",
      },
      {
        what: "Signed-in devices",
        detail:
          "For each iPhone you're signed in on: a hash of its session (never the session itself), what the app calls the device, like “iPhone”, and when it was last used.",
        where: SERVER,
        how: "until you sign out, or 90 days without use",
      },
      {
        what: "Saved pages",
        detail: "Each page's template, your numbers and answers on it, and its history: what you asked for, and each change you asked for.",
        where: SERVER,
        how: "until you delete the page or your account",
      },
      { what: "Lists", detail: "The entries you add to lists, like groceries or expenses.", where: SERVER, how: "until you delete them, the page, or your account" },
      {
        what: "Memory",
        detail: "Facts Dream remembers about you, which you can see, change and delete in “What Dream knows”.",
        where: SERVER,
        how: "until you delete them or your account",
      },
      {
        what: "Connected services",
        detail:
          "Which services you've connected, like Linear or Notion, and their addresses. Their sign-in tokens stay in your iPhone's Keychain and never reach Dream's server.",
        where: SERVER,
        how: "until you remove them or delete your account",
      },
      { what: "Settings", detail: "Your choices in Dream, like units and whether to help improve Dream.", where: SERVER, how: "until you delete your account" },
      {
        what: "Photos",
        detail: "Photos you attach to a request, kept with the page they made.",
        where: "Dream's file storage, on Cloudflare R2",
        how: "until you delete the page or your account",
      },
      {
        what: "Shared pages",
        detail:
          "A page you share is stored under its link, with your numbers only if you choose “Include my numbers”. Your answers, lists, photos and memory are never part of it. Dream counts how often a link is opened, not who opened it.",
        where: SERVER,
        how: "until you stop sharing it or delete your account",
      },
      {
        what: "Usage and limits",
        detail: "How many pages, model tokens and web searches your account has used, to apply the free allowance and your subscription.",
        where: SERVER,
        how: todo("retention for usage records, for example 13 months"),
      },
      {
        what: "Subscription",
        detail: "Whether you subscribe, and Apple's signed record of each purchase and renewal. Apple handles payment; Dream never sees card details.",
        where: SERVER,
        how: todo("as long as tax and accounting law requires"),
      },
      {
        what: "Web search answers",
        detail:
          "When a page searches the web or reads a page, the answer is kept for a while so asking again costs nothing. It's stored under a hash of what was asked, shared by everyone, and not linked to you.",
        where: SERVER,
        how: "15 minutes to 6 hours",
      },
      {
        what: "Crash and hang reports, unless you turn off “Help improve Dream”",
        detail:
          "The version of Dream and iOS, the kind of iPhone, and where in Dream's code a crash, hang or slow launch happened. No account, no location, and nothing you wrote.",
        where: SERVER,
        how: "90 days",
      },
      {
        what: "Usage counts, unless you turn off “Help improve Dream”",
        detail:
          "Events like “page built”, with how long it took, how many parts it had and of which kinds, and whether it used the web; and for each request to an AI model, how much it used, what it cost and how long it took. They're linked to Dream's own id for you, so they can be counted per person, and never include what you asked, what pages say, your lists, your memory or web addresses. They're not used for advertising or to track you elsewhere.",
        where: "PostHog, in the United States",
        how: todo("retention set in PostHog, for example 12 months"),
      },
    ]),
    p(
      "Dream's server logs only the kind of an unexpected error, never addresses or what you sent. Cloudflare sees your IP address when your iPhone connects, and uses it to count requests against rate limits; Dream doesn't store it.",
    ),
  ),
  section(
    "What stays on your iPhone",
    list([
      "Where you are. Dream uses it for the weather and travel times you ask about, and sends it from your iPhone to Apple Weather and Apple Maps. It never reaches Dream's server.",
      "What you say. Speech is turned into text on your iPhone.",
      "Sign-ins to services you connect, kept in your iPhone's Keychain.",
      "Small private jobs, like picking which facts from your memory fit a request, run on Apple's on-device model.",
    ]),
  ),
  section(
    "Who else handles it",
    p("Dream uses these companies to run. Each gets only what its job needs."),
    list([
      "<strong>Cloudflare</strong> runs Dream's server, database and file storage, so it holds everything Dream keeps.",
      "<strong>AI providers</strong> run the models that make pages. Today that's <strong>xAI</strong> (Grok). Dream may add or change providers, and this list will say so before it does. For each request a provider receives what you asked, the context needed to answer it (like facts from your memory you've confirmed, your answers, the page you're changing, or list entries you're talking to), any photo you attached, and what lookups returned. It doesn't receive your name, email or Apple ID. " +
        todo("each provider's retention and training terms for API data, starting with xAI's"),
      "<strong>Parallel</strong> searches the web and reads pages. It receives the searches the model writes and the addresses of pages to read, never your account.",
      "<strong>Apple</strong> handles Sign in with Apple, App Store purchases, Weather and Maps.",
      "<strong>Wikimedia</strong> answers Wikipedia and Wikimedia Commons lookups for facts, pictures and sounds. It receives what's looked up.",
      "<strong>PostHog</strong> keeps usage counts, in the United States, unless you turn off “Help improve Dream”. It doesn't keep your IP address.",
    ]),
    p(
      "Services you connect yourself, like Linear or Notion, talk to your iPhone directly, under their own terms. Dream shows you what it will send before one of their tools runs.",
    ),
  ),
  section(
    "Why Dream uses it",
    p(todo("legal bases, for a lawyer to confirm")),
    list([
      "To provide Dream: your account, pages, lists, memory and subscription, and sending what you ask to AI providers to make your pages (performing the contract with you, which you agree to when you sign in).",
      `To improve Dream: crash reports and usage counts, which you can turn off at any time in Account (${todo("consent given at sign-in, or legitimate interests, for a lawyer to confirm")}).`,
      "To keep Dream safe and working: rate limits, preventing abuse, and fixing problems (legitimate interests).",
      "Because the law requires it: purchase records.",
    ]),
  ),
  section(
    "Your rights",
    p("Wherever you live, you can:"),
    list([
      "See what Dream keeps about you, and get a copy in a format other services can read: Account › Export my data.",
      "Correct it: change or delete facts in “What Dream knows”, and edit your pages and lists.",
      "Delete it: delete pages, lists and facts one by one, or everything at once with Account › Delete my account.",
      "Stop crash reports and usage counts: turn off “Help improve Dream” in Account. Nothing more is sent from then on.",
    ]),
    p(
      "<strong>In the EU, the UK and elsewhere under the GDPR</strong>, you also have the right to restrict or object to how your data is used, and to complain to your data protection authority. Dream answers requests within one month.",
    ),
    p(
      `<strong>In India, under the Digital Personal Data Protection Act, 2023</strong>, you can ask for a summary of your data and who it's shared with, have it corrected, completed or erased, nominate someone to act for you if you die or can't, and have grievances answered by Dream's grievance officer, ${todo("name and contact of the grievance officer")}, within ${todo("response time")}. If you're not satisfied, you can complain to the Data Protection Board of India.`,
    ),
    p(`For anything the app can't do, write to ${PRIVACY_CONTACT}. Dream may ask you to confirm the request from your account before acting on it.`),
  ),
  section(
    "Deleting your account",
    p(
      "Deleting your account in the app erases it from Dream's server at once: your account, devices, pages and their history, lists, memory, photos, settings and shared pages, whose links stop working. Dream also tells Apple to revoke its Sign in with Apple link to you. Copies in the database's backups (Cloudflare D1 Time Travel) are gone within 30 days.",
    ),
    p(
      `Crash reports aren't linked to you, so they stay until they expire after 90 days. Usage counts in PostHog are linked to Dream's id for you; ${todo("how they're deleted with the account, for example a deletion request to PostHog")}. Purchase records may be kept as long as the law requires.`,
    ),
  ),
  section(
    "Children",
    p(
      `Dream isn't meant for children under 13. ${todo("Decide the minimum age, and how to handle users under 18: the DPDP Act treats them as children, needing verifiable parental consent. For a lawyer to decide.")}`,
    ),
  ),
  section(
    "Moving data between countries",
    p(
      `Cloudflare runs Dream's server around the world; xAI, Parallel and PostHog are in the United States. When data leaves your country, ${todo("the safeguards used, such as the EU's standard contractual clauses")}.`,
    ),
  ),
  section(
    "Security",
    p(
      `Everything travels over HTTPS. Sessions are stored only as hashes, and sign-ins to connected services stay in your iPhone's Keychain. ${todo("who at the company can reach production data, and how")}.`,
    ),
  ),
  section("Changes", p("If this policy changes in a way that matters, Dream will say so in the app before the change takes effect.")),
];

const TERMS = [
  section(
    "Agreeing to these terms",
    p(
      `These terms are between you and ${COMPANY}. By signing in to Dream, or otherwise using it, you agree to them and to the ${'<a href="/privacy">privacy policy</a>'}, including what it says about AI providers and usage counts. If you don't agree, please don't use Dream.`,
    ),
  ),
  section("Who can use Dream", p(`You need to be at least ${todo("minimum age")} and able to agree to these terms. You sign in with your Apple Account; one account per person.`)),
  section(
    "Your account",
    p("You're responsible for what happens in your account, so keep your Apple Account secure. You can delete your account at any time in Account."),
  ),
  section(
    "What Dream makes",
    list([
      "Pages are written by AI models from other companies, today xAI. What you ask, and what's needed to answer it, goes to them through Dream's server, as the privacy policy describes. Dream may change which providers it uses.",
      "AI-made pages can be wrong, out of date or incomplete, even when they look certain.",
      "Dream isn't professional advice: not medical, legal, financial, tax or safety advice. Check anything important with someone qualified.",
      "Calculations follow the formulas on the page. Check them before you rely on the numbers.",
      "When a page uses the web, it says which pages it read. Those pages, and the pictures and sounds from Wikimedia, belong to their owners and keep their own licences.",
    ]),
  ),
  section(
    "What's yours",
    p(
      `What you ask for, your numbers, lists and memory are yours. You let Dream store and process them to run the service for you, as the privacy policy describes. ${todo("who owns page templates Dream makes, and the licence for shared pages")}`,
    ),
  ),
  section(
    "Sharing",
    p(
      "A shared page can be seen by anyone with its link. You're responsible for what you share: don't share other people's personal information, or anything you don't have the right to share. Anyone can report a shared page, and Dream can take it down.",
    ),
  ),
  section(
    "Using Dream fairly",
    p("Don't use Dream to:"),
    list([
      "break the law, or help anyone else break it;",
      "harm, harass, threaten or deceive people;",
      "make or share sexual content involving minors, or content that exploits anyone;",
      "infringe anyone's rights, including copyright and privacy;",
      "get around limits, extract keys, scrape Dream, or try to break or overload it.",
    ]),
  ),
  section(
    "Connected services",
    p(
      "Services you connect, like Linear or Notion, are your choice and have their own terms. Dream asks before one of their tools sends anything, and a change happens there only when you tap.",
    ),
  ),
  section(
    "Free use and subscription",
    p(todo("final names, allowances and prices")),
    list([
      `Dream is free to use up to ${todo("the free allowance, for example a number of pages a month")}.`,
      `A subscription, ${todo("name and price")}, raises those limits. It's bought through Apple and renews automatically for the same period until you cancel at least 24 hours before it ends.`,
      "Manage or cancel it in Settings › your name › Subscriptions. Payment, renewals and refunds are handled by Apple, under Apple's terms.",
      "If prices change, you'll be told before your next renewal, and can cancel first.",
      `Apple's Licensed Application End User License Agreement applies to Dream ${todo("or a custom licence agreement, which must include Apple's minimum terms")}.`,
    ]),
  ),
  section(
    "Ending",
    p(
      `You can stop using Dream and delete your account at any time. Dream may suspend or close an account that breaks these terms, ${todo("with notice and a way to appeal, except where the law or safety requires otherwise")}.`,
    ),
  ),
  section("Changes", p("Dream changes over time, and these terms may too. If they change in a way that matters, the app will tell you before it takes effect.")),
  section("Disclaimers and liability", p(todo("disclaimer of warranties and limits on liability, for a lawyer to write for each country Dream is offered in"))),
  section("Law", p(todo("governing law and where disputes are settled"))),
  section("Contact", p(`Questions about these terms: ${SUPPORT_CONTACT}.`)),
];

const SUPPORT = [
  section(
    "Get help",
    p(
      `Write to ${SUPPORT_CONTACT}. Say which iPhone and version of iOS you have, and what happened. Please don't send passwords, or anything personal that isn't needed.`,
    ),
  ),
  section(
    "Questions",
    `<h3>How do I delete my account?</h3>`,
    p("In Dream, open Account and choose Delete my account. Everything Dream keeps on its server is erased at once, and backups are gone within 30 days."),
    `<h3>How do I get a copy of my data?</h3>`,
    p("Open Account and choose Export my data."),
    `<h3>A shared page is wrong, offensive or harmful</h3>`,
    p(`Open the link and use Report, or send the link to ${SUPPORT_CONTACT}. Dream can take shared pages down.`),
    `<h3>A page I made is wrong</h3>`,
    p("Tap the wand to ask for a change, or point at the part that's wrong. Pages say where their facts came from at the bottom; check anything important."),
    `<h3>How do I cancel my subscription, or get a refund?</h3>`,
    p(
      'Subscriptions are handled by Apple. Cancel in Settings › your name › Subscriptions. For a refund, go to <a href="https://reportaproblem.apple.com" rel="noopener noreferrer">reportaproblem.apple.com</a>.',
    ),
    `<h3>Why does Dream ask to use…</h3>`,
    list([
      "<strong>Your location:</strong> for the weather and travel times you ask about. It goes from your iPhone to Apple, not to Dream's server.",
      "<strong>The microphone and speech recognition:</strong> so you can ask out loud. What you say is turned into text on your iPhone.",
      "<strong>Calendars and reminders:</strong> only to add an event or reminder when you tap a button that says exactly what it will add.",
      "<strong>Photos:</strong> only the photo you pick, to ask about it.",
    ]),
    `<h3>How do I turn “Help improve Dream” on or off?</h3>`,
    p("In Account. When it's off, Dream sends no crash reports or usage counts."),
  ),
];

const PAGES: Record<LegalPath, { title: string; summary: string; body: string[] }> = {
  "/privacy": { title: "Privacy policy", summary: "What Dream keeps about you, where, for how long, and what you can do about it.", body: PRIVACY },
  "/terms": { title: "Terms of use", summary: "The agreement between you and Dream.", body: TERMS },
  "/support": { title: "Support", summary: "Help with Dream, and answers to common questions.", body: SUPPORT },
};

export function isLegalPath(path: string): path is LegalPath {
  return Object.hasOwn(PAGES, path);
}

/** One of the pages, as HTML. */
export function legalPage(path: LegalPath): string {
  const page = PAGES[path];
  const others = (Object.keys(PAGES) as LegalPath[]).filter((other) => other !== path);
  return document({
    language: "en",
    rtl: false,
    title: page.title,
    accent: "indigo",
    head: `<meta name="description" content="${page.summary}">\n${STYLE}`,
    body: `<header>
<p class="draft">Draft, needs legal review</p>
<h1>${page.title}</h1>
<p class="summary">${page.summary}</p>
<p class="updated">Last updated ${UPDATED}</p>
</header>
${page.body.join("\n")}
<nav class="pages">${others.map((other) => `<a href="${other}">${PAGES[other].title}</a>`).join("")}</nav>`,
  });
}
