import { configDefaults, defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    projects: [
      // Plain-node unit suite (SP1): everything under test/ except test/do/**.
      {
        test: {
          name: "unit",
          globals: true,
          include: ["test/**/*.test.ts"],
          exclude: [...configDefaults.exclude, "test/do/**", "test/realm/**/*.workers.test.ts", "test/backup/**"],
        },
      },
      // Durable Object suite: runs inside workerd via @cloudflare/vitest-pool-workers.
      "./vitest.workers.config.ts",
      "./vitest.backup.config.ts",
    ],
  },
});
