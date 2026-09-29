# R2 setup (owner steps)

Cloudflare R2 holds file bytes for Versio. Postgres never stores bytes, only
`blobs` rows pointing at R2 keys (`docs/storage-upload-contract.md`).

## 1. Create the bucket

1. Cloudflare dashboard → **R2 Object Storage** → **Create bucket**.
2. Name: `versio-dev`.
3. Location: default (automatic) is fine for dev.
4. Leave the bucket **private** — do not enable public access / a public
   `r2.dev` URL. All reads and writes go through presigned URLs signed by the
   server.

## 2. Create a scoped API token

1. R2 → **Manage R2 API Tokens** → **Create API Token**.
2. Permissions: **Object Read & Write**.
3. Scope the token to the `versio-dev` bucket only (not "all buckets").
4. TTL: no expiry for local dev is fine; use a short-lived token in CI/prod.
5. Copy the **Access Key ID** and **Secret Access Key** shown once at creation
   time. Cloudflare does not show the secret again.

## 3. Find the account ID

Cloudflare dashboard → right sidebar on the R2 overview page, or the account
home page → **Account ID**. This is the value used to build the R2 S3-compatible
endpoint: `https://<account_id>.r2.cloudflarestorage.com`.

## 4. Fill in `.env.local`

Copy `.env.example` to `.env.local` (git-ignored, never commit it) and fill in:

```
R2_ACCOUNT_ID=<account id from step 3>
R2_ACCESS_KEY_ID=<access key id from step 2>
R2_SECRET_ACCESS_KEY=<secret access key from step 2>
R2_BUCKET=versio-dev
```

Never paste these values in chat, commit messages, or logs. The scripts below
never print them.

## 5. Apply bucket config, then run the checks

```
npm run r2:config
npm run spike:r2
```

- `npm run r2:config` (`scripts/r2-apply-config.mjs`) idempotently applies:
  - **Lifecycle rule** `expire-staging`: prefix `staging/`, expires after
    `STAGING_EXPIRY_DAYS` (`lib/limits.js`, currently 1 day).
  - **CORS rule** `versio-app-origin`: `PUT`, `GET`, `HEAD` from
    `http://localhost:3000` and `http://127.0.0.1:3000`; allowed headers
    `content-type`, `content-length`, `x-amz-checksum-sha256`; exposes `ETag`.

  It merges with any existing rules under different IDs, so it is safe to
  re-run and safe to run alongside rules you set by hand.

- `npm run spike:r2` (`scripts/spike/r2.mjs`) then checks, against the real
  bucket, the four assumptions the upload pipeline depends on:
  1. presigned `PUT` enforces `Content-Length` + `x-amz-checksum-sha256`
     (wrong bytes of the same length are rejected; the right bytes succeed);
  2. `CopyObject` from `staging/<uid>/<hash>` to `objects/<hash>` works and
     `HEAD objects/<hash>` reports the right size; copying a missing staging
     key fails;
  3. the `staging/` lifecycle rule round-trips through
     `PutBucketLifecycleConfiguration` / `Get`;
  4. a presigned `GET` signed at the floor of the hour is byte-identical when
     generated twice in the same hour, and actually downloads the object.

  Both scripts clean up every object they create, print `PASS`/`FAIL` with a
  short reason per check, and exit non-zero if anything fails. If any
  `R2_*` env var is missing, they print which names are missing (never
  values) and exit with code 2.

## Dashboard fallback

If `npm run r2:config` reports `FAIL` for either rule (some R2 accounts/token
scopes reject the lifecycle or CORS management API), set the same rules by
hand:

- **R2 → `versio-dev` → Settings → Object lifecycle rules → Add rule**
  - Scope: prefix `staging/`
  - Action: **Delete object**, after **`STAGING_EXPIRY_DAYS`** days (see
    `lib/limits.js` for the current value)
- **R2 → `versio-dev` → Settings → CORS Policy → Add CORS policy**
  ```json
  [
    {
      "AllowedOrigins": ["http://localhost:3000", "http://127.0.0.1:3000"],
      "AllowedMethods": ["PUT", "GET", "HEAD"],
      "AllowedHeaders": ["content-type", "content-length", "x-amz-checksum-sha256"],
      "ExposeHeaders": ["ETag"]
    }
  ]
  ```

Update this list with the production origin once it exists (a separate CORS
rule, not a replacement of the dev one).

## Notes

- Object keys: `staging/<uid>/<sha256hex>` for uploads-in-progress,
  `objects/<sha256hex>` for committed blobs. Hashes are lowercase hex in keys
  (`bytea` in Postgres).
- Nothing in this repo reads `R2_*` outside server-only modules
  (`import 'server-only'`) or these owner-run setup scripts.
