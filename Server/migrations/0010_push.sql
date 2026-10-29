-- iPhones to tell when a page is ready or Dream has a question (src/push.ts): each one's APNs
-- device token, for the account signed in on it. A few per account at most. A token goes when its
-- iPhone signs out (DELETE /api/push/devices/:token), when the session that registered it ends,
-- when the account is deleted, and when Apple says it's no longer good.

CREATE TABLE push_devices (
  token TEXT PRIMARY KEY,             -- the APNs device token, hex; one iPhone, one account at a time
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  session_hash TEXT NOT NULL REFERENCES sessions(token_hash) ON DELETE CASCADE,
  environment TEXT NOT NULL,          -- sandbox (development builds) or production
  created_at INTEGER NOT NULL,        -- seconds since 1970
  updated_at INTEGER NOT NULL
);

CREATE INDEX push_devices_user ON push_devices (user_id, updated_at);
CREATE INDEX push_devices_session ON push_devices (session_hash);
