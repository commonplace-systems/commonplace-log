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
      "beam-native-revision.md?raw": `${path.resolve(
        import.meta.dirname,
        "../docs/proposals/2026-08-22-beam-native-revision.md",
      )}?raw`,
    },
  },
  test: {
    name: "do",
    include: ["test/do/**/*.test.ts", "test/realm/**/*.workers.test.ts"],
    poolOptions: {
      workers: {
        // Deliberately container-free (wrangler.jsonc carries the containers stanza, which the pool rejects): workerd's test pool supplies no
        // `ctx.container`, so ingress exercises its REALM_CONTAINER fallback.
        wrangler: { configPath: "./wrangler.test.jsonc" },
        // Test-only gateway secret. In production GATEWAY_TOKEN is a Worker
        // secret; it must never appear as a plaintext var in wrangler.jsonc.
        miniflare: { bindings: { GATEWAY_TOKEN: "test-gateway-token" } },
      },
    },
  },
});
