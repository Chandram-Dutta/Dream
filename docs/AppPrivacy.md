# App Privacy answers (draft)

What to answer in App Store Connect › App Privacy for Dream 1.0, given the production decisions in
PRODUCTION.md: accounts with Sign in with Apple, and pages, lists, memory, photos, usage and
subscriptions stored on Dream's backend (Cloudflare), which can read them. The same answers are
in the app's privacy manifest, `Dream/PrivacyInfo.xcprivacy`; change both together.

Draft, needs review: the person who submits the app answers these, and the privacy policy
(`/privacy` on the Worker) must say the same things.

## The short version

- **Tracking:** No. Dream doesn't link its data with other companies' data for advertising, and
  doesn't share it with data brokers. No App Tracking Transparency prompt is needed.
- **Data linked to you:** name, email address, user ID, device ID, photos, other user content,
  search history, purchase history, product interaction, other usage data, performance data.
- **Data not linked to you:** crash data, other diagnostic data.

Data collected only after the user agrees ("Help improve Dream": product interaction, device ID,
performance data, crash data, other diagnostic data) must still be declared. Apple's rule is that
optional collection is still collection.

## Per data type

| App Store Connect type | Collected | Linked | Tracking | Purposes | What it is |
|---|---|---|---|---|---|
| Contact info › Name | Yes | Yes | No | App functionality | The name Sign in with Apple shares, once, at the first sign-in. |
| Contact info › Email address | Yes | Yes | No | App functionality | The email Sign in with Apple shares, often a private relay address. Only if the user shares it. |
| Contact info › Phone, physical address, other | No | | | | |
| Health and fitness | No | | | | Pages can be about health, but Dream doesn't collect health data as such; what someone types is user content. |
| Financial info | No | | | | Purchases go through Apple; Dream never sees payment details. Expense lists are user content. |
| Location › Precise, coarse | No (see note) | | | | Location is read on the phone for weather and travel times and sent to Apple's WeatherKit and MapKit. Dream's server and the model get the weather or the travel time, never coordinates; a page's source says "current location", not where it is. |
| Sensitive info | No | | | | |
| Contacts | No | | | | |
| User content › Emails or text messages | No | | | | |
| User content › Photos or videos | Yes | Yes | No | App functionality | Photos the user attaches to a request or a list, sent to the model and kept with the page. |
| User content › Audio data | No | | | | Speech is turned into text on the iPhone; audio never leaves it. |
| User content › Gameplay content | No | | | | |
| User content › Customer support | No | | | | Support is by email, outside the app. Revisit if in-app support is added. |
| User content › Other user content | Yes | Yes | No | App functionality | Saved pages (template, values, answers, the history of requests and changes), list entries, memory facts, the list of connected services (not their tokens), settings, and shared pages. Requests and pages go to xAI to be made. |
| Browsing history | No | | | | Web pages are read by Dream's server for a page, not from the user's browsing. |
| Search history | Yes | Yes | No | App functionality | What the user asks Dream, kept with each page's history. Web searches the model makes are cached for hours under hashed keys, but come from requests already declared. |
| Identifiers › User ID | Yes | Yes | No | App functionality, analytics | Dream's own id for the account (a random UUID, never Apple's id or an email). Analytics are tied to it after sign-in. |
| Identifiers › Device ID | Yes | Yes | No | Analytics | PostHog's random id for this install, until sign-in. Not the advertising identifier, which Dream never reads. Only with "Help improve Dream". |
| Purchases › Purchase history | Yes | Yes | No | App functionality | Subscription status from Apple's signed transactions (workstream D). |
| Usage data › Product interaction | Yes | Yes | No | Analytics | The events in docs/Analytics.md, through PostHog. Only with "Help improve Dream". Never what anyone wrote. |
| Usage data › Advertising data | No | | | | No ads. |
| Usage data › Other usage data | Yes | Yes | No | App functionality | Per-account counts of pages, model tokens and searches, for the free allowance and limits (workstream D). |
| Diagnostics › Crash data | Yes | No | No | App functionality | MetricKit crash, hang and slow-launch reports, sent to Dream's server with no account. Only with "Help improve Dream". |
| Diagnostics › Performance data | Yes | Yes | No | App functionality, analytics | Hang and launch durations (not linked, from MetricKit) and how long pages take to build (linked, in product analytics). Declared as linked because the second is. |
| Diagnostics › Other diagnostic data | Yes | No | No | App functionality | The app and iOS version and the kind of iPhone, with each MetricKit report. |
| Surroundings, body | No | | | | |
| Other data | No | | | | |

### Notes for whoever submits

- **Location.** The answer above relies on Dream itself not collecting it: coordinates go only to
  Apple's own services for the request, and only results reach Dream's server and the model. If
  that changes (say, the server starts storing a page's place), or review disagrees, answer
  Location › Coarse location: collected, linked, app functionality.
- **Third parties count.** xAI (the model), Parallel (web search) and PostHog (analytics) receive
  data on Dream's behalf. Their data is covered by the rows above; the privacy policy names them.
- **"Help improve Dream" is opt-in.** It's off until the user answers the first-run question, and
  turning it off in Account stops both MetricKit reports and PostHog at once.
- **Deletion.** Account deletion in the app (workstream A) erases everything server-side; D1's
  Time Travel backups age out within 30 days. Analytics in PostHog are deleted by person id on
  request (see the privacy policy).
- **Privacy policy URL:** https://dream.onlychan.xyz/privacy

## The privacy manifest

`Dream/PrivacyInfo.xcprivacy` declares the collected types above and the required-reason APIs in
the app's binary, from an audit on 2026-10-27:

| API category | Reason | Who uses it |
|---|---|---|
| UserDefaults | CA92.1 (the app's own data) | The app's settings and choices; PostHog |
| File timestamp | C617.1 (files in the app's container) | swift-system (linked by the MCP SDK) wraps `stat`, `lstat`, `fstat`, `fstatat`; PostHog reads a file's modification date |
| System boot time | 35F9.1 (elapsed time in the app) | PostHog and its crash reporter (`mach_absolute_time`, `sysctl`) |
| Disk space | Not used | |
| Active keyboards | Not used | |

SwiftMath, swift-log and EventSource use none of them. PostHog ships its own manifest too, inside
its resource bundle. Re-run the audit when a package is added or updated:

```sh
nm -u <Dream.app>/Dream.debug.dylib | grep -E '^_(stat|lstat|fstat|fstatat|getattrlist|statfs|statvfs|mach_absolute_time|sysctl)$|UserDefaults|ModificationDate|systemUptime|volumeAvailableCapacity'
```

(`Dream.debug.dylib` in Debug builds; the `Dream` executable itself in Release.)
