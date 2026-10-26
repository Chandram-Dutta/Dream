-- Sign in with Apple (src/apple.ts, src/accounts.ts).

-- The nonce of every identity token used to sign in, kept until the token expires, so each token
-- signs in once: one that's been seen before is refused. The nonce is already a hash (the app
-- sends Apple a SHA-256 of a random value), so nothing here says who signed in.
CREATE TABLE apple_nonces (
  nonce TEXT PRIMARY KEY,
  expires_at INTEGER NOT NULL
);

CREATE INDEX apple_nonces_expiry ON apple_nonces (expires_at);
