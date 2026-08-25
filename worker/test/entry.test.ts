import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { validateEntry } from "../src/entry";

const conformanceDir = fileURLToPath(
  new URL("../../conformance/", import.meta.url),
);
const canonicalJsonDir = join(conformanceDir, "canonical-json");
const invalidEntriesDir = join(conformanceDir, "invalid-entries");

function toHex(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString("hex");
}

// --- Valid entries: canonical-json anchor cases ---------------------------
// 016: the spec §7 example entry. 017: the same entry padded with >1 MiB of
// inter-token whitespace — raw input exceeds 1,048,576 bytes but its
// canonical form is 016's 327 bytes, pinning that the spec §7.1 cap is
// measured on CANONICAL bytes, not raw input bytes. 018: the same entry with
// float-spelled integer fields (27.0, 1.0) — integer-field semantics are
// VALUE-based, spelling is irrelevant, and the canonical bytes are again
// exactly 016's. 019 is v2 with its required operation_id.

const validEntryCases = [
  "016-spec-example-entry",
  "017-whitespace-padded-entry",
  "018-float-spelled-integers",
  "019-entry-v2-operation-id",
];

describe("validateEntry accepts the valid-entry anchor cases", () => {
  it.for(validEntryCases)(
    "%s validates ok with exactly the expected canonical bytes",
    (name) => {
      const dir = join(canonicalJsonDir, name);
      const raw = readFileSync(join(dir, "input.json"));
      const expectedHex = readFileSync(
        join(dir, "expected.hex"),
        "utf-8",
      ).trim();
      expect(expectedHex).toMatch(/^[0-9a-f]+$/);

      const result = validateEntry(new Uint8Array(raw));
      expect(result.ok).toBe(true);
      if (!result.ok) throw new Error("unreachable");
      expect(toHex(result.canonicalBytes)).toBe(expectedHex);
    },
  );
});

describe("cap-side discrimination", () => {
  it("017's raw input is itself over the 1 MiB cap (whitespace collapses)", () => {
    const raw = readFileSync(
      join(canonicalJsonDir, "017-whitespace-padded-entry", "input.json"),
    );
    expect(raw.byteLength).toBeGreaterThan(1_048_576);
  });
});

describe("version-2 operation_id boundary and parsed-number semantics", () => {
  function mutateV2(mutator: (entry: Record<string, unknown>) => void): Uint8Array {
    const source = readFileSync(
      join(canonicalJsonDir, "019-entry-v2-operation-id", "input.json"),
      "utf8",
    );
    const entry = JSON.parse(source) as Record<string, unknown>;
    mutator(entry);
    return new TextEncoder().encode(JSON.stringify(entry));
  }

  it("accepts a non-empty operation_id of exactly 256 UTF-8 bytes", () => {
    const result = validateEntry(mutateV2((entry) => {
      entry["operation_id"] = "é".repeat(128);
    }));
    expect(result.ok).toBe(true);
  });

  it("rejects string version 2", () => {
    const result = validateEntry(mutateV2((entry) => {
      delete entry["operation_id"];
      entry["version"] = "2";
    }));
    expect(result).toEqual({ ok: false, code: "invalid_entry", reason: "wrong-version" });
  });
});

// --- Invalid entries: invalid-entries/* -----------------------------------

interface InvalidCase {
  name: string;
  raw: Uint8Array;
  code: string;
  reason: string;
}

function loadInvalidCase(name: string): InvalidCase {
  const dir = join(invalidEntriesDir, name);
  const raw = new Uint8Array(readFileSync(join(dir, "input.json")));
  // error.txt: line 1 error code, line 2 shared reason slug, trailing LF.
  const errorLines = readFileSync(join(dir, "error.txt"), "utf-8").split("\n");
  const [code, reason] = errorLines;
  expect(code).toMatch(/^[a-z_]+$/);
  expect(reason).toMatch(/^[a-z0-9-]+$/);
  return { name, raw, code: code as string, reason: reason as string };
}

const invalidCaseNames = readdirSync(invalidEntriesDir, {
  withFileTypes: true,
})
  .filter((entry) => entry.isDirectory())
  .map((entry) => entry.name)
  .sort();

describe("invalid-entries corpus discovery", () => {
  it("finds at least 36 invalid cases", () => {
    expect(invalidCaseNames.length).toBeGreaterThanOrEqual(36);
  });
});

describe("validateEntry rejects each invalid-entries vector with exact code and reason", () => {
  it.for(invalidCaseNames)("%s", (name) => {
    const { raw, code, reason } = loadInvalidCase(name);
    const result = validateEntry(raw);
    expect(result.ok).toBe(false);
    if (result.ok) throw new Error("unreachable");
    expect({ code: result.code, reason: result.reason }).toEqual({
      code,
      reason,
    });
  });
});
