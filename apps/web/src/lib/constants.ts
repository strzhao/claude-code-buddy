export const MAX_UPLOAD_SIZE = 5 * 1024 * 1024; // 5 MB
export const MAX_UNCOMPRESSED_SIZE = 50 * 1024 * 1024; // 50 MB
export const ZIP_BOMB_RATIO = 100;

export const REDIS_PREFIX = "skin";
export const REDIS_INDEX_ALL = "skin-ids";
export const REDIS_INDEX_APPROVED = "skin-ids:approved";
export const REDIS_INDEX_PENDING = "skin-ids:pending";
export const REDIS_INDEX_REJECTED = "skin-ids:rejected";

export const BLOB_BASE_PATH = "skins";
export const CACHE_MAX_AGE = 300; // 5 min edge cache
