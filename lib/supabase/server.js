// @ts-check
import "server-only";
import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";
import { AuthError, claimsToUser } from "./claims.js";

export { AuthError, claimsToUser };

/**
 * @param {string} name
 * @returns {string}
 */
function requireEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required env var: ${name}`);
  }
  return value;
}

/**
 * One Supabase client per request, backed by the request's cookies via
 * `next/headers`. Never share a client across requests (the `@supabase/ssr`
 * contract). Uses the anon key only — writes go through RPCs, which enforce
 * their own actor checks under RLS.
 *
 * @returns {Promise<import("@supabase/supabase-js").SupabaseClient>}
 */
export async function createClient() {
  const cookieStore = await cookies();

  return createServerClient(
    requireEnv("NEXT_PUBLIC_SUPABASE_URL"),
    requireEnv("NEXT_PUBLIC_SUPABASE_ANON_KEY"),
    {
      cookies: {
        getAll() {
          return cookieStore.getAll();
        },
        setAll(cookiesToSet) {
          try {
            for (const { name, value, options } of cookiesToSet) {
              cookieStore.set(name, value, options);
            }
          } catch {
            // Called from a Server Component render, where cookies can't be
            // written. proxy.js refreshes the session on the next request.
          }
        },
      },
    },
  );
}

/**
 * Verifies the caller's JWT locally (asymmetric signing keys, cached JWKS) —
 * no round trip to the Auth server. Never call `getSession()` on the server.
 *
 * @param {import("@supabase/supabase-js").SupabaseClient} supabase
 * @returns {ReturnType<import("@supabase/supabase-js").SupabaseClient["auth"]["getClaims"]>}
 */
export function getClaims(supabase) {
  return supabase.auth.getClaims();
}

/**
 * @typedef {{
 *   supabase: import("@supabase/supabase-js").SupabaseClient,
 *   uid: string,
 *   claims: Record<string, unknown>
 * }} RequireUserResult
 */

/**
 * Resolves the current request's authenticated user from verified JWT
 * claims, or throws. This is the only source of `p_actor` for write RPCs —
 * never trust a `uid`/`user_id` passed in from client input.
 *
 * @param {import("@supabase/supabase-js").SupabaseClient} [client]
 *   Optional client override, for callers that already created one this
 *   request (e.g. to avoid a second `cookies()` read).
 * @returns {Promise<RequireUserResult>}
 * @throws {AuthError} code 'UNAUTHENTICATED' when there is no verified session.
 */
export async function requireUser(client) {
  const supabase = client ?? (await createClient());
  const result = await getClaims(supabase);
  const { uid, claims } = claimsToUser(result);
  return { supabase, uid, claims };
}
