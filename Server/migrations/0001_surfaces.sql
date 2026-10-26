-- Shared surfaces. Each row is one link: the template as it was shared (with the sharer's numbers
-- only if they chose to include them), plus the few fields a public library will list and search by.
CREATE TABLE surfaces (
  id TEXT PRIMARY KEY,
  created_at INTEGER NOT NULL,
  format INTEGER NOT NULL,
  title TEXT NOT NULL,
  summary TEXT NOT NULL,
  language TEXT,
  has_values INTEGER NOT NULL DEFAULT 0,
  size INTEGER NOT NULL,
  body TEXT NOT NULL
);

CREATE INDEX surfaces_created ON surfaces (created_at);
