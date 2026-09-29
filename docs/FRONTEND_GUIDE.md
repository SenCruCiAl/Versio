# Versio: Frontend Guide

For the frontend owner (dip-soumya). It covers what exists, how to run it, what you can connect today, and what to build.
Last updated: 29 Sep 2026.

---

## 1. Where things stand

- **Repo is private.** Two branches: `main` (skeleton) and `backend` (all current work). PR #2 (`backend` → `main`) is open.
- **History was rewritten twice on 28 Sep.** If you cloned before then, run `git fetch && git reset --hard origin/main` (or re-clone).
- **No frontend code exists yet.** The PRD's pages all need building.
- **Backend done:** sign-up/sign-in (email; Google and GitHub are coded but switched off until the OAuth apps exist), usernames, and one profile per user.
- **Backend not done yet:** projects, uploads, versions, copies, requests, promote, notifications. See the step table in section 5.

Branch off `backend` (or off `main` once PR #2 is merged) so you start from the current `package.json`.

---

## 2. Decisions that differ from the PRD

| PRD says | What we actually use | What it means for you |
|---|---|---|
| TypeScript everywhere | Backend is **JavaScript with JSDoc types** (`// @ts-check`) | You can write the frontend in TS; importing the backend's JS works as is |
| Supabase Storage | **Cloudflare R2** | File bytes go browser → R2 directly via signed URLs. The upload helper (Step 4) handles this; never send file bytes through a server action |
| `middleware.ts` | **`proxy.js`** (Next 16 renamed it) | Already written; it refreshes the session. Don't add a `middleware` file |
| Status on versions | Versions never change; state lives on **copies** (`private` / `in_review` / `published`) | Show copy state from the copy, not the version |

Already installed (`package.json`): Next 16, React 19, `@supabase/ssr`, `@supabase/supabase-js`, zod. **You add:** Tailwind CSS and shadcn/ui (PRD §7). Later (P1): jsdiff, Shiki, three.js.

---

## 3. Run it locally

1. Install **Node 24 LTS** and **Docker Desktop** (needs WSL2 on Windows).
2. In the repo: `npm install`
3. Create your own JWT signing key (it's git-ignored, so each machine makes its own):
   ```
   echo [] > supabase/signing_keys.json
   npx supabase gen signing-key --algorithm ES256 --append
   ```
4. Start the local backend: `npx supabase start`. The first run downloads images and takes a few minutes. Then run `npx supabase db reset` to apply all migrations.
5. Run `npx supabase status` and copy `API_URL` and `ANON_KEY` into a new `.env.local` (git-ignored, never commit it):
   ```
   NEXT_PUBLIC_SUPABASE_URL=<API_URL>
   NEXT_PUBLIC_SUPABASE_ANON_KEY=<ANON_KEY>
   SUPABASE_SERVICE_ROLE_KEY=<SERVICE_ROLE_KEY>
   NEXT_PUBLIC_SITE_URL=http://localhost:3000
   ```
6. `npx next dev`. Local confirmation emails appear in **Mailpit** at the `MAILPIT_URL` shown by `supabase status` (usually http://127.0.0.1:54324).

Useful: `npm test` (backend unit tests), `npm run typecheck`, `npm run db:test` (database tests).

---

## 4. What you can connect today: Auth

All actions are in `app/actions/auth.js` (server actions, callable from forms or client components). Each returns
`{ ok: true }` or `{ ok: false, code, message }`, where `message` is already user-friendly and can be shown directly.

| Action | Input | Error codes | Notes |
|---|---|---|---|
| `signUpWithEmail({ email, password })` | password ≥ 8 chars, letters and digits | `INVALID_INPUT`, `SIGNUP_ERROR` | Sends a confirmation email. Show a "check your email" screen on `ok` |
| `signInWithEmail({ email, password })` | | `INVALID_INPUT`, `SIGNIN_ERROR` | Works only after the email is confirmed |
| `signInWithOAuth("google" \| "github")` | | `INVALID_PROVIDER`, `OAUTH_ERROR` | Redirects away to Google/GitHub. **Off until the OAuth apps exist**; build the buttons anyway |
| `setUsername({ username })` | 3–30 chars: `a-z`, `0-9`, `_` (stored lower-case) | `INVALID_USERNAME`, `USERNAME_TAKEN`, `UNAUTHENTICATED` / `NOT_AUTHENTICATED` (not signed in), `UNKNOWN` | Can be called again to change the name |
| `signOut()` | | | |

**Routes the backend already uses (you build the pages):**
- `/auth/callback`: done (route handler). Email-confirmation and OAuth links land here, and it redirects to `?next=` (relative paths only) or `/`.
- **`/auth/auth-error`**: page needed. Users land here if a confirmation or OAuth link fails.
- **Username onboarding**: page needed. Every new user starts with `username = null`, and every write action (create project, make copy, …) will require a username, so send users with no username here after sign-in.

**Reading the current user**
- Server Components / server actions: `import { requireUser } from "@/lib/supabase/server.js"` returns `{ supabase, uid, claims }` or throws `AuthError` with code `UNAUTHENTICATED`.
- Client Components: `import { createClient } from "@/lib/supabase/client.js"`.
- A profile: `supabase.from("profiles").select("username, display_name, avatar_url, tags, storage_used").eq("id", uid).single()`. Profiles are public to read, but **nobody can write them directly**; changes go through actions and RPCs only.

---

## 5. Screen-by-screen: what to build and when the backend is ready

Build every screen now with **mock data** (PRD §12, Step 1). Connect each one when its backend step lands.

| Screen (PRD §11) | Backend it will call | Backend ready? |
|---|---|---|
| Landing | none (static) | n/a: build anytime |
| Auth + username onboarding + `/auth/auth-error` | `app/actions/auth.js` (section 4) | **Ready now** |
| Dashboard: my projects | `projects` table (RLS), `create_project` | Step 3 |
| Project page: Files tab | `getDownloadUrls(versionId)` | Step 4 |
| Editor / upload (drag-drop, paste text, save with note) | `lib/hash.js`, `prepareUpload`, `commitVersion` | Step 4 |
| Project page: History tab + restore | `get_project_page`, `restore_version` | Step 5 |
| Make my copy button | `make_copy` | Step 5 |
| Dashboard: my copies | `copies` table (RLS) | Step 5 |
| Request to publish (on a copy) | `submit_request`, `resubmit_request` | Step 5 |
| Requests inbox | `get_inbox(cursor)` | Step 5 |
| Review screen (approve / ask for changes / reject) | `get_review`, `review_request` | Step 5 |
| Versions by others tab + "Make this the main version" | `get_project_page`, `promote_copy` | Step 6 |
| Notifications dropdown | `notifications` table, `mark_notifications_read`, Realtime channel `user:<uid>` | Step 6 |
| Explore, Profile (P1) | not designed yet | later |

Exact names and shapes: `BACKEND_PLAN.md` §6 (RPCs) and `docs/frontend-backend-map.md`. If a screen needs data or an action that isn't listed, open an issue or tell the backend owner, and it'll be added to the plan.

---

## 6. Rules the UI must follow (enforced by the backend)

- **Limits** (`lib/limits.js`): 25 MB per file, 500 MB per user, 1000 files per version. Check these in the UI before uploading, and show the user's `storage_used`.
- **Every project needs a license.** "All rights reserved" disables Make my copy, so hide or disable the button.
- **Copy states:** `private` → (Request to publish) → `in_review` → approve → `published`, or ask for changes (stays `in_review`, the author can edit and resubmit), or reject → back to `private`.
  - The author **cannot save** while a request is pending, and never after `published`.
- **Promote warning:** if a copy was built on an older main, the backend returns `STALE_COPY`. Show a confirm dialog ("this copy is based on an older version…"), then call again with `acknowledge_stale = true`.
- **Save conflicts:** if someone saved first, the backend returns `STALE_PARENT`. Ask the user to reload.
- **Lists page by cursor** (`id < cursor`, 20 at a time), never by page number. Use "Load more" or infinite scroll.
- **Never put secrets in client code.** Only `NEXT_PUBLIC_*` variables are allowed in the browser.
- **HTML/SVG files download instead of opening inline** (security). Previews for those need a sandbox (later, P1).

---

## 7. Suggested order for you

1. Tailwind + shadcn/ui setup, root layout, design system.
2. Auth screens + username onboarding + `/auth/auth-error`, **connected to the real actions** (ready now).
3. All other screens as static pages with mock data.
4. Connect each screen as backend Steps 3–6 land (you'll be told when each is ready), and add loading, empty and error states.
5. P1: diffs (jsdiff), code highlighting (Shiki), STL viewer (three.js), Explore, Profile.

Questions or missing backend pieces: open a GitHub issue on this repo.
