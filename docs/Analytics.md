# Product analytics

Dream counts how it's used through PostHog, only after the user says yes to "Help improve Dream"
(the first-run question on the home screen, or Account). The same choice sends crash and hang
reports to Dream's own server (Dream/Privacy/Diagnostics.swift). It's off until answered, and
turning it off calls PostHog's `optOut()` at once.

Events say what happened, never what anyone wrote: no requests, page text, values, list entries,
memory, names or addresses. Every name and property lives in `Dream/Engine/Analytics.swift`;
this table mirrors it.

## Events

| Event | Properties | Sent when | Where |
|---|---|---|---|
| `app_opened` | | Dream comes to the front, including at launch | `ImproveDream.start` |
| `signed_in` | | After sign-in, once `ProductAnalytics.signedIn(userID:)` is called | Account (workstream A) |
| `signed_out` | | When the session ends | `Session.didChange` |
| `page_requested` | `with_photo` | A new page is asked for | `Composer.compose` |
| `page_built` | `seconds`, `model`, `blocks`, `block_kinds`, `inputs`, `outputs`, `lists`, `live_sources`, `used_web`, `used_connections`, `asked_questions` | A page finished | `Composer.compose` |
| `page_failed` | `reason`, `changing`, `seconds` | Making or changing a page failed | `Composer` |
| `page_changed` | as `page_built`, plus `pointed_at_block`; no `model` | A change to a page finished | `Composer.edit` |
| `controls_used` | `changes`, `controls` | A page closes after its controls were used | `SurfaceScreen` (ControlUses.swift) |
| `shared` | `kind` (link, picture), `with_numbers` | A link is made, or the picture's share button is tapped | `ShareSheet` |
| `opened_shared` | `again` | A shared link opens in Dream | `SharedLinks` |
| `list_entries_added` | `count` | Entries are typed, said, photographed or tapped into a list | `SurfaceState.change` |
| `connection_added` | `needs_sign_in` | A service is connected | `ConnectionStore.add` |
| `tool_prompt_shown` | | A connected service's tool asks before it runs | `ConsentView` |
| `tool_prompt_answered` | `answer` (once, always, deny) | The user answers it | `ConsentView` |
| `paywall_shown` | | The paywall appears | Subscription (workstream D) |
| `subscription_started` | `product` | A subscription starts | Workstream D, or the server |
| `subscription_ended` | | A subscription ends | Workstream D, or the server |
| `limit_reached` | `kind` (pages, tokens, searches) | A free allowance runs out | Workstream D, or the server |

Property meanings:

- `seconds`: from the request to the finished page, to a tenth of a second.
- `model`: the provider and model, like "Grok (grok-4.7)".
- `block_kinds`: the kinds of block on the page, like `chart`, `slider`, `list` (Surface.swift's
  `BlockKind`), never their content.
- `used_web`: the page cites a web page other than Wikipedia. `used_connections`: a connected
  service's data is on it. `asked_questions`: Dream asked before building.
- `reason`: `no_model`, `safety_filter`, `too_big`, `rate_limited`, `network`, `empty`, `model`,
  `cancelled` (the user left), `other`. Taken from the error's type, never its message.
- `controls_used.changes`: separate uses, where a slider drag is one; `controls`: how many
  different controls.

PostHog adds its own context to each event: app version and build, iOS version, device model,
locale and screen size. Location from the address is turned off (`disableGeoIp`).

## Identity

- Before sign-in, PostHog uses a random id for this install, and makes no person profile
  (`personProfiles = .identifiedOnly`).
- After sign-in, Account calls `ProductAnalytics.signedIn(userID:)` with Dream's own id for the
  person, the server's UUID. Never Apple's id or an email.
- On sign-out (`Session.didChange` with no session), `signed_out` is sent and PostHog's `reset()`
  starts a fresh anonymous id.

## Configuration

- `POSTHOG_KEY` and `POSTHOG_HOST` build settings (Dream target), which reach Info.plist as
  `PostHogKey` and `PostHogHost`, like `DREAM_SHARE_HOST`. With no key, the SDK never starts.
- The key is PostHog's public project key. The host is `https://us.i.posthog.com` for US cloud
  or `https://eu.i.posthog.com` for EU cloud.
- Turned off in the SDK: session replay, screen views, lifecycle events, autocapture, swizzling,
  surveys, crash autocapture (MetricKit covers crashes), feature flag call events and GeoIP.

## Feature flags

`FeatureFlag` (in Analytics.swift) reads PostHog flags, falling back to a default:

```swift
extension FeatureFlag {
    static let webSearch = FeatureFlag("web-search", fallback: true)
}
if FeatureFlag.webSearch.isOn { … }
```

None is wired yet. Flags load only while the user agrees to help improve Dream, so everyone
else gets the fallback. A switch that must reach everyone, like changing the model provider,
belongs on Dream's own server.

## Server events

While "Help improve Dream" is on, the app sends `X-Dream-Analytics: on` with its requests to
Dream's server, and only then does the Worker send events of its own (`Server/src/analytics.ts`,
`countsAllowed`), keyed by the same user id. Its `POSTHOG_KEY` var holds the same public project
key as the app.

| Event | Properties | Sent when | Where |
|---|---|---|---|
| `$ai_generation` | `$ai_trace_id` (the page's id; a page's tool rounds and repairs are one trace), `$ai_span_name` (`page` or `lists`), `$ai_provider`, `$ai_model`, `$ai_input_tokens`, `$ai_cache_read_input_tokens`, `$ai_output_tokens` (with reasoning), `$ai_total_cost_usd` (xAI's own figure when it gives one), `$ai_latency`, `$ai_time_to_first_token`, `$ai_stream`, `$ai_http_status`, `$ai_is_error`, `plan` | Each request through the model proxy, done or failed | `Server/src/model.ts` |

They feed PostHog's LLM analytics: cost per person and per page, latency, cache use and errors.
Never `$ai_input` or `$ai_output_choices`: no messages, answers or tool calls leave for PostHog.

`limit_reached`, `subscription_started` and `subscription_ended` can also be sent from the Worker,
after the same check. The App Store's notifications come from Apple, not the phone, so they send
nothing; the app counts purchases itself.
