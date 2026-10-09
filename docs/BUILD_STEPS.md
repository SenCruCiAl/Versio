# Versio Backend: Build Steps

Living guide for building the backend described in [`BACKEND_PLAN.md`](../BACKEND_PLAN.md). Updated at the end of every step, in the same commit as that step's work.

## Rules

- **Permission gate:** no step starts without the owner's explicit "go". After each step: push, summarize, stop.
- **Branch:** all work goes to `backend`. `main` is never touched.
- **Secrets:** real keys live only in `.env.local` (git-ignored), entered by the owner, never pasted in chat or printed by scripts. `.env.example` has names only. A secret scan runs on the staged diff before every push.
- **Language:** JavaScript ES modules with `// @ts-check` + JSDoc (`jsconfig.json` has `checkJs`). The frontend owner has UI/UX and frontend access only for now; backend code is TypeScript-ready without being TypeScript.
- **Agents:** `storage-dev` and `upload-dev` (`.claude/agents/`, Sonnet) run only in the steps that need them, each inside its own files. They coordinate through `docs/storage-upload-contract.md` and the handoff log below.

---

## Step 0: Repo setup and plan (done, `228c46f`)

| Who | What |
|---|---|
| Main session | Cloned the repo, created `backend`. Added the skeleton (`supabase/migrations`, `supabase/tests`, `lib/storage`, `lib/supabase`, `app/actions`, `docs`), `jsconfig.json`, `lib/limits.js` (25 MB/file, 500 MB/user, 1000 files/version, URL lifetimes, staging expiry), `.gitignore`, and `.env.example`. Wrote `BACKEND_PLAN.md` v2 (JavaScript, efficiency changes E1–E8, F11 upload-leak fix). Secret scan clean; pushed. |
| storage-dev | Defined only; has not run. Brief: R2 adapter (`presignPut/presignGet/head/copy/remove`), key layout `staging/<uid>/<hash>` → `objects/<hash>`, signing rules, lifecycle, `blobs`, downloads, takedown; writes the storage/upload contract first. |
| upload-dev | Defined only; has not run. Brief: browser hashing, `prepareUpload`, `commitVersion`, `commit_version` RPC (service_role only), quota, delta manifests; reuse without upload only from the parent manifest; `p_actor` only from verified claims. |

Carried decisions: PRD collaboration model (locked main, Make my copy, request to publish), R2 for bytes, required license, RPC-only writes, no scheduled jobs.

---

## Step 1: B0 setup and checks (checks 4–5 pass; R2 checks 1–3 waiting on bucket credentials)

**Goal:** local Supabase running, R2 bucket ready, and the five risky assumptions checked before any real code depends on them.

| File | Who | Change |
|---|---|---|
| `package.json` | main | private, ES modules; AWS S3 SDK + presigner, supabase-js, @supabase/ssr, next 16, react 19, zod, server-only; dev: supabase CLI, typescript, @types/node. Scripts `spike:r2`, `spike:auth`, `r2:config`, `db:*`, `test`, `typecheck` |
| `supabase/config.toml` | main | `supabase init`; email confirmations on, 8-char passwords (letters+digits), local callback URLs, ES256 signing keys (`supabase/signing_keys.json`, git-ignored), GitHub/Google providers reading `env(...)` (disabled until keys exist) |
| `jsconfig.json` | main | TypeScript 7: dropped `baseUrl`, added `types: ["node"]` |
| `scripts/spike/r2.mjs` | storage-dev | checks 1–4: signed checksum (wrong bytes rejected, right bytes accepted), CopyObject staging → objects + HEAD (missing source fails), `staging/` lifecycle set and read back, presigned GET stable within the hour and downloadable. Cleans up; exits 2 if credentials are missing; never prints secrets or signed query strings |
| `scripts/r2-apply-config.mjs` | storage-dev | idempotent lifecycle + CORS apply and read-back (`npm run r2:config`) |
| `docs/r2-setup.md` | storage-dev | bucket, scoped token, env names, dashboard fallback |
| `scripts/spike/auth.mjs` | upload-dev | check 4: `getClaims()` makes no `/auth/v1/user` call (at most one JWKS fetch) and the token is ES256 |
| `scripts/spike/broadcast.sql` | main | check 5: `realtime.send()` to a private channel |

