// @ts-check
// Single place for all backend limits. Tune here only.

/** Max size of one uploaded file, in bytes (25 MB). */
export const MAX_FILE_BYTES = 25 * 1024 * 1024;

/** Storage quota per user, in bytes (500 MB). Charged only for new blobs. */
export const USER_QUOTA_BYTES = 500 * 1024 * 1024;

/** Max files in one version's manifest. */
export const MAX_FILES_PER_VERSION = 1000;

/** Presigned PUT lifetime for staging uploads, in seconds. */
export const PUT_URL_TTL_SECONDS = 10 * 60;

/** Presigned GET: signed at the start of the hour, valid 2 h, so URLs are stable (cacheable) within the hour. */
export const GET_URL_WINDOW_SECONDS = 60 * 60;
export const GET_URL_TTL_SECONDS = 2 * 60 * 60;

/** R2 lifecycle deletes staging/ objects after this many days. */
export const STAGING_EXPIRY_DAYS = 1;
