import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
    environment: "node",
    // Announces the database skip before the reporter owns the terminal. A console.warn inside an
    // all-skipped file is swallowed, which is how three documents came to claim a loudness the run
    // did not have.
    globalSetup: ["test/global-setup.ts"],
  },
});
