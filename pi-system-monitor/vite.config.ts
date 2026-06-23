import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import type { Plugin } from 'vite';

// Appends an explicit window assignment so Home Screens can find the plugin
// regardless of whether var declarations become window properties in the host.
function hsPluginExport(): Plugin {
  return {
    name: 'hs-plugin-export',
    generateBundle(_, bundle) {
      for (const chunk of Object.values(bundle)) {
        if (chunk.type === 'chunk' && chunk.fileName === 'bundle.js') {
          chunk.code += '\nwindow.__HS_PLUGIN__ = { default: __HS_PLUGIN__, __esModule: true };';
        }
      }
    },
  };
}

export default defineConfig({
  plugins: [react(), hsPluginExport()],
  define: {
    'process.env.NODE_ENV': JSON.stringify('production'),
  },
  build: {
    lib: {
      entry:    'src/index.tsx',
      name:     '__HS_PLUGIN__',
      fileName: () => 'bundle.js',
      formats:  ['iife'],
    },
    rollupOptions: {
      external: ['react', 'react-dom'],
      output:   { globals: { react: 'React', 'react-dom': 'ReactDOM' } },
    },
    outDir:     'dist',
    emptyOutDir: true,
  },
});
