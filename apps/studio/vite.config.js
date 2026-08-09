import { defineConfig } from 'vite';

export default defineConfig({
  // The packages are plain TypeScript sources consumed directly — no build
  // step, no dist/. Vite transpiles them along with the app, which keeps a
  // single source of truth and means a change in a package is live in the app.
  server: { host: true },
  build: { target: 'es2022', sourcemap: true },
});
