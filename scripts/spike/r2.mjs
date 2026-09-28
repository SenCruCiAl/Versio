// @ts-check
// Spike: four risky R2 assumptions, checked against the real bucket before any
// production code (lib/storage/r2.js) depends on them. See BACKEND_PLAN.md §9 (B0)
// and docs/BUILD_STEPS.md Step 1.
//
// Run: npm run spike:r2   (reads .env.local via --env-file-if-exists)
//
// Never prints secret values. Signed URLs are only ever printed with their
// query string stripped.

import { randomBytes, randomUUID, createHash } from "node:crypto";
import {
  S3Client,
  PutObjectCommand,
  CopyObjectCommand,
  HeadObjectCommand,
  GetObjectCommand,
  DeleteObjectsCommand,
  PutBucketLifecycleConfigurationCommand,
  GetBucketLifecycleConfigurationCommand,
} from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import {
  STAGING_EXPIRY_DAYS,
  GET_URL_WINDOW_SECONDS,
  GET_URL_TTL_SECONDS,
  PUT_URL_TTL_SECONDS,
} from "../../lib/limits.js";

/** @typedef {{ pass: boolean, reason: string }} CheckOutcome */

const REQUIRED_ENV = /** @type {const} */ ([
  "R2_ACCOUNT_ID",
  "R2_ACCESS_KEY_ID",
  "R2_SECRET_ACCESS_KEY",
  "R2_BUCKET",
]);

/**
 * Reads a required env var. Only call after `assertEnv()` has confirmed it exists.
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

/** Keys created during this run; removed in cleanup() regardless of outcome. */
const cleanupKeys = /** @type {Set<string>} */ (new Set());

/** @param {string} url */
function stripQuery(url) {
  const i = url.indexOf("?");
  return i === -1 ? url : url.slice(0, i);
}

/** @param {Uint8Array} buf */
function sha256Hex(buf) {
  return createHash("sha256").update(buf).digest("hex");
}

/** @param {Uint8Array} buf */
function sha256Base64(buf) {
  return createHash("sha256").update(buf).digest("base64");
}

/** @param {unknown} err */
function errorMessage(err) {
  return err instanceof Error ? err.message : String(err);
}

/**
 * Check 1: presigned PUT signs Content-Length + x-amz-checksum-sha256.
 * Wrong bytes of the same length must be rejected; the right bytes must succeed.
 * @returns {Promise<CheckOutcome>}
 */
async function checkChecksumEnforcement() {
  const uid = randomUUID();
  const right = randomBytes(256);
  const wrong = Buffer.from(right);
  wrong[0] = wrong[0] ^ 0xff; // flip a byte: same length, different content, different sha256

  const hash = sha256Hex(right);
  const key = `staging/${uid}/${hash}`;
  cleanupKeys.add(key);

  const putCmd = new PutObjectCommand({
    Bucket: bucket,
    Key: key,
    ContentLength: right.length,
    ChecksumSHA256: sha256Base64(right),
  });
  const url = await getSignedUrl(client, putCmd, { expiresIn: PUT_URL_TTL_SECONDS });

  const wrongRes = await fetch(url, { method: "PUT", body: wrong });
  if (wrongRes.ok) {
    return {
      pass: false,
      reason: `wrong bytes (same length, ${wrong.length}B) were accepted (status ${wrongRes.status}); checksum not enforced`,
    };
  }

  const rightRes = await fetch(url, { method: "PUT", body: right });
  if (!rightRes.ok) {
    const body = await rightRes.text().catch(() => "");
    return {
      pass: false,
      reason: `correct bytes were rejected (status ${rightRes.status}): ${body.slice(0, 200)}`,
    };
  }

  return {
    pass: true,
    reason: `wrong bytes rejected (status ${wrongRes.status}), right bytes accepted (status ${rightRes.status}); Content-Length + x-amz-checksum-sha256 enforced`,
  };
}

/**
 * Check 2: CopyObject staging/<uid>/<hash> -> objects/<hash>, then HEAD objects/<hash>
 * returns the right size. Copy from a missing staging key must fail.
 * @returns {Promise<CheckOutcome>}
 */
