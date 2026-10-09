#!/usr/bin/env node
// @ts-check
// B2 check: through PostgREST with user B's real JWT, B cannot write any table, cannot update
// A's project, and cannot read A's private project. Run: `npm run check:rls` (local Supabase up).
// Creates two throwaway users and deletes them (cascading their rows) at the end.
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { createClient } from "@supabase/supabase-js";

const repoRoot = fileURLToPath(new URL("../../", import.meta.url));

/** @returns {Record<string, string>} values from `supabase status -o env` (never printed) */
function statusEnv() {
  const out = execFileSync("npx supabase status -o env", {
    cwd: repoRoot, encoding: "utf8", shell: true, stdio: ["ignore", "pipe", "ignore"], timeout: 30_000,
  });
  /** @type {Record<string, string>} */
  const env = {};
  for (const line of out.split(/\r?\n/)) {
    const m = line.match(/^([A-Z_]+)="?(.*?)"?$/);
    if (m) env[m[1]] = m[2];
  }
  return env;
}

const env = statusEnv();
const url = env.API_URL;
const anonKey = env.ANON_KEY;
const serviceKey = env.SERVICE_ROLE_KEY;
if (!url || !anonKey || !serviceKey) {
  console.log("SKIPPED: local Supabase is not running (npm run db:start)");
  process.exit(2);
}

const admin = createClient(url, serviceKey, { auth: { persistSession: false } });
const stamp = Date.now();
const password = "Passw0rd123";
/** @type {string[]} */
const created = [];
let failures = 0;

/** @param {boolean} ok @param {string} label */
function check(ok, label) {
  console.log(`${ok ? "PASS" : "FAIL"}  ${label}`);
  if (!ok) failures++;
}

/** @param {string} tag */
async function makeUser(tag) {
  const email = `rls-${tag}-${stamp}@example.com`;
  const { data, error } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (error) throw error;
  created.push(data.user.id);
  const client = createClient(url, anonKey, { auth: { persistSession: false } });
  const { error: signInError } = await client.auth.signInWithPassword({ email, password });
  if (signInError) throw signInError;
  return { id: data.user.id, client };
}

try {
  const a = await makeUser("a");
  const b = await makeUser("b");

  // Seed A's projects with the service role (no create_project RPC until B3+).
  const { data: projects, error: seedError } = await admin.from("projects").insert([
    { owner_id: a.id, title: "Public", type: "writing", visibility: "public", license: "cc_by" },
    { owner_id: a.id, title: "Secret", type: "code", visibility: "private", license: "mit" },
  ]).select("id, visibility");
  if (seedError) throw seedError;
  const pub = projects.find((p) => p.visibility === "public")?.id;
  const priv = projects.find((p) => p.visibility === "private")?.id;

  /** @type {[string, Record<string, unknown>][]} */
  const writes = ([
    ["projects", { owner_id: b.id, title: "x", type: "code", license: "mit" }],
    ["copies", { project_id: pub, author_id: b.id, project_owner_id: a.id, base_version_id: 1, head_version_id: 1 }],
    ["versions", { project_id: pub, author_id: b.id, file_paths: [], file_hashes: [] }],
    ["blobs", { hash: "\\x" + "00".repeat(32), size: 1 }],
    ["review_requests", { copy_id: 1, project_id: pub, owner_id: a.id, contributor_id: b.id, submitted_version_id: 1 }],
    ["request_events", { request_id: 1, actor_id: b.id, kind: "approved" }],
    ["main_history", { project_id: pub, version_id: 1, promoted_by: b.id }],
    ["notifications", { user_id: b.id, type: "x" }],
    ["profiles", { id: b.id }],
  ]);
  for (const [table, row] of writes) {
    const { error } = await b.client.from(table).insert(row);
    check(error?.code === "42501", `B cannot insert into ${table}`);
  }

  const upd = await b.client.from("projects").update({ title: "pwned" }).eq("id", pub).select();
  check(upd.error?.code === "42501", "B cannot update A's project");
  const del = await b.client.from("projects").delete().eq("id", pub).select();
  check(del.error?.code === "42501", "B cannot delete A's project");

  const readPriv = await b.client.from("projects").select("id").eq("id", priv);
  check(!readPriv.error && readPriv.data?.length === 0, "B cannot read A's private project");
  const readPub = await b.client.from("projects").select("id").eq("id", pub);
  check(!readPub.error && readPub.data?.length === 1, "B can read A's public project");
  const readOwn = await a.client.from("projects").select("id").in("id", [pub, priv]);
  check(!readOwn.error && readOwn.data?.length === 2, "A reads both own projects");
} catch (err) {
  console.log("FAIL  unexpected error:", err instanceof Error ? err.message : err);
  failures++;
} finally {
  for (const id of created) await admin.auth.admin.deleteUser(id);
}

console.log(failures ? `\n${failures} check(s) failed` : "\nAll RLS REST checks passed");
process.exit(failures ? 1 : 0);
