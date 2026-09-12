# Restore test collection diagnostic

The first focused worker run collected the schema control but reported zero tests
for the restore test. The cause was filename classification, not the test module
or restore product code.

The installed Wrangler default Data rule is the unanchored glob `**/*.bin`
(`node_modules/wrangler/wrangler-dist/cli.js`, line 171043). Miniflare's
`compileModuleRules` turns that rule into an unanchored regular expression. The
pool's module handling (`@cloudflare/vitest-pool-workers`, `index.mjs`, line
7810) externalizes any matching module. Consequently
`restore.binding.workers.test.ts` matched the generated pattern, was
externalized as `?mf_vitest_force=Data`, and never received the TypeScript
transform. `schema.workers.test.ts` did not match and collected normally.

The focused test is therefore named `restore-authority.workers.test.ts`, with
its content unchanged. This diagnostic is for local runner evidence only; it
does not change Wrangler configuration or production code.