async function checkCopyStagingToObjects() {
  const uid = randomUUID();
  const content = randomBytes(128);
  const hash = sha256Hex(content);
  const stagingKey = `staging/${uid}/${hash}`;
  const objectKey = `objects/${hash}`;
  cleanupKeys.add(stagingKey);
  cleanupKeys.add(objectKey);

  await client.send(
    new PutObjectCommand({
      Bucket: bucket,
      Key: stagingKey,
      Body: content,
      ContentLength: content.length,
      ChecksumSHA256: sha256Base64(content),
    }),
  );

  await client.send(
    new CopyObjectCommand({
      Bucket: bucket,
      Key: objectKey,
      CopySource: `${bucket}/${stagingKey}`,
    }),
  );

  const head = await client.send(new HeadObjectCommand({ Bucket: bucket, Key: objectKey }));
  if (head.ContentLength !== content.length) {
    return {
      pass: false,
      reason: `HEAD objects/<hash> size mismatch: expected ${content.length}, got ${head.ContentLength}`,
    };
  }

  const missingStagingKey = `staging/${randomUUID()}/${"0".repeat(64)}`;
  const missingDestKey = `objects/${"0".repeat(64)}`;
  cleanupKeys.add(missingDestKey);
  let missingCopyRejected = false;
  let missingCopyReason = "";
  try {
    await client.send(
      new CopyObjectCommand({
        Bucket: bucket,
        Key: missingDestKey,
        CopySource: `${bucket}/${missingStagingKey}`,
      }),
    );
  } catch (err) {
    missingCopyRejected = true;
    missingCopyReason = errorMessage(err);
  }
  if (!missingCopyRejected) {
    return { pass: false, reason: "CopyObject from a missing staging key unexpectedly succeeded" };
  }

  return {
    pass: true,
    reason: `copy + HEAD size match (${head.ContentLength}B); copy from a missing staging key failed as expected (${missingCopyReason})`,
  };
}

/**
 * Check 3: staging/ lifecycle rule, expiring after STAGING_EXPIRY_DAYS, set via
 * PutBucketLifecycleConfiguration and read back with Get. This writes the real,
 * intended rule to the bucket (merged with any existing rules), not a throwaway.
 * @returns {Promise<CheckOutcome>}
 */
async function checkStagingLifecycle() {
  const ruleId = "expire-staging";
  const fallback = `fallback: set "staging/" -> expire after ${STAGING_EXPIRY_DAYS} day(s) in the R2 dashboard (Bucket > Settings > Object lifecycle rules)`;

  try {
    let existingRules = /** @type {import("@aws-sdk/client-s3").LifecycleRule[]} */ ([]);
    try {
      const current = await client.send(new GetBucketLifecycleConfigurationCommand({ Bucket: bucket }));
      existingRules = current.Rules ?? [];
    } catch (err) {
      const name = err && typeof err === "object" && "name" in err ? String(err.name) : "";
      if (name !== "NoSuchLifecycleConfiguration") throw err;
    }

    const desired = /** @type {import("@aws-sdk/client-s3").LifecycleRule} */ ({
      ID: ruleId,
      Filter: { Prefix: "staging/" },
      Status: "Enabled",
      Expiration: { Days: STAGING_EXPIRY_DAYS },
    });
    const merged = [...existingRules.filter((r) => r.ID !== ruleId), desired];

    await client.send(
      new PutBucketLifecycleConfigurationCommand({
        Bucket: bucket,
        LifecycleConfiguration: { Rules: merged },
      }),
    );

    const after = await client.send(new GetBucketLifecycleConfigurationCommand({ Bucket: bucket }));
    const rule = (after.Rules ?? []).find((r) => r.ID === ruleId);
    const days = rule?.Expiration?.Days;
    const prefix = rule?.Filter?.Prefix;
    if (!rule || days !== STAGING_EXPIRY_DAYS || prefix !== "staging/") {
      return {
        pass: false,
        reason: `rule missing/mismatched after write-then-read (days=${days}, prefix=${prefix}); ${fallback}`,
      };
    }

    return {
      pass: true,
      reason: `staging/ expires after ${days} day(s), confirmed via GetBucketLifecycleConfiguration`,
    };
  } catch (err) {
    return { pass: false, reason: `R2 rejected the lifecycle API (${errorMessage(err)}); ${fallback}` };
  }
}

