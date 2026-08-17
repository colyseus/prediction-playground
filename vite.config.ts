import { defineConfig } from 'vite';
import { colyseus } from 'colyseus/vite';

// The colyseus/vite plugin declares a second build environment (dist/server) and
// sets `builder: {}`, which makes EVERY `vite build` build both — `--app` is
// redundant and the plugin has no opt-out. Vercel only ships the client, so
// BUILD_TARGET=client drops the plugin and re-declares the outDir it would set.
const clientOnly = process.env.BUILD_TARGET === 'client';

export default defineConfig({
  build: { outDir: 'dist/client' },
  plugins: [
    ...(clientOnly ? [] : [colyseus({ serverEntry: '/src/server/index.ts' })]),
  ],
});
