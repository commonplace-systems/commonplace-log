// Types Vite's `?raw` imports of project source files (used by the R6 lane
// dataflow gate in read_capability.workers.test.ts, which imports
// src/realm/node.ts and src/realm/container.ts as text). Unlike the exact-name
// ambient declarations in spec-raw.d.ts/proposal-raw.d.ts — which never match
// relative import paths — a WILDCARD ambient module declaration does match
// relative specifiers, so this covers `../../src/realm/node.ts?raw` directly.
// Must stay a script (no top-level import/export) to remain ambient.
declare module "*?raw" {
  const content: string;
  export default content;
}