/**
 * Check 4: presigned GET signed at the floor of the hour is byte-identical when
 * generated twice within the same hour, and actually downloads the object.
 * @returns {Promise<CheckOutcome>}
 */
async function checkPresignedGetStability() {
  const content = randomBytes(64);
  const hash = sha256Hex(content);
  const key = `objects/spike-get-${hash}`;
  cleanupKeys.add(key);

  await client.send(
    new PutObjectCommand({
      Bucket: bucket,
      Key: key,
      Body: content,
      ContentLength: content.length,
      ChecksumSHA256: sha256Base64(content),
    }),
  );

  const flooredSeconds = Math.floor(Date.now() / 1000 / GET_URL_WINDOW_SECONDS) * GET_URL_WINDOW_SECONDS;
  const signingDate = new Date(flooredSeconds * 1000);

  const buildGetCommand = () =>
    new GetObjectCommand({
      Bucket: bucket,
      Key: key,
      ResponseCacheControl: "private, max-age=3600, immutable",
      ResponseContentDisposition: "attachment",
    });

  const urlA = await getSignedUrl(client, buildGetCommand(), { expiresIn: GET_URL_TTL_SECONDS, signingDate });
  const urlB = await getSignedUrl(client, buildGetCommand(), { expiresIn: GET_URL_TTL_SECONDS, signingDate });

  if (urlA !== urlB) {
    return {
      pass: false,
      reason: "two presigned GETs signed at the same floored hour were not byte-identical",
    };
  }

  const res = await fetch(urlA);
  if (!res.ok) {
    return { pass: false, reason: `presigned GET download failed with status ${res.status}` };
  }
  const downloaded = Buffer.from(await res.arrayBuffer());
  if (!downloaded.equals(content)) {
    return { pass: false, reason: "downloaded bytes did not match the uploaded content" };
  }

  return {
    pass: true,
    reason: `identical URL within the ${GET_URL_WINDOW_SECONDS}s window (TTL ${GET_URL_TTL_SECONDS}s), download verified byte-for-byte: ${stripQuery(urlA)}`,
  };
}

async function cleanup() {
  const keys = [...cleanupKeys];
  if (keys.length === 0) return;
  try {
    await client.send(
      new DeleteObjectsCommand({
        Bucket: bucket,
        Delete: { Objects: keys.map((Key) => ({ Key })) },
      }),
    );
  } catch (err) {
    console.log(`WARN: cleanup failed for one or more test objects: ${errorMessage(err)}`);
  }
}

/** @type {{ name: string, fn: () => Promise<CheckOutcome> }[]} */
const checks = [
  { name: "checksum-enforcement", fn: checkChecksumEnforcement },
  { name: "copy-staging-to-objects", fn: checkCopyStagingToObjects },
  { name: "staging-lifecycle", fn: checkStagingLifecycle },
  { name: "presigned-get-stability", fn: checkPresignedGetStability },
];

async function main() {
  /** @type {{ name: string, pass: boolean }[]} */
  const results = [];
  for (const { name, fn } of checks) {
    try {
      const { pass, reason } = await fn();
      results.push({ name, pass });
      console.log(`${pass ? "PASS" : "FAIL"} (${name}): ${reason}`);
    } catch (err) {
      results.push({ name, pass: false });
      console.log(`FAIL (${name}): ${errorMessage(err)}`);
    }
  }

  await cleanup();

  const failed = results.filter((r) => !r.pass);
  if (failed.length > 0) {
    console.log(`\n${failed.length}/${results.length} check(s) failed.`);
    process.exit(1);
  }
  console.log(`\nAll ${results.length} checks passed.`);
}

main().catch(async (err) => {
  console.log(`FAIL (fatal): ${errorMessage(err)}`);
  await cleanup();
  process.exit(1);
});
