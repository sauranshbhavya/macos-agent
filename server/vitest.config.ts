import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
    // Migration tests need a real Postgres and are skipped when DATABASE_URL is unset, so the
    // default `npm test` runs with no external dependency. See test/migrate.test.ts.
    environment: "node",
  },
});
