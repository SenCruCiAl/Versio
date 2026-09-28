"use server";
// @ts-check
import { z } from "zod";

// Next-only modules (`lib/supabase/server.js` -> `server-only` +
// `next/headers`, and `next/headers`/`next/navigation` themselves) are
// imported lazily, inside each action, instead of at module top-level.
//
// Reason: those modules cannot be loaded outside a Next/webpack runtime
// (`server-only` throws unconditionally on load; `next/*` subpaths fail to
// resolve under plain Node — see tests/auth.test.mjs). Validation-only
// paths (bad input) never reach the dynamic import, so this file stays
// importable — and its input validation unit-testable — under
// `node --test`, while still enforcing the same rules at runtime in Next.

/** @typedef {{ ok: true } | { ok: false, code: string, message: string }} ActionResult */

const USERNAME_RE = /^[a-z0-9_]{3,30}$/;
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

const usernameSchema = z.object({
  username: z.string().trim().toLowerCase().regex(USERNAME_RE),
});

const emailSchema = z.object({
  email: z.string().trim().toLowerCase().regex(EMAIL_RE),
  password: z.string().min(8),
});

const providerSchema = z.enum(["google", "github"]);

const KNOWN_RPC_ERROR_CODES = /** @type {const} */ ([
  "INVALID_USERNAME",
  "USERNAME_TAKEN",
  "NOT_AUTHENTICATED",
]);

/**
 * @param {string} code
 * @returns {string}
 */
function usernameMessage(code) {
  switch (code) {
    case "INVALID_USERNAME":
      return "Usernames are 3-30 characters: lowercase letters, digits, underscore.";
    case "USERNAME_TAKEN":
      return "That username is taken.";
    case "NOT_AUTHENTICATED":
      return "Sign in first.";
    default:
      return "Something went wrong. Try again.";
  }
}

/**
 * Maps the RPC's `RAISE ... MESSAGE 'X'` (SQLSTATE P0001) to a typed result.
 * @param {unknown} error
 * @returns {ActionResult}
 */
function mapSetUsernameRpcError(error) {
  const message =
    error && typeof (/** @type {{ message?: unknown }} */ (error).message) === "string"
      ? /** @type {{ message: string }} */ (error).message
      : "";
  const code = KNOWN_RPC_ERROR_CODES.find((known) => message.includes(known));
  if (code) {
    return { ok: false, code, message: usernameMessage(code) };
  }
  return { ok: false, code: "UNKNOWN", message: "Something went wrong. Try again." };
}

/**
 * Sets the caller's username. Validates locally first so bad input never
 * reaches the database. `p_actor` for the RPC comes only from the caller's
 * own verified session (`requireUser`) — never from `input`.
 *
 * @param {{ username: string }} input
 * @returns {Promise<ActionResult>}
 */
export async function setUsername(input) {
  const parsed = usernameSchema.safeParse(input);
  if (!parsed.success) {
    return { ok: false, code: "INVALID_USERNAME", message: usernameMessage("INVALID_USERNAME") };
  }

  const { requireUser, AuthError } = await import("../../lib/supabase/server.js");

  /** @type {import("@supabase/supabase-js").SupabaseClient} */
  let supabase;
  try {
    ({ supabase } = await requireUser());
  } catch (err) {
    if (err instanceof AuthError) {
      return { ok: false, code: err.code, message: usernameMessage(err.code) };
    }
    throw err;
  }

  const { error } = await supabase.rpc("set_username", { p_username: parsed.data.username });
  if (error) {
    return mapSetUsernameRpcError(error);
  }
  return { ok: true };
}

/**
 * Resolves the app origin for auth redirects — needed because
 * `redirectTo`/`emailRedirectTo` must be absolute URLs. Uses
 * NEXT_PUBLIC_SITE_URL when set (always in production); falls back to the
 * request's host headers for local dev. Host headers are client-controlled,
 * so Supabase's `additional_redirect_urls` allow-list (supabase/config.toml)
 * remains the security boundary.
 * @returns {Promise<string>}
 */
async function currentOrigin() {
  const siteUrl = process.env.NEXT_PUBLIC_SITE_URL;
  if (siteUrl) return siteUrl.replace(/\/+$/, "");
  const { headers } = await import("next/headers");
  const h = await headers();
  const host = h.get("x-forwarded-host") ?? h.get("host");
  const proto = h.get("x-forwarded-proto") ?? "http";
  return `${proto}://${host}`;
}

/**
 * Starts an OAuth sign-in and redirects to the provider.
 * @param {"google" | "github"} provider
 * @returns {Promise<ActionResult>}
 */
export async function signInWithOAuth(provider) {
  const parsedProvider = providerSchema.safeParse(provider);
  if (!parsedProvider.success) {
    return { ok: false, code: "INVALID_PROVIDER", message: "Unsupported sign-in provider." };
  }

  const { createClient } = await import("../../lib/supabase/server.js");
  const origin = await currentOrigin();
  const supabase = await createClient();

  const { data, error } = await supabase.auth.signInWithOAuth({
    provider: parsedProvider.data,
    options: { redirectTo: `${origin}/auth/callback` },
  });

  if (error || !data?.url) {
    return { ok: false, code: "OAUTH_ERROR", message: "Could not start sign-in. Try again." };
  }

  const { redirect } = await import("next/navigation");
  redirect(data.url);
  // Unreachable: redirect() always throws NEXT_REDIRECT. Keeps the return
  // type honest for callers/tests that don't go through Next's redirect
  // handling.
  return { ok: true };
}

/**
 * @param {{ email: string, password: string }} input
 * @returns {Promise<ActionResult>}
 */
export async function signUpWithEmail(input) {
  const parsed = emailSchema.safeParse(input);
  if (!parsed.success) {
    return {
      ok: false,
      code: "INVALID_INPUT",
      message: "Enter a valid email and a password of at least 8 characters.",
    };
  }

  const { createClient } = await import("../../lib/supabase/server.js");
  const origin = await currentOrigin();
  const supabase = await createClient();

  const { error } = await supabase.auth.signUp({
    email: parsed.data.email,
    password: parsed.data.password,
    options: { emailRedirectTo: `${origin}/auth/callback` },
  });

  if (error) {
    return { ok: false, code: "SIGNUP_ERROR", message: "Could not sign up. Try again." };
  }
  return { ok: true };
}

/**
 * @param {{ email: string, password: string }} input
 * @returns {Promise<ActionResult>}
 */
export async function signInWithEmail(input) {
  const parsed = emailSchema.safeParse(input);
  if (!parsed.success) {
    return { ok: false, code: "INVALID_INPUT", message: "Enter a valid email and password." };
  }

  const { createClient } = await import("../../lib/supabase/server.js");
  const supabase = await createClient();

  const { error } = await supabase.auth.signInWithPassword(parsed.data);
  if (error) {
    return { ok: false, code: "SIGNIN_ERROR", message: "Invalid email or password." };
  }
  return { ok: true };
}

/**
 * @returns {Promise<ActionResult>}
 */
export async function signOut() {
  const { createClient } = await import("../../lib/supabase/server.js");
  const supabase = await createClient();
  await supabase.auth.signOut();
  return { ok: true };
}
