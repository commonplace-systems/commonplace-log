/**
 * RFC 8785 (JCS) canonical JSON serialization.
 *
 * Returns the canonical UTF-8 bytes for a parsed JSON value. The shared
 * conformance corpus in conformance/canonical-json/ is the arbiter of
 * correctness; every runtime implementation must match it byte-for-byte.
 */
export function canonicalize(value: unknown): Uint8Array {
  return new TextEncoder().encode(serialize(value));
}

function serialize(value: unknown): string {
  if (value === null) {
    return "null";
  }
  switch (typeof value) {
    case "boolean":
      return value ? "true" : "false";
    case "number":
      if (!Number.isFinite(value)) {
        throw new TypeError(
          `Cannot canonicalize non-finite number: ${String(value)}`,
        );
      }
      // RFC 8785 §3.2.2.3 defines number serialization as ECMAScript's
      // Number::toString, which JSON.stringify applies to finite numbers.
      return JSON.stringify(value);
    case "string":
      // RFC 8785 §3.2.2.2 defines string escaping as ECMAScript's
      // JSON.stringify serialization of a string.
      return JSON.stringify(value);
    case "object":
      if (Array.isArray(value)) {
        return `[${value.map((element) => serialize(element)).join(",")}]`;
      }
      return serializeObject(value as Record<string, unknown>);
    default:
      // undefined, function, symbol, bigint: no JCS serialization exists.
      throw new TypeError(`Cannot canonicalize value of type ${typeof value}`);
  }
}

function serializeObject(obj: Record<string, unknown>): string {
  // RFC 8785 §3.2.3: sort property names by UTF-16 code units. JavaScript's
  // native `<` on strings compares UTF-16 code units, so a default-comparator
  // sort is exactly the required order (never localeCompare/Intl).
  const keys = Object.keys(obj).sort();
  const members = keys.map(
    (key) => `${JSON.stringify(key)}:${serialize(obj[key])}`,
  );
  return `{${members.join(",")}}`;
}
