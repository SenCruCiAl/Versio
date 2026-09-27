# Versio: Backend Plan (Auth, Storage, Core Functionality), v2

**Scope:** authentication/authorization, file storage, and the P0 core flow (projects, versions, "Make my copy", request to publish, review, promote, notifications).
**Out of scope for now:** diffs (P1), previews/viewers, explore/search/stars, landing page, deploy.
**Sources:** `PRD.md` is the source of truth for product behavior. `PROJECT_SPEC.md` fills gaps (R2, limits, quotas, license, storage abstraction).
**Language:** **JavaScript** (ES modules, `// @ts-check` + JSDoc types). The frontend owner currently has UI/UX and frontend access only; the backend is written so a later move to TypeScript is a rename plus type cleanup, not a rewrite.

---

## Changes from v1

| # | Change | Effect |
|---|---|---|
| E1 | Saves send a **delta** from the parent; reuse without upload only for hashes in the parent manifest | 1 changed file in a 200-file project = 1 upload, 1 RPC, 1 row (was ~200 reuse RPCs + 200 manifest rows) |
| E2 | Uploads go to `staging/<uid>/<hash>`; commit copies/verifies server-side; R2 lifecycle deletes staging after 1 day | 2 calls per save instead of 3; no `upload_reservations`; fixes F11 |
| E3 | Manifest stored in the `versions` row as arrays; hashes are 32-byte `bytea`; identity IDs for internal tables | Roughly 3× smaller manifests; one-row version loads; `version_files` table removed |
| E4 | `copies.state` + `copies.project_owner_id` | Copy RLS is three column checks, no subquery |
| E5 | One SECURITY INVOKER read function per screen; keyset pagination; batched, hour-stable download URLs | Fewer round trips, browser cache hits, less egress |
| E6 | `getClaims()` (local JWT verify) and a narrow middleware matcher | No Auth-server call per request |
| E7 | Notifications via Realtime Broadcast (`realtime.send`) | No per-subscriber RLS evaluation of `postgres_changes` |
| E8 | No scheduled jobs | Nothing breaks while the free Supabase project is paused |

---

## 0. Step 0 audit result

The repo contains only `PRD.md` and a README. No code, schema, auth, or upload code; nothing in Python to port. Everything is "build new". This section replaces `AUDIT.md`.

---

## 1. Decisions between the two documents

