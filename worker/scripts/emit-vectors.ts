/**
 * Conformance vector emitter (TypeScript side of the cross-runtime
 * byte-diff harness, conformance/check.sh).
 *
 * For every case directory under conformance/canonical-json/ — including
 * the deliberately-wrong 9xx cases — read input.json as raw bytes, parse
 * as JSON, canonicalize via src/jcs.ts, and write the canonical bytes to
 * `<outdir>/<case-name>.bin`. The harness diffs these files against the
 * Elixir emitter's output and against the decoded expected.hex bytes;
 * this script itself renders no verdict.
 *
 * Usage: node worker/scripts/emit-vectors.ts <outdir>
 * (node v24 native type-stripping; no build step, no dependencies.)
 */
import { mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { canonicalize } from "../src/jcs.ts";

const outDir = process.argv[2];
if (!outDir) {
  console.error("usage: node emit-vectors.ts <outdir>");
  process.exit(2);
}

const corpusDir = fileURLToPath(
  new URL("../../conformance/canonical-json/", import.meta.url),
);

mkdirSync(outDir, { recursive: true });

const cases = readdirSync(corpusDir, { withFileTypes: true })
  .filter((entry) => entry.isDirectory())
  .map((entry) => entry.name)
  .sort();

for (const name of cases) {
  const inputBytes = readFileSync(join(corpusDir, name, "input.json"));
  const value: unknown = JSON.parse(inputBytes.toString("utf8"));
  writeFileSync(join(outDir, `${name}.bin`), canonicalize(value));
}

console.error(`emit-vectors.ts: emitted ${cases.length} cases to ${outDir}`);
