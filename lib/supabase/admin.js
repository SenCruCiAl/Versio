// @ts-check
import "server-only";
import { createClient as createSupabaseClient } from "@supabase/supabase-js";

/** @type {import("@supabase/supabase-js").SupabaseClient | null} */
let cached = null;

/**
 * Service-role client. Bypasses RLS entirely — per BACKEND_PLAN.md §3 rule 2
 * this is used ONLY for `commit_version` (which receives `p_actor` from
 * verified JWT claims, never from client input) and takedown/orphan cleanup.
 * No session persistence: this client does not represent any one user.
 *
 * Reads `SUPABASE_SERVICE_ROLE_KEY` from `process.env` only — never accept
 * it as a parameter, never log it, never send it to the browser.
 *
 * @returns {import("@supabase/supabase-js").SupabaseClient}
 */
export function createClient() {
  if (cached) return cached;

  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (!url || !serviceRoleKey) {
    throw new Error(
      "Missing NEXT_PUBLIC_SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY env var",
    );
  }

  cached = createSupabaseClient(url, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  return cached;
}