**Verified now:** `npm run typecheck` clean; `node --check` on all scripts; both spikes exit 2 (SKIPPED) with no credentials, printing only missing variable names.
**Ran 2026-09-28 (Docker + local Supabase):** `spike:auth` PASS (0 `/auth/v1/user` calls, 1 JWKS fetch, ES256); `broadcast.sql` PASS. Results in `BACKEND_PLAN.md` §9.
**Still to run (owner):** R2 bucket and token per `docs/r2-setup.md`, then `npm run r2:config` and `npm run spike:r2` (checks 1–3).

---

## Step 2: B1 auth (email auth verified; Google/GitHub waiting on OAuth apps)

| File | Who | Change |
|---|---|---|
| `supabase/migrations/0001_schema.sql` | main | `profiles` (B2 extends this file) |
| `supabase/migrations/0002_rls.sql` | main | profiles: RLS on, SELECT for all, writes revoked from anon/authenticated |
| `supabase/migrations/0004_auth_trigger.sql` | main | `handle_new_user` trigger (one profile per auth user); `set_username` RPC (NOT_AUTHENTICATED / INVALID_USERNAME / USERNAME_TAKEN), authenticated only |
| `supabase/tests/auth_profiles.test.sql` | main | pgTAP: 12 checks (profile on signup, name rules, case-insensitive uniqueness, no direct writes, anon blocked) |
| `lib/supabase/server.js`, `claims.js` | upload-dev | per-request server client, `getClaims`, `requireUser()` → `{supabase, uid, claims}` or `UNAUTHENTICATED` |
| `lib/supabase/admin.js`, `client.js` | upload-dev | service-role client (server-only); browser client |
| `proxy.js` | upload-dev | Next 16 session refresh, narrow matcher |
| `app/auth/callback/route.js` | upload-dev | code exchange, relative-only `next` redirect |
| `app/actions/auth.js` | upload-dev | `setUsername`, `signInWithOAuth`, email sign-up/in, sign-out (zod). Redirect origin from `NEXT_PUBLIC_SITE_URL` when set |
| `tests/auth.test.mjs` | upload-dev | 6 unit tests (`npm test`) |

**Verified now:** `npm test` 6/6 pass; migrations applied to an in-memory Postgres (PGlite with a stub `auth` schema): trigger creates one profile, `set_username` accepts/lower-cases valid names, rejects short/invalid/duplicate names, direct UPDATE/INSERT denied, anon cannot call the RPC but can read profiles.
**Ran 2026-09-28:** `db:reset` applied all migrations; `db:test` 12/12 pgTAP pass; real email signup through Supabase Auth → exactly 1 profile, `set_username` works via the API, direct profile UPDATE denied (42501), deleting the user removes the profile.
**Still to run (owner):** GitHub and Google OAuth apps (callback `http://127.0.0.1:54321/auth/v1/callback`), IDs/secrets in `supabase/.env`, set `enabled = true`; sign in once with each provider and confirm exactly one profile each.
**Frontend needs:** pages for `/auth/auth-error` and username onboarding.

---

## Step 3: B2 schema and RLS (done)

