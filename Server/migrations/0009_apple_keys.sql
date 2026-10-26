-- Apple's published Sign in with Apple keys (src/apple.ts), kept between fetches. They're public.
-- appleid.apple.com answers some of Cloudflare's servers with 501, so sign-ins read this copy
-- first, and every good fetch, including the scheduled one, keeps it fresh.
CREATE TABLE apple_keys (
  url TEXT PRIMARY KEY,
  body TEXT NOT NULL,
  fetched_at INTEGER NOT NULL -- ms
);
