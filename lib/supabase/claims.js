// @ts-check
// Pure, network-free helpers shared by `lib/supabase/server.js`.
//
// Deliberately has NO `server-only` / `next/headers` imports: `server-only`
// throws unconditionally the moment it is loaded outside a Next.js/webpack
// build (see node_modules/server-only/index.js), and `next/headers` fails to
// resolve under plain Node. That makes `server.js` itself impossible to
// `import` from `node --test`. This module holds the one piece of
// `requireUser()`'s logic that actually needs testing — the claims -> user
// mapping — so it can be unit tested without a Next runtime.

/**
 * Thrown by auth helpers. `code` is a small, closed set of machine-readable
 * reasons a caller (a server action) can switch on.
 */
export class AuthError extends Error {
  /**
   * @param {string} code
   * @param {string} [message]
   */
  constructor(code, message) {
    super(message ?? code);
    this.name = "AuthError";
    /** @type {string} */
    this.code = code;
  }
}

/**
 * @typedef {{
 *   data: { claims: Record<string, unknown>, header?: Record<string, unknown>, signature?: Uint8Array } | null,
 *   error: unknown
 * } | null | undefined} GetClaimsResult
 *   The shape of `await supabase.auth.getClaims()`.
 */

/**
 * Maps a `supabase.auth.getClaims()` result to `{ uid, claims }`.
 *
 * `getClaims()` verifies the JWT locally against the cached JWKS (asymmetric
 * signing keys) with no Auth-server round trip — never use `getSession()` on
 * the server (BACKEND_PLAN.md §4.1, E6).
 *
 * @param {GetClaimsResult} result
 * @returns {{ uid: string, claims: Record<string, unknown> }}
 * @throws {AuthError} code 'UNAUTHENTICATED' when there is no verified session.
 */
export function claimsToUser(result) {
  const claims = result && !result.error ? (result.data?.claims ?? null) : null;
  const sub = claims && typeof claims.sub === "string" ? claims.sub : null;

  if (!claims || !sub) {
    throw new AuthError("UNAUTHENTICATED", "No verified session.");
  }

  return { uid: sub, claims };
}
