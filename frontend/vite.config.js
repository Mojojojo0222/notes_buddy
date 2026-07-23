import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      '/commands': { target: 'http://localhost:9098', changeOrigin: true },
      '/summary': { target: 'http://localhost:9098', changeOrigin: true },
      '/sessions': { target: 'http://localhost:9098', changeOrigin: true },
      '/ingest': { target: 'http://localhost:9098', changeOrigin: true },
      '/actuator': { target: 'http://localhost:9098', changeOrigin: true },
      '/h2-console': { target: 'http://localhost:9098', changeOrigin: true },
    },
  },
  build: {
    outDir: process.env.VITE_OUT_DIR || '../src/main/resources/static',
    emptyOutDir: true,
  },
});
