-- What each account uses and may use, Dream Plus, and App Attest keys (src/usage.ts,
-- src/appstore.ts, src/attest.ts). Nothing here holds what anyone asked or read: only counts,
-- costs, and the App Store's ids for a subscription.

-- Use per account, per UTC day (period 2026-10-27) and per month (period 2026-10).
CREATE TABLE usage (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  period TEXT NOT NULL,
  pages INTEGER NOT NULL DEFAULT 0,           -- new pages and changes
  tokens_in INTEGER NOT NULL DEFAULT 0,
  tokens_cached INTEGER NOT NULL DEFAULT 0,   -- of tokens_in, read from the provider's cache
  tokens_out INTEGER NOT NULL DEFAULT 0,      -- answers and reasoning
  searches INTEGER NOT NULL DEFAULT 0,
  reads INTEGER NOT NULL DEFAULT 0,
  cost_micros INTEGER NOT NULL DEFAULT 0,     -- what the model cost Dream, in millionths of a dollar
  PRIMARY KEY (user_id, period)
);

-- Pages being built, by the app's id for each, so a page's several requests count once and
-- one page can't spend without end. Kept for two days.
CREATE TABLE usage_pages (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  page TEXT NOT NULL,
  day TEXT NOT NULL,
  cost_micros INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, page)
);

-- Spending for everyone together, per UTC day, against the daily budget (MODEL_DAILY_BUDGET).
CREATE TABLE spend (
  day TEXT NOT NULL,
  kind TEXT NOT NULL,
  amount INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (day, kind)
);

-- Dream Plus, one row per App Store subscription, as its newest signed transaction says.
CREATE TABLE subscriptions (
  original_transaction_id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  product_id TEXT NOT NULL,
  environment TEXT NOT NULL,     -- Production, or Sandbox (TestFlight and App Review)
  expires_at INTEGER NOT NULL,   -- ms since 1970, including any billing grace period
  revoked_at INTEGER,            -- ms; refunded or revoked
  auto_renew INTEGER,            -- 1 renews, 0 doesn't, null not known yet
  signed_at INTEGER NOT NULL,    -- ms; when the App Store signed the newest state applied
  updated_at INTEGER NOT NULL
);

CREATE INDEX subscriptions_user ON subscriptions (user_id);

-- App Store Server Notifications already handled, so a retry isn't applied twice.
CREATE TABLE appstore_notifications (
  uuid TEXT PRIMARY KEY,
  received_at INTEGER NOT NULL
);

-- App Attest keys, one per install of the app, and the one-time challenges they're made for.
CREATE TABLE attest_keys (
  key_id TEXT PRIMARY KEY,       -- base64 SHA-256 of the public key, as the app names it
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  public_key TEXT NOT NULL,      -- SubjectPublicKeyInfo, base64
  environment TEXT NOT NULL,     -- production or development
  counter INTEGER NOT NULL,      -- the highest assertion counter seen
  seen INTEGER NOT NULL,         -- which of the 20 counters below it have been used, as bits
  receipt TEXT,                  -- Apple's receipt, for asking about fraud risk later
  created_at INTEGER NOT NULL,
  last_used_at INTEGER NOT NULL
);

CREATE INDEX attest_keys_user ON attest_keys (user_id);

CREATE TABLE attest_challenges (
  challenge TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  expires_at INTEGER NOT NULL
);
