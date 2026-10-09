// @ts-check
// OAuth and email-confirmation callback: exchanges the `code` query param
// for a session (writes the auth cookies), then redirects onward.
import { NextResponse } from "next/server";
import { createClient } from "../../../lib/supabase/server.js";

/**
 * Only relative, same-app paths are allowed as a post-auth redirect target
 * (no open redirect via a crafted `next` param).
 *
 * @param {string | null} next
 * @returns {string}
 */
function safeNext(next) {
  if (
    typeof next === "string" &&
    next.startsWith("/") &&
    !next.startsWith("//") &&
    !next.startsWith("/\\")
  ) {
    return next;
  }
  return "/";
}

/**
 * @param {import("next/server").NextRequest} request
 */
export async function GET(request) {
  const code = request.nextUrl.searchParams.get("code");
  const next = safeNext(request.nextUrl.searchParams.get("next"));
  const origin = request.nextUrl.origin;

  if (code) {
    const supabase = await createClient();
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    if (!error) {
      return NextResponse.redirect(`${origin}${next}`);
    }
  }

  return NextResponse.redirect(`${origin}/auth/auth-error`);
}
