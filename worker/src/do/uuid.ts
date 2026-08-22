/**
 * UUIDv7 generation per RFC 9562 §5.7.
 *
 * Bit layout over the 16 bytes (big-endian within each field):
 *
 *   bytes 0..5   unix_ts_ms  48-bit Unix epoch milliseconds
 *   byte  6      ver | rand_a[11..8]   high nibble = 0b0111 (version 7)
 *   byte  7      rand_a[7..0]          (12 random bits total in rand_a)
 *   byte  8      var | rand_b[61..56]  top two bits = 0b10 (RFC 4122 variant)
 *   bytes 9..15  rand_b remainder      (62 random bits total in rand_b)
 *
 * The spec (§6.3) recommends UUIDv7 for operational readability only; UUID
 * ordering has no protocol meaning, so no sub-millisecond monotonicity
 * counter is used — rand_a/rand_b are plain crypto.getRandomValues output.
 */

const HEX = "0123456789abcdef";

export function uuidv7(nowMs: number = Date.now()): string {
  if (!Number.isSafeInteger(nowMs) || nowMs < 0 || nowMs >= 2 ** 48) {
    throw new RangeError(`uuidv7 timestamp out of 48-bit range: ${String(nowMs)}`);
  }

  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);

  // unix_ts_ms: 48 bits big-endian in bytes 0..5. nowMs exceeds 32 bits, so
  // divide instead of shifting (JS bitwise ops truncate to 32 bits).
  let t = nowMs;
  for (let i = 5; i >= 0; i--) {
    bytes[i] = t % 256;
    t = Math.floor(t / 256);
  }

  bytes[6] = 0x70 | (bytes[6]! & 0x0f); // version 7 in the high nibble
  bytes[8] = 0x80 | (bytes[8]! & 0x3f); // variant 10xxxxxx

  let hex = "";
  for (const b of bytes) {
    hex += HEX[b >> 4]! + HEX[b & 0x0f]!;
  }
  return (
    `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-` +
    `${hex.slice(16, 20)}-${hex.slice(20, 32)}`
  );
}
