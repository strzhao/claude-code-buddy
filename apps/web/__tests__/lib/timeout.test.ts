import { describe, it, expect } from "vitest";
import { withTimeout } from "@/lib/timeout";

const delay = <T>(ms: number, value: T): Promise<T> =>
  new Promise((resolve) => setTimeout(() => resolve(value), ms));

describe("withTimeout", () => {
  it("resolves with the value when the promise settles before the deadline", async () => {
    await expect(withTimeout(delay(5, "ok"), 100)).resolves.toBe("ok");
  });

  it("rejects with the deadline message when the promise is too slow", async () => {
    await expect(withTimeout(delay(100, "late"), 10, "redis read timed out")).rejects.toThrow(
      "redis read timed out",
    );
  });

  it("propagates the original rejection when it loses to the deadline", async () => {
    const failing = Promise.reject(new Error("boom"));
    await expect(withTimeout(failing, 50)).rejects.toThrow("boom");
  });

  it("does not leave the slow input as an unhandled rejection after timing out", async () => {
    let unhandled: unknown;
    const onUnhandled = (e: PromiseRejectionEvent | { reason?: unknown }) => {
      unhandled = "reason" in e ? e.reason : e;
    };
    process.on("unhandledRejection", onUnhandled as never);

    const slowReject = new Promise((_, reject) =>
      setTimeout(() => reject(new Error("late boom")), 30),
    );
    await expect(withTimeout(slowReject, 5, "timed out")).rejects.toThrow("timed out");
    // give the slow promise time to reject after the race already settled
    await delay(60, null);
    process.off("unhandledRejection", onUnhandled as never);

    expect(unhandled).toBeUndefined();
  });
});
