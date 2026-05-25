/**
 * Auth utility library for gateway session management.
 *
 * Uses Web Crypto API (crypto.subtle) for Edge Runtime compatibility
 * in Next.js middleware. Works in both Edge and Node.js runtimes.
 */

// ─── Constants ────────────────────────────────────────────────────────────────

export const GATEWAY_COOKIE_NAME = "buddy_gateway_session";
export const AUTH_STATE_COOKIE_NAME = "auth_state";
export const GATEWAY_SESSION_TTL_SECONDS = 43200; // 12 hours

// ─── Types ────────────────────────────────────────────────────────────────────

export interface GatewaySessionPayload {
  email: string;
  issuedAt: string | number;
  expiresAt: string | number;
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function base64urlEncode(buf: ArrayBuffer | Uint8Array): string {
  const bytes = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
  let binary = "";
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "");
}

function base64urlEncodeString(str: string): string {
  return base64urlEncode(new TextEncoder().encode(str));
}

function base64urlDecode(input: string): Uint8Array {
  const padded = input
    .replace(/-/g, "+")
    .replace(/_/g, "/")
    .padEnd(input.length + ((4 - (input.length % 4)) % 4), "=");
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

function getSecret(secretArg?: string): string {
  const secret = secretArg ?? process.env.AUTH_GATEWAY_SESSION_SECRET;
  if (!secret) {
    throw new Error("AUTH_GATEWAY_SESSION_SECRET is not set and no secret was provided");
  }
  return secret;
}

async function hmacSign(data: string, secret: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(data));
  return base64urlEncode(sig);
}

function timingSafeCompare(a: string, b: string): boolean {
  const maxLen = Math.max(a.length, b.length);
  let result = a.length !== b.length ? 1 : 0;
  for (let i = 0; i < maxLen; i++) {
    result |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
  }
  return result === 0;
}

// ─── Gateway Session Cookie ───────────────────────────────────────────────────

/**
 * Create a signed gateway session cookie value.
 * Format: base64url(JSON payload) + "." + base64url(HMAC-SHA256 signature)
 */
export async function createGatewaySession(email: string, secret?: string): Promise<string> {
  const signingSecret = getSecret(secret);

  const now = Date.now();
  const payload: GatewaySessionPayload = {
    email,
    issuedAt: now,
    expiresAt: now + GATEWAY_SESSION_TTL_SECONDS * 1000,
  };

  const payloadB64 = base64urlEncodeString(JSON.stringify(payload));
  const signature = await hmacSign(payloadB64, signingSecret);
  return `${payloadB64}.${signature}`;
}

/**
 * Verify a gateway session cookie value.
 * Returns the payload if valid and unexpired, null otherwise.
 */
export async function verifyGatewaySession(
  cookieValue: string,
  secret?: string,
): Promise<GatewaySessionPayload | null> {
  const resolvedSecret = secret ?? process.env.AUTH_GATEWAY_SESSION_SECRET ?? "";
  if (!resolvedSecret) return null;

  const dotIndex = cookieValue.lastIndexOf(".");
  if (dotIndex === -1) return null;

  const payloadB64 = cookieValue.slice(0, dotIndex);
  const providedSig = cookieValue.slice(dotIndex + 1);

  // Compute expected signature
  let expectedSig: string;
  try {
    expectedSig = await hmacSign(payloadB64, resolvedSecret);
  } catch {
    return null;
  }

  // Timing-safe comparison
  if (!timingSafeCompare(providedSig, expectedSig)) return null;

  // Decode and parse payload
  let payload: GatewaySessionPayload;
  try {
    const payloadJson = new TextDecoder().decode(base64urlDecode(payloadB64));
    payload = JSON.parse(payloadJson) as GatewaySessionPayload;
  } catch {
    return null;
  }

  // Check expiration (support both millisecond timestamps and ISO strings)
  const expiresMs =
    typeof payload.expiresAt === "number"
      ? payload.expiresAt
      : new Date(payload.expiresAt).getTime();

  if (isNaN(expiresMs) || expiresMs <= Date.now()) return null;

  return payload;
}

/**
 * Extract email from a gateway session cookie value without full verification.
 * Used in Server Components where we only need to display the email (middleware already verified).
 */
export function extractEmailFromSession(cookieValue: string): string | null {
  const dotIndex = cookieValue.lastIndexOf(".");
  if (dotIndex === -1) return null;
  const payloadB64 = cookieValue.slice(0, dotIndex);
  try {
    const payloadJson = new TextDecoder().decode(base64urlDecode(payloadB64));
    const payload = JSON.parse(payloadJson) as GatewaySessionPayload;
    return payload.email ?? null;
  } catch {
    return null;
  }
}

// ─── Admin Email Check ────────────────────────────────────────────────────────

/**
 * Check if an email is in the admin list.
 */
export function isAdminEmail(email: string, adminEmailsEnv?: string): boolean {
  const raw = adminEmailsEnv ?? process.env.AUTH_ADMIN_EMAILS ?? "";
  if (!raw.trim()) return false;
  const admins = raw
    .split(",")
    .map((e) => e.trim().toLowerCase())
    .filter(Boolean);
  return admins.includes(email.trim().toLowerCase());
}
