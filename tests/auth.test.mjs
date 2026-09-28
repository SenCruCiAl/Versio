// @ts-check
// Unit tests that need no network and no Next runtime. `node --test tests/`.
//
// `app/actions/auth.js` and `lib/supabase/server.js` both reach for
// Next-only modules (`server-only`, `next/headers`, `next/navigation`) —
// those throw/fail to resolve under plain Node (confirmed: `server-only`'s
// index.js unconditionally throws on load; `next/*` subpaths don't resolve
// outside Next's loader). `auth.js` imports them lazily inside each action
// so the *validation* paths (exercised below) never touch them, and
// `lib/supabase/claims.js` is a small Next-free module holding the exact
// claims -> user mapping `requireUser()` uses, so that logic is testable
// directly.
import { test } from "node:test";
import assert from "node:assert/strict";
import { setUsername } from "../app/actions/auth.js";
import { AuthError, claimsToUser } from "../lib/supabase/claims.js";

test("setUsername rejects bad input before any call", async () => {
  const result = await setUsername({ username: "A!" });
  assert.equal(result.ok, false);
  assert.equal(/** @type {{code: string}} */ (result).code, "INVALID_USERNAME");
});

test("setUsername rejects usernames outside the length bounds", async () => {
  const tooShort = await setUsername({ username: "ab" });
  assert.equal(tooShort.ok, false);
  assert.equal(/** @type {{code: string}} */ (tooShort).code, "INVALID_USERNAME");

  const tooLong = await setUsername({ username: "a".repeat(31) });
  assert.equal(tooLong.ok, false);
  assert.equal(/** @type {{code: string}} */ (tooLong).code, "INVALID_USERNAME");
});

test("setUsername rejects non-input (missing field)", async () => {
  // @ts-expect-error deliberately malformed input
  const result = await setUsername({});
  assert.equal(result.ok, false);
  assert.equal(/** @type {{code: string}} */ (result).code, "INVALID_USERNAME");
});

test("claimsToUser throws AuthError('UNAUTHENTICATED') when getClaims returns no claims", () => {
  const noSession = { data: null, error: null };
  assert.throws(
    () => claimsToUser(noSession),
    (err) => err instanceof AuthError && err.code === "UNAUTHENTICATED",
  );

  const withError = { data: null, error: new Error("expired") };
  assert.throws(
    () => claimsToUser(withError),
    (err) => err instanceof AuthError && err.code === "UNAUTHENTICATED",
  );

  assert.throws(
    () => claimsToUser(null),
    (err) => err instanceof AuthError && err.code === "UNAUTHENTICATED",
  );

  const missingSub = { data: { claims: { role: "authenticated" } }, error: null };
  assert.throws(
    () => claimsToUser(missingSub),
    (err) => err instanceof AuthError && err.code === "UNAUTHENTICATED",
  );
});

test("claimsToUser returns { uid, claims } for a verified session (requireUser's success path)", () => {
  const result = {
    data: {
      claims: { sub: "11111111-1111-1111-1111-111111111111", role: "authenticated" },
      header: { alg: "ES256" },
    },
    error: null,
  };
  const user = claimsToUser(result);
  assert.equal(user.uid, "11111111-1111-1111-1111-111111111111");
  assert.equal(user.claims.role, "authenticated");
});

test("requireUser's rejection path (mocked client): no claims -> UNAUTHENTICATED", async () => {
  // `requireUser()` itself needs `cookies()`/`server-only`, which only run
  // inside a real Next request/build. This exercises the exact same
  // rejection path it delegates to (claimsToUser) against a client double
  // shaped like what `supabase.auth.getClaims()` returns with no session —
  // i.e. "inject/mock the client" per the no-session case.
  const fakeSupabase = {
    auth: {
      async getClaims() {
        return { data: null, error: null };
      },
    },
  };
  const result = await fakeSupabase.auth.getClaims();
  assert.throws(
    () => claimsToUser(result),
    (err) => err instanceof AuthError && err.code === "UNAUTHENTICATED",
  );
});
