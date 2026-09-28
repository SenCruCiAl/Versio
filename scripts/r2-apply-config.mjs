// @ts-check
// Idempotently applies the R2 bucket config Versio needs: the staging/ lifecycle
// rule and the CORS rule for browser presigned PUT/GET. Safe to re-run; it merges
// with (rather than replaces) unrelated existing rules and reads both back to
// confirm the applied values match. See BACKEND_PLAN.md §8, §9 (B0) and
// docs/r2-setup.md.
//
// Run: npm run r2:config   (reads .env.local via --env-file-if-exists)
//
// Never prints secret values.

import {
  S3Client,
  PutBucketLifecycleConfigurationCommand,
  GetBucketLifecycleConfigurationCommand,
  PutBucketCorsCommand,
  GetBucketCorsCommand,
} from "@aws-sdk/client-s3";
import { STAGING_EXPIRY_DAYS } from "../lib/limits.js";

const REQUIRED_ENV = /** @type {const} */ ([
  "R2_ACCOUNT_ID",
  "R2_ACCESS_KEY_ID",
  "R2_SECRET_ACCESS_KEY",
  "R2_BUCKET",
]);

/**
 * @param {string} name
 * @returns {string}
 */
function requireEnv(name) {
  const value = process.env[name];
  if (!value) throw new Error(`missing env var ${name}`);
  return value;
}

function assertEnv() {
  const missing = REQUIRED_ENV.filter((name) => !process.env[name]);
  if (missing.length > 0) {
    console.log("SKIPPED: credentials not set");
    console.log(`Missing env vars: ${missing.join(", ")}`);
    console.log("Add them to .env.local (see .env.example) and re-run.");
    process.exit(2);
  }
}

assertEnv();

const accountId = requireEnv("R2_ACCOUNT_ID");
const bucket = requireEnv("R2_BUCKET");

const client = new S3Client({
  region: "auto",
  endpoint: `https://${accountId}.r2.cloudflarestorage.com`,
  credentials: {
    accessKeyId: requireEnv("R2_ACCESS_KEY_ID"),
    secretAccessKey: requireEnv("R2_SECRET_ACCESS_KEY"),
  },
});

const LIFECYCLE_RULE_ID = "expire-staging";
const CORS_RULE_ID = "versio-app-origin";
const DEV_ORIGINS = ["http://localhost:3000", "http://127.0.0.1:3000"];

/** @param {unknown} err */
function errorMessage(err) {
  return err instanceof Error ? err.message : String(err);
}

async function applyLifecycle() {
  console.log("Lifecycle: staging/ ...");
  let existingRules = /** @type {import("@aws-sdk/client-s3").LifecycleRule[]} */ ([]);
  try {
    const current = await client.send(new GetBucketLifecycleConfigurationCommand({ Bucket: bucket }));
    existingRules = current.Rules ?? [];
  } catch (err) {
    const name = err && typeof err === "object" && "name" in err ? String(err.name) : "";
    if (name !== "NoSuchLifecycleConfiguration") throw err;
  }

  const desired = /** @type {import("@aws-sdk/client-s3").LifecycleRule} */ ({
    ID: LIFECYCLE_RULE_ID,
    Filter: { Prefix: "staging/" },
    Status: "Enabled",
    Expiration: { Days: STAGING_EXPIRY_DAYS },
  });
  const merged = [...existingRules.filter((r) => r.ID !== LIFECYCLE_RULE_ID), desired];

  await client.send(
    new PutBucketLifecycleConfigurationCommand({
      Bucket: bucket,
      LifecycleConfiguration: { Rules: merged },
    }),
  );

  const after = await client.send(new GetBucketLifecycleConfigurationCommand({ Bucket: bucket }));
  const rule = (after.Rules ?? []).find((r) => r.ID === LIFECYCLE_RULE_ID);
  const days = rule?.Expiration?.Days;
  const prefix = rule?.Filter?.Prefix;
  if (!rule || days !== STAGING_EXPIRY_DAYS || prefix !== "staging/") {
    throw new Error(
      `lifecycle rule missing/mismatched after write-then-read (days=${days}, prefix=${prefix})`,
    );
  }
  console.log(`  OK: staging/ expires after ${days} day(s) (rule "${LIFECYCLE_RULE_ID}", ${after.Rules?.length ?? 0} total rule(s))`);
}

async function applyCors() {
  console.log("CORS: PUT/GET/HEAD from dev origins ...");
  let existingRules = /** @type {import("@aws-sdk/client-s3").CORSRule[]} */ ([]);
  try {
    const current = await client.send(new GetBucketCorsCommand({ Bucket: bucket }));
    existingRules = current.CORSRules ?? [];
  } catch (err) {
    const name = err && typeof err === "object" && "name" in err ? String(err.name) : "";
    if (name !== "NoSuchCORSConfiguration") throw err;
  }

  const desired = /** @type {import("@aws-sdk/client-s3").CORSRule} */ ({
    ID: CORS_RULE_ID,
    AllowedMethods: ["PUT", "GET", "HEAD"],
    AllowedOrigins: DEV_ORIGINS,
    AllowedHeaders: ["content-type", "content-length", "x-amz-checksum-sha256"],
    ExposeHeaders: ["ETag"],
  });
  const merged = [...existingRules.filter((r) => r.ID !== CORS_RULE_ID), desired];

  await client.send(
    new PutBucketCorsCommand({
      Bucket: bucket,
      CORSConfiguration: { CORSRules: merged },
    }),
  );

  const after = await client.send(new GetBucketCorsCommand({ Bucket: bucket }));
  const rule = (after.CORSRules ?? []).find((r) => r.ID === CORS_RULE_ID);
  const methodsOk = DEV_ORIGINS.every((o) => rule?.AllowedOrigins?.includes(o));
  const allowedMethodsOk = ["PUT", "GET", "HEAD"].every((m) => rule?.AllowedMethods?.includes(m));
  if (!rule || !methodsOk || !allowedMethodsOk) {
    throw new Error(`CORS rule missing/mismatched after write-then-read: ${JSON.stringify(rule)}`);
  }
  console.log(
    `  OK: origins [${rule.AllowedOrigins?.join(", ")}], methods [${rule.AllowedMethods?.join(", ")}] (rule "${CORS_RULE_ID}", ${after.CORSRules?.length ?? 0} total rule(s))`,
  );
}

async function main() {
  await applyLifecycle();
  await applyCors();
  console.log("\nR2 config applied and verified.");
}

main().catch((err) => {
  console.log(`FAIL: ${errorMessage(err)}`);
  console.log(
    'Fallback: set both rules by hand in the R2 dashboard (Bucket > Settings > "Object lifecycle rules" and "CORS Policy").',
  );
  process.exit(1);
});
