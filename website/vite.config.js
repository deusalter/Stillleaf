import { defineConfig } from "vite";
import { fileURLToPath } from "node:url";
import { pages } from "./src/site-build.js";
import { stillleafSite } from "./scripts/site-plugin.mjs";

const input = Object.fromEntries(
  pages.map(({ file, path }) => [
    path === "/" ? "main" : path.replaceAll("/", ""),
    fileURLToPath(new URL(file, import.meta.url)),
  ]),
);
input.notFound = fileURLToPath(new URL("404.html", import.meta.url));

export default defineConfig({
  // Root-relative URLs: the site is served from the root of its own domain.
  // For a GitHub Pages project URL, build with --base=/<repository>/.
  base: "/",
  plugins: [stillleafSite()],
  server: { host: "127.0.0.1", port: 4173, strictPort: true },
  preview: { host: "127.0.0.1", port: 4173, strictPort: true },
  build: {
    target: ["es2022", "safari16"],
    assetsInlineLimit: 0,
    rollupOptions: { input },
  },
});
