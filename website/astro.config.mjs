import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://ghosthub.ai',
  vite: {
    build: {
      // Embed the woff2 faces in the render-blocking stylesheet so text first
      // paints in its final typeface instead of a fallback that swaps later.
      assetsInlineLimit: (filePath) => (filePath.endsWith('.woff2') ? true : undefined),
    },
  },
});
