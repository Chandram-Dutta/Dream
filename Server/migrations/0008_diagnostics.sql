-- Crash, hang and slow-launch reports from the app (src/diagnostics.ts), sent only when its user
-- has turned on "Help improve Dream". Anonymous: no account, no address, no region and nothing
-- anyone wrote. Rows are deleted after 90 days, as new ones arrive.

CREATE TABLE diagnostics (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL,                 -- crash, hang or launch
  received_at INTEGER NOT NULL,       -- seconds since 1970
  day TEXT NOT NULL,                  -- received_at's day, YYYY-MM-DD, for counting by day
  app_version TEXT NOT NULL,          -- like 1.0
  app_build TEXT NOT NULL,            -- like 12
  os_version TEXT NOT NULL,           -- like "iPhone OS 27.0 (24A335)"
  device TEXT NOT NULL,               -- the model's identifier, like iPhone18,1
  test_flight INTEGER NOT NULL DEFAULT 0,
  period_start INTEGER,               -- the span MetricKit's payload covers, in seconds
  period_end INTEGER,
  duration REAL,                      -- how long a hang or launch took, in seconds
  exception_type INTEGER,             -- crashes: the Mach exception, signal and Objective-C exception
  exception_code INTEGER,
  signal INTEGER,
  exception_name TEXT,                -- like NSRangeException; never the exception's message
  exception_class TEXT,
  termination_reason TEXT,
  signature TEXT NOT NULL,            -- where it happened, for grouping: "EXC_BREAKPOINT SIGTRAP Dream+0x1a2b4"
  stack TEXT                          -- MetricKit's call stack tree as JSON; null when it was too big
);

CREATE INDEX diagnostics_received ON diagnostics (received_at);
CREATE INDEX diagnostics_kind_day ON diagnostics (kind, day);
CREATE INDEX diagnostics_signature ON diagnostics (kind, signature);
