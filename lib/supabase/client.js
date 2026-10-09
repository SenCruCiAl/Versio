// @ts-check
import { createBrowserClient } from "@supabase/ssr";

/**
 * Browser client (anon key). For Client Components only — server code uses
 * `lib/supabase/server.js` instead.
 *
 * @returns {import("@supabase/supabase-js").SupabaseClient}
 */
export function createClient() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

  if (!url || !anonKey) {
    throw new Error(
      "Missing NEXT_PUBLIC_SUPABASE_URL or NEXT_PUBLIC_SUPABASE_ANON_KEY env var",
    );
  }

  return createBrowserClient(url, anonKey);
}
