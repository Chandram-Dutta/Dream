-- Web search and page reading (src/web.ts).

-- Answers kept for a while, so asking again costs nothing. Keyed by a hash of what was asked, so
-- no query or address is stored as such; rows expire within hours and are cleared as new ones come.
CREATE TABLE web_cache (
  key TEXT PRIMARY KEY,
  expires_at INTEGER NOT NULL,
  body TEXT NOT NULL
);

CREATE INDEX web_cache_expiry ON web_cache (expires_at);

-- Provider calls per day, for everyone together, against the daily budget (WEB_DAILY_LIMIT).
CREATE TABLE web_usage (
  day TEXT NOT NULL,
  kind TEXT NOT NULL,
  count INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (day, kind)
);