| File | Who | Change |
|---|---|---|
| `supabase/migrations/0001_schema.sql` | main | enums (project_type, visibility, license_type, copy_state, request_status, request_event_kind); projects, copies, versions, blobs, review_requests, request_events, main_history, notifications; circular FKs added after `versions`; CHECKs (manifest lengths, ≤1000 files, 32-byte hash, published_at iff published, no copy of own project); all §5 indexes + one-open-request-per-copy unique index |
| `supabase/migrations/0002_rls.sql` | main | RLS on all 9 tables; INSERT/UPDATE/DELETE/TRUNCATE revoked from anon/authenticated (and for future tables via default privileges); SELECT on blobs revoked; `is_project_readable` / `is_copy_readable` helpers; SELECT policies per §7; `realtime.messages` policy for private channel `user:<uid>` |
| `supabase/tests/schema_rls.test.sql` | main | pgTAP, 27 checks |
| `scripts/spike/rls-rest.mjs` (`npm run check:rls`) | main | same rules through real PostgREST with two real users; cleans up after itself |
| `BACKEND_PLAN.md` | main | proxy.js naming, getDownloadUrls blob lookup via service role, main-line timeline = `main_history`, enum values, B2 results, open questions 4–6 |

**Ran 2026-10-07:** `db:reset` clean; `db:test` **39/39**; `check:rls` **14/14**; `typecheck` clean; `npm test` 6/6.

**Also done ahead of Steps 4–6 (database side only, same day):** `0003_rpc.sql` (projects, `commit_version`, restore, make_copy) and `0005_requests.sql` (requests, review, promote, notifications) with pgTAP `rpc_projects` (24) and `rpc_requests` (22). `db:test` **85/85**. Server actions, R2 integration, read functions and takedown are still to do; see `BACKEND_PLAN.md` "RPC results".

---

## Step 4: B3 storage and upload pipeline (pending)

**Owner:** **both agents.** Order: storage-dev writes `docs/storage-upload-contract.md` → upload-dev reviews it (questions go in the handoff log) → both implement in their own files → main session integrates.

| storage-dev | upload-dev |
|---|---|
| `lib/storage/index.js`, `lib/storage/r2.js`, `getDownloadUrls` in `app/actions/upload.js` (download part) | `lib/hash.js` (Web Worker), `prepareUpload`, `commitVersion`, `commit_version` in `0003_rpc.sql` |

**Done when:** same file twice → one object, one blob row, quota charged once; wrong hash rejected; B cannot commit a hash without their own staging upload even when A's object exists; 1 changed file in a 200-file project → 1 PUT + 1 `versions` row; stale parent → `STALE_PARENT`; oversize and over-quota rejected.

---

## Step 5: B4–B5 versions, copies, requests (pending)

**Owner:** main session.
**Files:** `restore_version`, `make_copy`, `submit/resubmit/review_request` in `0003_rpc.sql`; `0005_read_functions.sql`; `app/actions/projects.js`, `copies.js`, `requests.js`.
**Done when:** restore test (3 saves + restore → v4 = v1 manifest); two-account flow: copy → submit → changes → resubmit → approve (published, credited); reject run keeps the copy private.

---

## Step 6: B6–B7 promote and notifications (pending)

**Owner:** main session.
**Files:** `promote_copy`, `mark_notifications_read`, Broadcast calls in RPCs; `app/actions/notifications.js`.
**Done when:** promote keeps old main in history; stale copy raises `STALE_COPY` until acknowledged; each transition sends exactly one live notification to the right user. PRD Phase 3 scripted test passes.

---

## Step 7: B8 takedown (pending)

**Owner:** storage-dev.
**Files:** `takedown_blob` RPC, blocked check in `getDownloadUrls`, orphan removal after version deletion.
**Done when:** a blocked blob refuses download from every project; deleting a version removes its orphaned R2 objects.

---

## Agent handoff log

| Date | From → To | Question / request | Resolution |
|---|---|---|---|
| 2026-09-28 | storage-dev → upload-dev | `x-amz-checksum-sha256` is base64 of the raw SHA-256 digest, not hex (keys stay lowercase hex). The presigner hoists it into the URL query, so the browser must not set it again as a header. | Goes into `docs/storage-upload-contract.md` in Step 4 |
| 2026-09-28 | upload-dev → main | `lib/supabase/admin.js` exports the cached service-role `createClient()` for `commit_version` and takedown cleanup | Noted for Steps 4 and 7 |
