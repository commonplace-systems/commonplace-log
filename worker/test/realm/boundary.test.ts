import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, extname, join, relative, resolve } from "node:path";
import { describe, expect, test } from "vitest";

const WORKER_ROOT = resolve(import.meta.dirname, "../..");
const DEFAULT_REALM_ROOT = resolve(WORKER_ROOT, "src/realm");
const REQUIRED_REALM_ENTRIES = ["node.ts", "outbound.ts"];
const FORBIDDEN = new Set([
  resolve(WORKER_ROOT, "src/entry.ts"),
  resolve(WORKER_ROOT, "src/jcs.ts"),
  resolve(WORKER_ROOT, "src/do/merge-plan.ts"),
]);

function sourceFiles(root: string): string[] {
  if (!existsSync(root)) return [];
  const files: string[] = [];
  for (const name of readdirSync(root)) {
    const path = join(root, name);
    if (statSync(path).isDirectory()) files.push(...sourceFiles(path));
    else if ([".ts", ".tsx", ".mts", ".cts"].includes(extname(path))) files.push(path);
  }
  return files;
}

function resolveImport(from: string, specifier: string): string | null {
  if (!specifier.startsWith(".")) return null;
  const base = resolve(dirname(from), specifier);
  for (const candidate of [base, `${base}.ts`, `${base}.tsx`, join(base, "index.ts")]) {
    if (existsSync(candidate) && statSync(candidate).isFile()) return candidate;
  }
  return null;
}

function importsOf(path: string): string[] {
  const source = readFileSync(path, "utf8");
  const imports: string[] = [];
  const pattern = /(?:import|export)\s+(?:type\s+)?(?:[^"']*?\s+from\s+)?["']([^"']+)["']|import\s*\(\s*["']([^"']+)["']\s*\)/g;
  for (const match of source.matchAll(pattern)) imports.push(match[1] ?? match[2]!);
  return imports;
}

export function assertRealmBoundary(root: string): void {
  const entries = sourceFiles(root);
  if (entries.length === 0) {
    throw new Error(`realm boundary gate found no TypeScript source files under ${root}`);
  }

  if (root === DEFAULT_REALM_ROOT) {
    for (const name of REQUIRED_REALM_ENTRIES) {
      const required = resolve(root, name);
      if (!entries.includes(required)) {
        throw new Error(`realm boundary gate is missing required entry ${relative(WORKER_ROOT, required)}`);
      }
    }
  }

  const visited = new Set<string>();
  const visit = (path: string, chain: string[]): void => {
    if (FORBIDDEN.has(path)) {
      throw new Error(
        `realm boundary violation: ${chain.map((item) => relative(WORKER_ROOT, item)).join(" -> ")}`,
      );
    }
    if (visited.has(path)) return;
    visited.add(path);
    for (const specifier of importsOf(path)) {
      const dependency = resolveImport(path, specifier);
      if (dependency !== null) visit(dependency, [...chain, dependency]);
    }
  };

  for (const entry of entries) visit(entry, [entry]);
}

describe("realm semantic boundary", () => {
  test("the realm import graph cannot reach workalike semantic modules", () => {
    assertRealmBoundary(process.env.REALM_GATE_ROOT ?? DEFAULT_REALM_ROOT);
  });

  test("the scanner rejects an empty realm subtree", () => {
    expect(() => assertRealmBoundary(resolve(import.meta.dirname, "fixtures/empty"))).toThrow(
      "realm boundary gate found no TypeScript source files",
    );
  });
});
