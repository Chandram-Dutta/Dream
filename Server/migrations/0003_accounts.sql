-- Accounts (src/auth.ts). A user is someone who signed in with Apple; a session is one signed-in
-- device. Only a hash of each session token is stored, never the token.

CREATE TABLE users (
  id TEXT PRIMARY KEY,          -- Dream's own id for the person, never Apple's
  apple_sub TEXT UNIQUE,        -- Apple's stable id for them in this app
  email TEXT,                   -- only if they shared it; often an Apple relay address
  name TEXT,                    -- Apple sends it once, at the first sign-in
  created_at INTEGER NOT NULL,
  deleted_at INTEGER            -- set while an account is being deleted
);

CREATE TABLE sessions (
  token_hash TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  last_used_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  device TEXT                   -- what the app calls the device, like "iPhone"
);

CREATE INDEX sessions_user ON sessions (user_id);