| Topic | Decision | Why |
|---|---|---|
| Language | **JavaScript** (JSDoc + `checkJs`) | Owner decision. `supabase gen types` output can still be consumed via JSDoc `import()` types. |
| File storage | **Cloudflare R2** | 10 GB free, zero egress; Supabase Storage (1 GB) is the PRD's own "first scaling wall". |
| Fork model | **PRD model** (copy inside the owner's project, owner approves publishing) | Built around the locked-main rule. |
| License | **Required** on every project | See F7. |
| Vocabulary | UI-only | Frontend decides. |

---

## 2. Flaws in the PRD (fixed by this plan)

**F1. Contributors can publish themselves.** An insert policy checking only `author_id` leaves `status` free. **Fix:** no direct client writes; all writes via RPCs (§6).

**F2. "Only owner updates review_requests" vs "contributor resubmits".** **Fix:** separate `submit/resubmit/review` RPCs with their own actor checks.

**F3. Request/version model inconsistent** (`version_id unique` vs "same request continues"; status in two places). **Fix:** `copies` table; versions immutable with no status.

**F4. No multi-statement transactions from supabase-js.** **Fix:** each multi-row operation is one Postgres function.

**F5. Client hash trusted blindly (dedup poisoning).** **Fix:** presigned PUT signs `x-amz-checksum-sha256`; R2 rejects mismatched bytes.

**F6. Dedup leaks private files / existence oracle.** **Fix (v2):** a hash may be referenced without upload **only if it is in the parent manifest** (which the caller can already read). Every other hash must be uploaded by the caller to their own staging key. No endpoint reveals whether a hash exists.

**F7. No license.** **Fix:** required `license`; ToS clause permitting private copies of public projects; "All rights reserved" disables Make my copy.

**F8. `diff_cache jsonb` fills the 500 MB DB.** **Fix:** diffs stored in R2 keyed by manifest pair; only a key in Postgres (P1).

**F9. Shared blobs vs takedown.** **Fix:** `blobs.blocked_at`; download refuses blocked blobs everywhere.

**F10. Promoting a stale copy discards newer work.** **Fix:** `promote_copy(..., acknowledge_stale)` raises `STALE_COPY` unless acknowledged.

**F11 (new). v1 finalize-by-HEAD leak.** v1 verified uploads by HEAD on `objects/<hash>`. If A already had private blob H, B could request an upload, skip it, and finalize: HEAD succeeds on A's object, and B gains access. **Fix:** each user uploads to `staging/<uid>/<hash>`; commit verifies *that* key (E2).

---

## 3. Architecture

```
Browser ──(supabase-js, anon key, user JWT)──▶ Supabase Postgres  (SELECT via RLS + INVOKER read fns; writes via RPC)
   │                                             ▲
   │──(Next.js server actions)──────────────────┘  (user JWT; service role ONLY for commit_version + takedown cleanup)
   │
   └──(presigned PUT/GET, direct)──▶ Cloudflare R2  (private bucket: staging/<uid>/<hash>, objects/<hash>)
```

Rules:
1. **Clients never write tables directly.** `INSERT/UPDATE/DELETE` revoked from `anon` and `authenticated`.
2. **All writes are RPCs** (`SECURITY DEFINER`, `set search_path = ''`, actor checked first). All use `auth.uid()` except `commit_version`, which is granted to `service_role` only and receives `p_actor` from verified JWT claims (it must trust the server's R2 checks).
3. **File bytes never pass through Vercel** (4.5 MB body cap). Presigned URLs only.
4. **Secrets** (service-role key, R2 keys) only in server env; modules that read them `import 'server-only'`.
5. **Storage abstraction:** `lib/storage/index.js` exposes `presignPut`, `presignGet`, `head`, `copy`, `remove`; `lib/storage/r2.js` implements them. Contract in `docs/storage-upload-contract.md`.
6. **Database access only via supabase-js/PostgREST.** No direct Postgres connections from Vercel; if ever needed, use the Supavisor transaction pooler (port 6543).

---

## 4. Auth and storage

### 4.1 Authentication (Supabase Auth)
- Providers: email + password (confirmation on), Google, GitHub.
- `@supabase/ssr` cookie sessions; `middleware.js` refreshes the session. Matcher excludes `_next/static`, `_next/image`, `favicon.ico`, and image files.
- **Identify users with `supabase.auth.getClaims()`** with asymmetric JWT signing keys enabled: verified locally against cached JWKS, no Auth-server round trip. Never `getSession()` on the server.
- Trigger on `auth.users` insert creates `profiles(id)` with `username = null`; onboarding calls `set_username`. Every write RPC requires a username.

### 4.2 Authorization model

| Action | Who | Enforced by |
|---|---|---|
| Read public project, main line, published copies | Anyone | RLS |
| Read private project | Owner | RLS |
| Read a copy's versions | Copy author; project owner while `state = 'in_review'` | RLS |
| Create project, save on main, restore, edit metadata | Owner | RPC |
| Make my copy, save on copy | User with username; public project; license allows | RPC |
| Submit / resubmit request | Copy author | RPC |
| Approve / ask for changes / reject | Project owner | RPC |
| Promote copy to main | Owner; copy published | RPC |
| Read / mark notifications | Notified user | RLS + RPC |

### 4.3 Upload and save pipeline (E1 + E2)

Limits in `lib/limits.js`: 25 MB/file, 500 MB/user, 1000 files/version.

```
1. Client: editor tracks touched files. Hash only those (crypto.subtle.digest in a Web Worker).
2. Client → server action prepareUpload([{hash, size, path}])          (NO database call)
     a. size ≤ MAX_FILE_BYTES, count ≤ MAX_FILES_PER_VERSION
     b. quota pre-check against the storage_used the client already has
     c. presigned PUT for staging/<uid>/<hash>, signing Content-Length + x-amz-checksum-sha256, 10 min
   Upload starts on drop, while the user types the note.
3. Client PUTs bytes to R2. R2 rejects bytes that don't match the hash (F5).
4. Client → server action commitVersion({project_id, copy_id, parent_id, note, upserts:[{path,hash,size}], deletes:[path]})
     a. uid from getClaims()
     b. for each upsert hash NOT in the parent manifest (parent read with the user's client, so RLS applies):
          blob exists     → head(staging/<uid>/<hash>)      proves possession
          blob new        → copy(staging/<uid>/<hash> → objects/<hash>)   fails if never uploaded
        size taken from R2, not from the client
     c. ONE RPC commit_version(p_actor = uid, ..., verified [{hash,size}]) via service role, one transaction:
          - actor rules: owner if copy_id null, else copy author; copy not in_review/published
          - every upsert hash ∈ parent manifest ∪ verified set, else raise
          - insert new blobs (on conflict do nothing); new_bytes = sizes of rows actually inserted
          - update profiles set storage_used = storage_used + new_bytes
              where id = p_actor and storage_used + new_bytes <= quota   → 0 rows: QUOTA_EXCEEDED
          - new manifest = parent − deletes − upserted paths + upserts, sorted by path
          - insert versions row with file_paths[] / file_hashes[]
          - advance pointer optimistically:
              main: update projects set main_version_id = new where id = p and main_version_id = parent
              copy: update copies set head_version_id = new where id = c and head_version_id = parent
              0 rows → STALE_PARENT
          - main: insert main_history
5. R2 lifecycle rule deletes staging/ after 1 day. Abandoned uploads need no cleanup code.
```

Paste-into-editor text uses the same pipeline (UTF-8 bytes → hash → upload).
Quota is charged to the user who registers a *new* blob; reuse is free.

### 4.4 Downloads (E5)
- `getDownloadUrls(version_id)`: one RLS-checked read of the version's manifest joined to `blobs` (invisible version → nothing returned), skip/flag `blocked_at` blobs, presign all GETs locally.
- GETs are signed at the start of the current hour and valid 2 h, with `response-cache-control: private, max-age=3600, immutable`. The same file gets the same URL within the hour, so the browser caches it.
- `response-content-disposition: attachment` for HTML, SVG and anything not allow-listed (stored-XSS guard).

### 4.5 Cleanup and takedown (E8)
- No scheduled jobs. Staging is cleaned by the R2 lifecycle rule.
- Blobs become unreferenced only when versions are deleted (takedown / account deletion). Those RPCs return the orphaned hashes in the same transaction, and the server action removes the R2 objects.
- Takedown: admin RPC sets `blobs.blocked_at`; downloads refuse it everywhere at once.

---

## 5. Data model (E3, E4)

```sql
profiles        id uuid pk → auth.users(id) on delete cascade,
                username citext unique null,
                display_name text, avatar_url text, tags text[] default '{}',
                storage_used bigint not null default 0,
                created_at timestamptz default now()

projects        id uuid pk default gen_random_uuid(),
                owner_id uuid → profiles, title text not null, description text,
                type project_type (writing|code|cad),
                visibility visibility (public|private),
                license license_type not null,
                main_version_id bigint → versions null,     -- null only before first save
                created_at, updated_at

copies          id bigint generated always as identity pk,
                project_id → projects, author_id → profiles,
                project_owner_id uuid,                     -- denormalized for RLS (E4)
                state copy_state (private|in_review|published) default 'private',
                base_version_id → versions,
                head_version_id → versions,
                published_at timestamptz null,
                created_at

versions        id bigint generated always as identity pk,  -- time-ordered: order by id desc
                project_id → projects,
                copy_id → copies null,                     -- null = main line
                parent_id → versions null,
                author_id → profiles, note text,
                file_paths text[] not null,                -- sorted, same length as file_hashes
                file_hashes bytea[] not null,
                created_at
                -- immutable, no status column

blobs           hash bytea pk check (octet_length(hash) = 32),
                size bigint not null, mime text,
                uploaded_by → profiles,
                blocked_at timestamptz null,
                created_at
                -- R2 key derived: 'objects/' || encode(hash,'hex')

review_requests id bigint identity pk, copy_id → copies,
                project_id, owner_id, contributor_id,
                submitted_version_id → versions,
                status request_status (pending|changes_requested|approved|rejected),
                created_at, updated_at, resolved_at
                unique index on (copy_id) where status in ('pending','changes_requested')

request_events  id bigint identity pk, request_id, actor_id,
                kind (submitted|changes_requested|resubmitted|approved|rejected),
                version_id null, comment text null, created_at

main_history    id bigint identity pk, project_id, version_id, promoted_by, from_copy_id null, created_at

notifications   id bigint identity pk, user_id, type, ref_id text, payload jsonb,
                read bool default false, created_at
```

**State lives in:** copy visibility and review stage → `copies.state`, updated in the same RPC as `review_requests.status` (the history). Current main → `projects.main_version_id`.

**Indexes:**
`review_requests(owner_id, status, id desc)`, `review_requests(contributor_id, status, id desc)`,
`notifications(user_id, id desc) where not read` (partial) and `notifications(user_id, id desc)`,
`versions(project_id, copy_id, id desc)`, `versions(parent_id)`,
`copies(project_id, state)`, `copies(author_id)`, `projects(owner_id)`, `main_history(project_id, id desc)`.
No reverse index on file hashes: nothing in v1 queries "which versions contain hash X".

**Retention:** `mark_notifications_read` also deletes read notifications beyond the newest 100 for that user.

---

## 6. RPC functions

All `SECURITY DEFINER`, `set search_path = ''`, execute revoked from `anon`, one transaction each.

| RPC | Caller check | Does |
|---|---|---|
| `set_username(name)` | self | validates `^[a-z0-9_]{3,30}$` |
| `create_project(title, description, type, visibility, license)` | has username | inserts project |
| `update_project(id, ...)` | owner | cannot touch `main_version_id` |
| `commit_version(p_actor, project_id, copy_id, parent_id, note, upserts, deletes, verified)` | **service_role only**; actor rules inside | §4.3 step 4c |
| `restore_version(project_id, version_id)` | owner | new main version copying the old arrays; note "Restored from …"; optimistic pointer update |
| `make_copy(project_id)` | has username, public, not owner, license allows | inserts copy (`base = head = main`, `state = private`, `project_owner_id` set) |
| `submit_request(copy_id, note)` | copy author, state `private` | request `pending`, `copies.state = in_review`, event, notify owner |
| `resubmit_request(request_id, note)` | contributor, status `changes_requested` | `submitted_version_id = copy.head`, `pending`, event, notify |
| `review_request(request_id, decision, comment)` | owner, status `pending` | approve → `state = published`, `published_at`; changes → `changes_requested` (state stays `in_review`, author may save); reject → `state = private`. Event + notify |
| `promote_copy(copy_id, acknowledge_stale)` | owner, copy published | `STALE_COPY` unless base = current main or acknowledged; set main, `main_history(from_copy_id)`, notify |
| `mark_notifications_read(ids bigint[])` | owner of rows | mark read + retention prune |
| `takedown_blob(hash)` | admin | sets `blocked_at` |

Saving on a copy is refused while `state = 'in_review'` and the request is `pending`, and always once `published` (content under review or approved is frozen). During `changes_requested` the author may save.

**Read functions (SECURITY INVOKER, so RLS applies), one round trip per screen:**
`get_project_page(project_id)`, `get_review(request_id)`, `get_inbox(cursor)`. All lists use keyset pagination (`where id < cursor limit 20`); never OFFSET.

**Notifications (E7):** inserted inside the RPCs, then pushed with `realtime.send()` to the private channel `user:<uid>` (RLS on `realtime.messages`). The client subscribes once and loads the unread count once.

---

## 7. RLS policies (SELECT only)

```
profiles:         true
projects:         visibility = 'public' or owner_id = (select auth.uid())
copies:           author_id = (select auth.uid())
                  or (state = 'published' and is_project_readable(project_id))
                  or (state = 'in_review' and project_owner_id = (select auth.uid()))
versions:         (copy_id is null and is_project_readable(project_id)) or is_copy_readable(copy_id)
blobs:            false (only reached through read functions / server actions)
review_requests:  owner_id = (select auth.uid()) or contributor_id = (select auth.uid())
request_events:   caller can read the parent request
main_history:     is_project_readable(project_id)
notifications:    user_id = (select auth.uid())
```

Helpers are `STABLE SECURITY DEFINER`. Client queries also add explicit filters matching the policy (for example `.eq('owner_id', uid)`) so the planner can use indexes.

---

## 8. Code layout (JavaScript)

```
supabase/
  migrations/0001_schema.sql          tables, enums, indexes
  migrations/0002_rls.sql             policies + helpers
  migrations/0003_rpc.sql             write RPCs (§6)
  migrations/0004_auth_trigger.sql    profile-on-signup
  migrations/0005_read_functions.sql  SECURITY INVOKER read functions
  tests/*.sql                         pgTAP (`supabase test db`)
lib/
  limits.js              all limits and URL lifetimes
  hash.js                browser SHA-256 (Web Worker)
  supabase/server.js     createServerClient, getClaims helper
  supabase/admin.js      service-role client (import 'server-only')
  storage/index.js       interface; storage/r2.js implementation
app/actions/
  upload.js              prepareUpload, commitVersion, getDownloadUrls
  projects.js, copies.js, requests.js, notifications.js   (zod validation + RPC calls)
middleware.js            session refresh (narrow matcher)
docs/storage-upload-contract.md   shared by storage-dev and upload-dev
```

R2 setup (in the B0 notes): private bucket, API token scoped to it, lifecycle rule on prefix `staging/` expiring after 1 day, CORS allowing PUT/GET from the app origin with the `x-amz-checksum-sha256` header.

---

## 9. Build order (each step needs the owner's go-ahead)

| # | Step | Done when |
|---|---|---|
| B0 | Supabase local dev, R2 bucket + token, env vars. **Spike:** (1) R2 enforces a presigned `x-amz-checksum-sha256`; (2) lifecycle on `staging/`; (3) CopyObject behavior/cost; (4) `getClaims()` verifies locally with asymmetric keys; (5) private-channel `realtime.send()` on free tier | Results written here; fallbacks chosen where needed |
| B1 | Auth (email, Google, GitHub), middleware, profile trigger, `set_username` | Each provider creates exactly one profile; actions reject calls without valid claims |
| B2 | Schema + RLS + helpers | pgTAP: user B cannot write any table directly, cannot update A's project, cannot read A's private project or private copy, calling PostgREST with B's JWT |
| B3 | Storage adapter + upload/commit pipeline | Same file twice → one object, one blob row, quota charged once; wrong hash rejected by R2; B cannot commit a hash without their own staging upload even when A's object exists; 1 changed file in a 200-file project → 1 PUT + 1 `versions` row; stale parent → `STALE_PARENT`; >25 MB and over-quota rejected |
| B4 | Owner versions: `restore_version`, history via `main_history` | 3 saves + restore v1 → v4 has v1's manifest; history pages by keyset |
| B5 | Copies + requests | Two-account flow: copy, edit, submit, changes requested, resubmit, approve → published and credited; separate run: reject → private |
| B6 | Promote | Old main in history; stale copy raises `STALE_COPY` until acknowledged |
| B7 | Notifications + Broadcast | Each B5/B6 transition sends exactly one notification to the right user, live |
| B8 | Takedown | Blocked blob refuses download from every project; version deletion removes orphaned R2 objects |

PRD Phase 3 criterion = B5 + B6 + B7 as one scripted test with two real supabase-js clients.

---

## 10. Open questions

1. **License options:** proposed CC BY, CC BY-SA, CC BY-NC, MIT (code), All rights reserved (copy disabled).
2. **Quota numbers:** 25 MB/file, 500 MB/user are placeholders (10 GB R2 cap ≈ 20 users at full quota).
3. **Withdraw a pending request?** Cheap to add (`withdraw_request`).
4. **Account deletion:** recommended: keep content, anonymize the profile ("deleted user").
