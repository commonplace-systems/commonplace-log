import path from "node:path";
import { defineWorkersProject } from "@cloudflare/vitest-pool-workers/config";

export default defineWorkersProject({
  resolve: {
    alias: {
      // Non-relative specifier for the spec document so tests can `?raw`-import
      // it with proper types (TS ambient module declarations never match
      // relative paths). Used by the §12 DDL fidelity gate in schema.test.ts.
      "commonplace-monotonic-log-spec.md?raw": `${path.resolve(
        import.meta.dirname,
        "../docs/commonplace-monotonic-log-spec.md",
      )}?raw`,
    },
  },
  test: {
    name: "do",
    include: ["test/do/**/*.test.ts"],
    poolOptions: {
      workers: {
        wrangler: { configPath: "./wrangler.jsonc" },
      },
    },
  },
});
