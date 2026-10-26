-- Cloud sync (src/sync.ts): each signed-in person's pages, list entries, memory, connections and
-- settings, so they follow them to another iPhone. Stored so the server can read them
-- (PRODUCTION.md). One row per item holds its latest version. A deleted item keeps its row,
-- without its content, so other devices learn it's gone.

CREATE TABLE sync_items (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind TEXT NOT NULL,             -- surface, record, fact, connection or setting
  id TEXT NOT NULL,               -- the item's own id, made on the phone that created it
  parent TEXT,                    -- a list entry's page
  format INTEGER NOT NULL,        -- the shape of body, so later apps can read older items
  updated_at INTEGER NOT NULL,    -- when it last changed, in ms since 1970; the latest change wins
  deleted INTEGER NOT NULL DEFAULT 0,
  body TEXT,                      -- JSON; null once deleted
  size INTEGER NOT NULL,          -- bytes of body, counted against the person's allowance
  change INTEGER NOT NULL,        -- the person's change counter when this version was written
  PRIMARY KEY (user_id, kind, id)
);

-- Reading changes in order, from where a device left off.
CREATE INDEX sync_items_changes ON sync_items (user_id, change, kind, id);
-- A page's entries, which go when the page does.
CREATE INDEX sync_items_parent ON sync_items (user_id, parent) WHERE parent IS NOT NULL;

-- Each person's change counter: every batch the server takes gets the next number.
CREATE TABLE sync_state (
  user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  change INTEGER NOT NULL
);

-- Photos from synced pages. The bytes are in R2 (the dream-photos bucket) under <user id>/<id>;
-- this keeps their sizes, for the allowance.
CREATE TABLE sync_photos (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  id TEXT NOT NULL,
  size INTEGER NOT NULL,
  content_type TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, id)
);
