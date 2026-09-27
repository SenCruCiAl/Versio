# Versio Backend: Build Steps

Living guide for building the backend described in [`BACKEND_PLAN.md`](../BACKEND_PLAN.md). Updated at the end of every step, in the same commit as that step's work.

## Rules

- **Permission gate:** no step starts without the owner's explicit "go". After each step: push, summarize, stop.
- **Branch:** all work goes to `backend`. `main` is never touched.
- **Secrets:** real keys live only in `.env.local` (git-ignored), entered by the owner, never pasted in chat or printed by scripts. `.env.example` has names only. A secret scan runs on the staged diff before every push.
- **Language:** JavaScript ES modules with `// @ts-check` + JSDoc (`jsconfig.json` has `checkJs`). The frontend owner has UI/UX and frontend access only for now; backend code is TypeScript-ready without being TypeScript.
- **Agents:** `storage-dev` and `upload-dev` (`.claude/agents/`, Sonnet) run only in the steps that need them, each inside its own files. They coordinate through `docs/storage-upload-contract.md` and the handoff log below.

---

## Step 0: Repo setup and plan (done, `938ccc7`)

| Who | What |
|---|---|
| Main session | Cloned the repo, created `backend`. Added the skeleton (`supabase/migrations`, `supabase/tests`, `lib/storage`, `lib/supabase`, `app/actions`, `docs`), `jsconfig.json`, `lib/limits.js` (25 MB/file, 500 MB/user, 1000 files/version, URL lifetimes, staging expiry), `.gitignore`, and `.env.example`. Wrote `BACKEND_PLAN.md` v2 (JavaScript, efficiency changes E1–E8, F11 upload-leak fix). Secret scan clean; pushed. |
| storage-dev | Defined only; has not run. Brief: R2 adapter (`presignPut/presignGet/head/copy/remove`), key layout `staging/<uid>/<hash>` → `objects/<hash>`, signing rules, lifecycle, `blobs`, downloads, takedown; writes the storage/upload contract first. |
| upload-dev | Defined only; has not run. Brief: browser hashing, `prepareUpload`, `commitVersion`, `commit_version` RPC (service_role only), quota, delta manifests; reuse without upload only from the parent manifest; `p_actor` only from verified claims. |

Carried decisions: PRD collaboration model (locked main, Make my copy, request to publish), R2 for bytes, required license, RPC-only writes, no scheduled jobs.

---

## Step 1: B0 setup and checks (pending)

**Goal:** local Supabase running, R2 bucket ready, and the five risky assumptions checked before any real code depends on them.
**Owner:** storage-dev (R2 checks, R2 setup doc) + main session. upload-dev does not run.
**Owner prerequisites:** Docker Desktop, Supabase CLI, R2 bucket `versio-dev` + API token scoped to it, keys in `.env.local`.

| File | Who | Change |
|---|---|---|
| `package.json` | main | private, `"type":"module"`; `@aws-sdk/client-s3`, `@aws-sdk/s3-request-presigner`, `@supabase/supabase-js`; scripts `spike:r2`, `spike:auth` |
| `supabase/config.toml`, `supabase/seed.sql` | main | from `supabase init` (no secrets) |
| `scripts/spike/r2.mjs` | storage-dev | (1) signed checksum: wrong bytes fail, right bytes pass; (2) CopyObject staging → objects + HEAD; (3) `staging/` 1-day lifecycle set via API and read back; (4) presigned GET stable within the hour |
| `scripts/spike/auth.mjs` | main | `getClaims()` verifies locally with no Auth network call |
| `scripts/spike/broadcast.sql` | main | `realtime.send()` to a private channel |
| `docs/r2-setup.md` | storage-dev | bucket, scoped token, CORS (PUT/GET + checksum header), lifecycle |
| `BACKEND_PLAN.md` §9 | main | results; fallback for any failing check |

**Done when:** all five checks report pass/fail with output shown to the owner; fallbacks recorded; `.env.local` untracked; secret scan clean.

---

## Step 2: B1 auth (pending)

**Owner:** main session.
**Owner prerequisites:** Google and GitHub OAuth apps (client IDs/secrets into `.env.local` / Supabase dashboard).
**Files:** `lib/supabase/server.js`, `lib/supabase/admin.js`, `middleware.js` (narrow matcher), `supabase/migrations/0004_auth_trigger.sql`, `set_username` RPC.
**Done when:** each provider creates exactly one profile; server actions reject calls without valid claims.

---

## Step 3: B2 schema and RLS (pending)

**Owner:** main session.
**Files:** `supabase/migrations/0001_schema.sql`, `0002_rls.sql`, `supabase/tests/*.sql` (pgTAP).
**Done when:** with user B's JWT against PostgREST, B cannot write any table, cannot update A's project, and cannot read A's private project or private copy.

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
| | | | |
