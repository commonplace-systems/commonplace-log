import { defineWorkersConfig } from "@cloudflare/vitest-pool-workers/config";

export default defineWorkersConfig({
  test: {
    name: "backup",
    include: ["test/backup/**/*.test.ts"],
    poolOptions: { workers: { wrangler: { configPath: "./wrangler.backup.test.jsonc" } } },
  },
});
