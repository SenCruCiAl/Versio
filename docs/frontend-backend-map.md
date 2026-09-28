# Frontend → backend map

For the frontend owner. No frontend code exists in this repo yet (only
`PRD.md`, added in dip-soumya's one commit so far). This lists, for every
screen in `PRD.md` §11, what backend action or RPC it will call and whether
that backend piece exists today.

Status key:
- **done in Steps 1–2** — code complete per `docs/BUILD_STEPS.md`; Step 1
  (B0 setup) and Step 2 (B1 auth) are written and tested, just waiting on the
  owner's local Docker/OAuth setup for live verification, not on more code.
- **planned step N** — RPC/action is designed in `BACKEND_PLAN.md` and
  scheduled as step N of `docs/BUILD_STEPS.md`, but not built yet.
- **not in plan** — no backend work scheduled for this screen yet (P1/P2 in
  the PRD, or explicitly out of scope in `BACKEND_PLAN.md`'s Scope line).

| Screen (PRD §11) | Backend action / RPC it will call | Status |
|---|---|---|
| Landing | none — static marketing page | not in plan (`BACKEND_PLAN.md` Scope: "Out of scope for now: … landing page") |
| Auth (sign up / log in, username onboarding) | `app/actions/auth.js`: `signUpWithEmail`, `signInWithEmail`, `signInWithOAuth`, `signOut`, `setUsername`; RPC `set_username`; `handle_new_user` trigger creates the `profiles` row on signup | done in Steps 1–2. Still needs frontend pages for `/auth/auth-error` and username onboarding (noted in `docs/BUILD_STEPS.md` Step 2) |
| Dashboard — my projects | RLS-filtered `select * from projects where owner_id = auth.uid()` (table + RLS from `BACKEND_PLAN.md` §5/§7) | planned step 3 (B2 schema + RLS) |
| Dashboard — my copies | RLS-filtered `select * from copies where author_id = auth.uid()` | planned step 5 (B4–B5 versions, copies, requests) |
| Project page — Files tab | `getDownloadUrls(version_id)` for the current main version's manifest | planned step 4 (B3 storage and upload pipeline) |
| Project page — History tab | `get_project_page(project_id)` read function, `main_history` table, `restore_version` RPC | planned step 5 (B4–B5 versions, copies, requests) |
| Project page — Versions by others tab | `get_project_page(project_id)` (published copies for this project), `promote_copy` RPC | planned step 5 for the copy list; `promote_copy` itself is planned step 6 (B6–B7 promote and notifications) |
| Editor / upload (drag-drop, paste text, save version with note) | `prepareUpload`, `commitVersion` in `app/actions/upload.js`; `commit_version` RPC; `lib/hash.js` (browser SHA-256) | planned step 4 (B3 storage and upload pipeline) |
| Make my copy (button on project page) | `make_copy` RPC | planned step 5 (B4–B5 versions, copies, requests) |
| Requests inbox | `get_inbox(cursor)` read function, `review_requests` table | planned step 5 (B4–B5 versions, copies, requests) |
| Review screen (approve / ask for changes / reject) | `get_review(request_id)` read function; `submit_request`, `resubmit_request`, `review_request` RPCs | planned step 5 (B4–B5 versions, copies, requests) |
| Notifications dropdown | `notifications` table (RLS), `mark_notifications_read` RPC, Realtime Broadcast on channel `user:<uid>` | planned step 6 (B6–B7 promote and notifications) |
| Explore (P1) | none designed yet | not in plan (`BACKEND_PLAN.md` Scope: "Out of scope for now: … explore/search/stars") |
| Profile (P1) | none designed yet | not in plan (P1 in PRD; no backend RPC drafted) |

## Notes for the frontend owner

- Backend branch is `backend`; `main` only has the skeleton and is not
  touched by backend work.
- Auth is the only screen with working backend code right now. Everything
  else needs `docs/BUILD_STEPS.md` Steps 3–7 done first (schema/RLS, then
  storage/upload, then versions/copies/requests, then promote/notifications,
  then takedown).
- Backend code is JavaScript with `// @ts-check` + JSDoc (see
  `BACKEND_PLAN.md` "Language"), not TypeScript, so it can be called from a
  TS frontend without a rewrite.
- Takedown (Step 7 / B8) has no dedicated screen in PRD §11; it is an admin
  RPC (`takedown_blob`), not a page.
