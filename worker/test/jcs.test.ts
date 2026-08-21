import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { canonicalize } from "../src/jcs";

const corpusDir = fileURLToPath(
  new URL("../../conformance/canonical-json/", import.meta.url),
);

interface CorpusCase {
  name: string;
  input: unknown;
  expectedHex: string;
}

function loadCase(name: string): CorpusCase {
  const dir = join(corpusDir, name);
  // input.json is authoritative as raw bytes; parse those bytes as UTF-8 JSON.
  const inputBytes = readFileSync(join(dir, "input.json"));
  const input: unknown = JSON.parse(inputBytes.toString("utf-8"));
  // expected.hex is one line of lowercase hex plus a trailing LF (formatting).
  const expectedHex = readFileSync(join(dir, "expected.hex"), "utf-8").trim();
  expect(expectedHex).toMatch(/^[0-9a-f]+$/);
  return { name, input, expectedHex };
}

function toHex(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString("hex");
}

const caseNames = readdirSync(corpusDir, { withFileTypes: true })
  .filter((entry) => entry.isDirectory())
  .map((entry) => entry.name)
  .sort();

const passGateCases = caseNames.filter((name) => !/^9\d\d-/.test(name));
const deliberateMismatchCases = caseNames.filter((name) =>
  /^9\d\d-/.test(name),
);

describe("corpus discovery", () => {
  it("finds at least 15 pass-gate cases (corpus is non-empty)", () => {
    expect(passGateCases.length).toBeGreaterThanOrEqual(15);
  });

  it("finds at least one deliberate-mismatch (9xx) case", () => {
    expect(deliberateMismatchCases.length).toBeGreaterThanOrEqual(1);
  });
});

describe("canonicalize matches shared vectors", () => {
  it.for(passGateCases)("%s", (name) => {
    const { input, expectedHex } = loadCase(name);
    expect(toHex(canonicalize(input))).toBe(expectedHex);
  });
});

describe("deliberate-mismatch (9xx) cases must NOT match correct output", () => {
  it.for(deliberateMismatchCases)("%s", (name) => {
    const { input, expectedHex } = loadCase(name);
    expect(toHex(canonicalize(input))).not.toBe(expectedHex);
  });
});
