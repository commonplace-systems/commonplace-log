// The spec document as a string, inlined at transform time via the resolve
// alias in vitest.workers.config.ts (used by the §12 DDL fidelity gate in
// schema.test.ts). The specifier is non-relative because TypeScript ambient
// module declarations never match relative import paths — and this file must
// stay a script (no top-level import/export), or the declaration would be
// treated as an augmentation of a nonexistent module instead of ambient.
declare module "commonplace-monotonic-log-spec.md?raw" {
  const content: string;
  export default content;
}
