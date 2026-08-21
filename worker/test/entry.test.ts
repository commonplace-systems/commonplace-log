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

// --- Valid entry: canonical-json/016-spec-example-entry -------------------

const validEntryCase = "016-spec-example-entry";

describe("validateEntry accepts the spec example entry", () => {
  it(`${validEntryCase} validates ok with exactly the expected canonical bytes`, () => {
    const dir = join(canonicalJsonDir, validEntryCase);
    const raw = readFileSync(join(dir, "input.json"));
    const expectedHex = readFileSync(join(dir, "expected.hex"), "utf-8").trim();
    expect(expectedHex).toMatch(/^[0-9a-f]+$/);

    const result = validateEntry(new Uint8Array(raw));
    expect(result.ok).toBe(true);
    if (!result.ok) throw new Error("unreachable");
    expect(toHex(result.canonicalBytes)).toBe(expectedHex);
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
  it("finds at least 15 invalid cases (corpus is non-empty)", () => {
    expect(invalidCaseNames.length).toBeGreaterThanOrEqual(15);
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
