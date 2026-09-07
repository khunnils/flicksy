// @ts-check
import { defineConfig } from 'astro/config';
import cloudflare from '@astrojs/cloudflare';

// https://astro.build/config
export default defineConfig({
  site: 'https://flicksy.me',
  trailingSlash: 'never',
  adapter: cloudflare({
    imageService: 'passthrough',
  }),
  session: false,
  server: {
    port: 4700,
  },
  vite: {
    define: {
      'import.meta.env.FLICKSY_DEPLOY_ENV': JSON.stringify(process.env.CLOUDFLARE_ENV ?? 'production'),
    },
    optimizeDeps: {
      // Pre-bundle modules Vite only reaches through virtual imports. Late
      // discovery rehashes deps_ssr chunks and crashes the Cloudflare worker.
      include: ['astro/app/manifest', 'astro/assets/services/noop'],
    },
  },
});
