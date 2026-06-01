/**
 * Reject if `promise` does not settle within `ms`.
 *
 * Used to bound Redis reads on public paths: when Upstash is unreachable the
 * client retries with exponential backoff for several seconds, blocking the
 * response. Racing against a deadline lets callers fail fast (and degrade as
 * they see fit) instead of hanging. `Promise.race` consumes the input promise's
 * late settlement, so a slow rejection won't surface as an unhandled rejection.
 */
export function withTimeout<T>(
  promise: Promise<T>,
  ms: number,
  message = "operation timed out",
): Promise<T> {
  let timer: ReturnType<typeof setTimeout>;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(message)), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer)) as Promise<T>;
}
