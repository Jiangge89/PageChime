import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // @peculiar/x509 (used only to build test certificates) needs this polyfill.
    setupFiles: ["reflect-metadata"],
  },
});
