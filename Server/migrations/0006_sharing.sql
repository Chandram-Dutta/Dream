-- Shared links that belong to someone (src/shares.ts), and keeping them safe (src/safety.ts).

-- Who shared each link, and what's become of it. Links made before accounts have no owner: they
-- keep working, read-only. A link that stops keeps its id, so it says it's gone rather than 404.
ALTER TABLE surfaces ADD COLUMN owner_id TEXT;      -- users.id; null for older, anonymous links
ALTER TABLE surfaces ADD COLUMN page_id TEXT;       -- the app's own id for the page, so sharing it again reuses the link
ALTER TABLE surfaces ADD COLUMN updated_at INTEGER; -- when its content last changed
ALTER TABLE surfaces ADD COLUMN expires_at INTEGER; -- when the owner chose for it to stop working, if they did
ALTER TABLE surfaces ADD COLUMN revoked_at INTEGER; -- when it stopped: by its owner, a takedown, or the account's deletion
ALTER TABLE surfaces ADD COLUMN revoked_by TEXT;    -- 'owner', 'admin' or 'account'
ALTER TABLE surfaces ADD COLUMN views INTEGER NOT NULL DEFAULT 0; -- a count only: nothing about who looked

CREATE INDEX surfaces_owner ON surfaces (owner_id, page_id);

-- Reports from readers. Nothing about who reported is kept: reports come from the web viewer,
-- anonymously, as well as the app. The note is what they chose to write, at most 500 characters.
CREATE TABLE reports (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  share_id TEXT NOT NULL,
  reason TEXT NOT NULL,         -- hate, sexual, violence, private, spam or other
  note TEXT,
  via TEXT NOT NULL,            -- 'web' or 'app'
  created_at INTEGER NOT NULL,
  resolved_at INTEGER,
  resolution TEXT               -- 'removed', 'dismissed' or 'gone' (stopped by its owner, or the account deleted)
);

CREATE INDEX reports_open ON reports (resolved_at, share_id);

-- Sharers someone chose not to see again. The sharer is never named to them: the list shows the
-- title of the page they blocked from.
CREATE TABLE blocked_sharers (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL,        -- who doesn't want to see them
  owner_id TEXT NOT NULL,       -- the sharer
  title TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  UNIQUE (user_id, owner_id)
);

CREATE INDEX blocked_sharers_owner ON blocked_sharers (owner_id);

-- Accounts that may no longer share, set by an admin.
CREATE TABLE sharing_bans (
  user_id TEXT PRIMARY KEY,
  created_at INTEGER NOT NULL
);
