# Toward production

Dream works end to end as a prototype (see ROADMAP.md). This is what stands between it and a
public App Store release, the decisions taken, and the work in progress.

> On the `apple-intelligence` branch, pages are made only by Apple's models, sign-in is optional
> and there's no subscription, so the model, proxy and Dream Plus parts below describe `main`.
> See docs/AppleIntelligence.md; the privacy policy and terms (`Server/src/legal.ts`) describe
> that branch.

## Decisions (2026-10-27)

- **Accounts:** Sign in with Apple, with accounts on Dream's own backend (Cloudflare Worker + D1).
- **Personal data:** saved pages, the user's numbers, lists and memory are stored on the backend.
  It can read them. Pages' history of requests and changes counts as part of the page.
- **Models:** the app reaches Grok (and later others) through the backend, with Dream's own key and
  per-account limits. Bring-your-own-key stays as a developer option only.
- **Domain:** `dream.onlychan.xyz`, now serving the backend. `workers.dev` stays on for old links.
- **Pricing:** a free tier plus a subscription, through StoreKit 2.

## Foundation (done)

- `Server/migrations/0003_accounts.sql`: `users` and `sessions`.
- `Server/src/auth.ts`:
  - `userFrom(request, env)` returns the signed-in user, or null; call it on every route that
    keeps or spends something for a person. `signInNeeded()` is the 401.
  - `startSession`, `newUserID`, `hashToken`.
  - `POST /api/dev/session?user=name` gives a test session, only where `DEV_LOGIN=1` is set in
    `.dev.vars`; never in production.
- `Dream/Generation/Providers/Session.swift`:
  - `Session.token` is kept in the Keychain, or comes from `DREAM_SESSION` on the bench.
  - `Session.authorize(&request)` sends `Authorization: Bearer <session>`.
  - `Session.didChange` is posted on sign-in and sign-out.
- `ServerAddress.dream` is the backend's address.
- **The app key moves.** The web routes' key leaves `Authorization` for `X-Dream-Key` (workstream D),
  so `Authorization` always carries the session.
- **Migration numbers** are reserved per workstream, so files don't collide: A 0004, B 0005,
  C 0006, D 0007, E 0008.

## Wave 3 workstreams

**A. Accounts.**
- Sign in with Apple in the app, and `POST /api/auth/apple` on the server, which verifies Apple's
  identity token against Apple's keys (audience, issuer, expiry, nonce).
- First-run sign-in that feels like Dream.
- An account screen: name and email, signed-in devices, sign out, export my data, and delete my
  account. Deleting erases everything server-side and revokes Apple tokens. App Store guideline
  5.1.1(v) requires in-app deletion.
- On first sign-in, offer to move the phone's existing pages, lists and memory into the account.
- Signing out clears personal data from the phone.

**B. Cloud sync.**
- Server-readable tables for pages (template, values, answers, request and change history),
  list entries, memory facts, the connection list (never OAuth tokens) and settings, plus R2
  for photos.
- A local-first sync engine: SwiftData stays the source for the UI, changes queue up and push,
  pulls happen on open and periodically, last write per item wins, deletions travel as
  tombstones, and it works across devices.

**C. Sharing management, trust and safety.**
- Shares belong to their owner's account.
- "Your shared links": open, copy, update to the page's latest version, stop sharing, and view
  counts (counts only).
- A report button on the web viewer, a report queue, and an admin takedown endpoint. Shared pages
  are user-generated content, which App Store guideline 1.2 covers.
- A basic automated check before a page is published.

**D. Model proxy, limits and subscription.**
- `POST /api/model` proxies xAI chat completions (streaming) with the server's key.
- A Dream `LanguageModel` adapter in the app, using the session.
- Metering per account (pages, tokens, searches) and a free allowance.
- StoreKit 2 subscription and paywall, with signed transactions verified on the server and an
  endpoint for App Store Server Notifications v2.
- Web routes move to sessions and per-account limits.
- App Attest for the app key.

**E. Release readiness.**
- Release builds hide Under the hood and ignore the testing launch arguments.
- A privacy manifest (PrivacyInfo.xcprivacy).
- Drafts:
  - App Privacy answers;
  - privacy policy, terms and support pages served by the Worker;
  - App Store metadata and review notes.
- MetricKit diagnostics sent to the backend.
- Tests:
  - a Swift Testing target holding the `Tools/*.sh` checks;
  - a CI workflow file;
  - a `staging` Worker environment with its own database.
- An app icon.

## What production needs, in full

**Accounts and data**
- Sign in with Apple.
- Account deletion and data export.
- Sync across devices.
- A schema-versioning plan for SwiftData (VersionedSchema).
- D1 backups (Time Travel) and migrations practice.

**Money and abuse**
- No provider keys on phones.
- Per-account limits and a free tier.
- Subscription.
- App Attest.
- Rate limits.
- Daily budgets with alerts.
- A kill switch to change model provider without an app update.

**Trust and safety**
- Report and takedown for shared pages.
- Moderation of what's published.
- The age rating (AI-made content plus open web results).
- Prompt-injection defences, which are already fenced.
- A way to block abusive accounts.

**Privacy and legal**
- A privacy policy, and terms.
- App Privacy labels, and a privacy manifest.
- Data retention, and the rights requests GDPR and India's DPDP Act require.
- A list of subprocessors: Cloudflare, xAI, Parallel, Apple Weather, Wikimedia.
- Checking xAI's and Parallel's terms allow a consumer app.
- Export compliance: HTTPS only, so likely exempt.

**Reliability and operations**
- Crash and hang reporting.
- Server error alerts.
- A staging environment.
- Load and latency work. Pages take 20–60 s to build; streaming hides some of it.
- Model fallbacks. A busy or silent model is asked again, and a page that comes out broken or
  empty is written again once (Composer.swift), but on a phone there's no second model to turn
  to: Private Cloud Compute is still awaiting Apple's entitlement.

**Quality**
- Automated tests in Xcode, and CI.
- TestFlight beta.
- An accessibility audit (VoiceOver, Dynamic Type, Reduce Motion).
- Localizing the app's own text.

**App Store**
- Icon and screenshots.
- Description, keywords and support URL.
- Review notes with a demo account.
- Release configuration.
- Versioning.

## Needs from the user

- **Sign in with Apple key.** Create one in the developer portal (Keys → Sign in with Apple) and
  share its Key ID. The .p8 goes into a Worker secret: the server needs it to revoke Apple tokens
  when an account is deleted.
- **App Store Connect:**
  - create the app record;
  - create a subscription group and products, with prices;
  - sign the Paid Apps agreement;
  - set the App Store Server Notifications URL to the backend.
- **xAI:** a production API key for the server, set as a Worker secret.
- **Legal:** the pages are written in Chandram Dutta's name (an individual, not a company), for
  16+ everywhere. A lawyer's review is optional, worth it with revenue or an EU push.
- **Parallel:** sign its Data Processing Addendum, and ask whether shared pages may carry text made
  from its results.
- **Optional:** a GitHub repository for CI.
