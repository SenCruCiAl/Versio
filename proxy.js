// @ts-check
// Next 16 renamed `middleware.js` to `proxy.js` (export `proxy`, not
// `middleware`). Refreshes the Supabase session cookie on every navigation
// so Server Components always see a valid (or correctly expired) session.
import { createServerClient } from "@supabase/ssr";
import { NextResponse } from "next/server";

/**
 * @param {import("next/server").NextRequest} request
 * @returns {Promise<import("next/server").NextResponse>}
 */
export async function proxy(request) {
  let response = NextResponse.next({ request });

  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

  if (!supabaseUrl || !supabaseAnonKey) {
    // Misconfigured env: let the request through rather than 500 every page.
    // Server actions still enforce auth independently via requireUser().
    return response;
  }

  const supabase = createServerClient(supabaseUrl, supabaseAnonKey, {
    cookies: {
      getAll() {
        return request.cookies.getAll();
      },
      setAll(cookiesToSet) {
        for (const { name, value } of cookiesToSet) {
          request.cookies.set(name, value);
        }
        response = NextResponse.next({ request });
        for (const { name, value, options } of cookiesToSet) {
          response.cookies.set(name, value, options);
        }
      },
    },
  });

  // Must run before `response` is returned: this both verifies the JWT
  // (E6: local verification, no Auth-server round trip with asymmetric
  // signing keys) and refreshes it when it's close to expiry, writing the
  // new cookies via setAll above.
  await supabase.auth.getClaims();

  return response;
}

export const config = {
  matcher: [
    // Skip Next internals, favicon, and static image files. Everything else
    // (including Server Function/RPC POSTs) goes through the proxy so the
    // session cookie stays fresh.
    "/((?!_next/static|_next/image|favicon\\.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico|bmp|avif)$).*)",
  ],
};
