/**
 * Differential fuzz canonicalizer (TypeScript side of conformance/fuzz.sh).
 *
 * For every `fuzz-NNNN.json` in <gendir> (written by the Elixir generator,
 * commonplace_log/scripts/fuzz_differential.exs): read the file as raw
 * bytes, JSON.parse, canonicalize via src/jcs.ts, and write the canonical
 * bytes to `<outdir>/fuzz-NNNN.bin`. The orchestrator diffs these files
 * against the Elixir .bin files (cross-runtime verdict) and against the
 * .json bytes themselves (fixpoint verdict — the inputs are canonical by
 * construction); this script itself renders no verdict.
 *
 * Usage: node worker/scripts/fuzz-check.ts <gendir> <outdir>
 * (node v24 native type-stripping; no build step, no dependencies.)
 */
import { mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { canonicalize } from "../src/jcs.ts";

const genDir = process.argv[2];
const outDir = process.argv[3];
if (!genDir || !outDir) {
  console.error("usage: node fuzz-check.ts <gendir> <outdir>");
  process.exit(2);
}

mkdirSync(outDir, { recursive: true });

const cases = readdirSync(genDir)
  .filter((name) => name.endsWith(".json"))
  .sort();

for (const name of cases) {
  const inputBytes = readFileSync(join(genDir, name));
  const value: unknown = JSON.parse(inputBytes.toString("utf8"));
  const binName = name.replace(/\.json$/, ".bin");
  writeFileSync(join(outDir, binName), canonicalize(value));
}

console.error(
  `fuzz-check.ts: canonicalized ${cases.length} cases from ${genDir} into ${outDir}`,
);
