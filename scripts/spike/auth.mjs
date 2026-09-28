#!/usr/bin/env node
// @ts-check
// Step 1 / B0 check (4): `getClaims()` verifies a JWT locally against the
// cached JWKS with asymmetric signing keys, with NO request to
// /auth/v1/user. Run via `npm run spike:auth` (loads .env.local if present).
//
// PASS/FAIL on stdout. Exits 2 with "SKIPPED" if local Supabase isn't
// reachable (e.g. Docker not installed yet) — this script never blocks on
// infra it can't see.
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { createClient } from "@supabase/supabase-js";

const repoRoot = fileURLToPath(new URL("../../", import.meta.url));

/** Thrown to short-circuit `main()` with a known outcome (never a bug). */
class SpikeOutcome extends Error {
  /**
   * @param {"SKIPPED" | "FAIL"} kind
   * @param {string} message
   */
  constructor(kind, message) {
    super(message);
    this.kind = kind;
  }
}

/**
 * @param {string} message
 * @returns {never}
 */
function skip(message) {
  throw new SpikeOutcome("SKIPPED", message);
}

/**
 * @param {string} message
 * @returns {never}
 */
function fail(message) {
  throw new SpikeOutcome("FAIL", message);
}

/**
 * Reads `supabase status -o env` output, if the CLI and a running local
 * stack are available. Never printed or logged — used only to fill in
 * missing env vars in-memory.
 * @returns {Record<string, string>}
 */
function readStatusEnv() {
  try {
    const out = execFileSync("npx", ["supabase", "status", "-o", "env"], {
      cwd: repoRoot,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 15_000,
    });
    /** @type {Record<string, string>} */
    const vars = {};
    for (const line of out.split(/\r?\n/)) {
      const match = line.match(/^([A-Z0-9_]+)="?(.*?)"?$/);
      if (match) vars[match[1]] = match[2];
    }
    return vars;
  } catch {
    return {};
  }
}

/**
 * @returns {Promise<{ jwksCalls: number, alg: string | undefined }>}
 */
async function main() {
  const fromStatus = readStatusEnv();

  const url = process.env.NEXT_PUBLIC_SUPABASE_URL ?? fromStatus.API_URL;
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? fromStatus.ANON_KEY;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY ?? fromStatus.SERVICE_ROLE_KEY;

  if (!url || !anonKey || !serviceRoleKey) {
    skip(
      "no local Supabase URL/keys found (run `supabase start`, or set NEXT_PUBLIC_SUPABASE_URL / NEXT_PUBLIC_SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY)",
    );
  }

  try {
    const res = await fetch(`${url}/auth/v1/health`, { headers: { apikey: anonKey } });
    if (!res.ok) throw new Error(`health check status ${res.status}`);
  } catch (err) {
    skip(`local Supabase not reachable at ${url} (${/** @type {Error} */ (err).message})`);
  }

  // Wrap fetch to observe exactly which requests getClaims() makes.
  /** @type {string[]} */
  const calls = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (input, init) => {
    const href =
      typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    calls.push(href);
    return originalFetch(input, init);
  };

  // No auto-refresh timers / storage for either client: this is a one-shot
  // script, not a long-lived session, and we don't want a dangling interval
  // to keep the process alive.
  const noPersist = { auth: { autoRefreshToken: false, persistSession: false } };
  const admin = createClient(url, serviceRoleKey, noPersist);
  /** @type {string | null} */
  let throwawayUserId = null;

  try {
    const email = `spike-${Date.now()}-${Math.random().toString(36).slice(2)}@example.com`;
    const password = `Sp1ke-${Math.random().toString(36).slice(2)}-Aa1!`;

    // Local dev has email confirmation ON (supabase/config.toml
    // [auth.email] enable_confirmations = true). Sign up + confirm via
    // Inbucket would couple this JWT-verification check to the mailer
    // pipeline, so provision an already-confirmed throwaway user directly.
    const created = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
    });
    if (created.error || !created.data.user) {
      fail(`admin.createUser failed: ${created.error?.message ?? "no user returned"}`);
    }
    throwawayUserId = created.data.user.id;

    const anon = createClient(url, anonKey, noPersist);
    const signIn = await anon.auth.signInWithPassword({ email, password });
    if (signIn.error) {
      fail(`signInWithPassword failed: ${signIn.error.message}`);
    }

    calls.length = 0; // only count requests made during getClaims() itself

    const claimsResult = await anon.auth.getClaims();
    if (claimsResult.error || !claimsResult.data) {
      fail(`getClaims failed: ${claimsResult.error?.message ?? "no data returned"}`);
    }
    const { data } = claimsResult;

    const userCalls = calls.filter((href) => href.includes("/auth/v1/user"));
    if (userCalls.length > 0) {
      fail(
        `getClaims() made ${userCalls.length} request(s) to /auth/v1/user; expected 0 (should verify the JWT locally)`,
      );
    }

    const jwksCalls = calls.filter((href) => href.includes("jwks"));
    if (jwksCalls.length > 1) {
      fail(`getClaims() made ${jwksCalls.length} JWKS requests; expected at most 1 (cached)`);
    }

    const alg = data.header?.alg;
    if (alg !== "ES256") {
      fail(`token header alg is "${alg}", expected "ES256" (asymmetric signing keys)`);
    }

    return { jwksCalls: jwksCalls.length, alg };
  } finally {
    globalThis.fetch = originalFetch;
    if (throwawayUserId) {
      try {
        await admin.auth.admin.deleteUser(throwawayUserId);
      } catch {
        // Best-effort cleanup; don't let it change the PASS/FAIL result.
      }
    }
  }
}

main()
  .then(({ jwksCalls, alg }) => {
    console.log(
      `PASS: getClaims() verified the JWT locally — 0 requests to /auth/v1/user, ${jwksCalls} JWKS request(s), alg=${alg}`,
    );
    process.exitCode = 0;
  })
  .catch((err) => {
    if (err instanceof SpikeOutcome) {
      console.log(`${err.kind}: ${err.message}`);
      process.exitCode = err.kind === "SKIPPED" ? 2 : 1;
      return;
    }
    console.log(`FAIL: ${err instanceof Error ? err.message : String(err)}`);
    process.exitCode = 1;
  });
