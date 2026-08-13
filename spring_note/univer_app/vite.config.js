import { defineConfig } from 'vite';

export default defineConfig({
  base: './',
  build: {
    outDir: 'dist',
    chunkSizeWarningLimit: 4000,
    worker: {
      format: 'es',
    },
  },
  server: {
    port: 5177,
    strictPort: true,
  },
});
