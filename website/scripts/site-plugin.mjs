import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { releases } from "../src/releases.js";
import { site, validateSite } from "../src/site-config.js";
import {
  fillTokens,
  headTags,
  publicPath,
  robotsTxt,
  sitemapXML,
} from "../src/site-build.js";
import { updateFeedFiles } from "../src/update-feed.js";

const badge = fileURLToPath(new URL("../public/badges/app-store.svg", import.meta.url));

/**
 * Finishes pages from src/site-config.js and src/releases.js: fills tokens,
 * adds robots/canonical/Open Graph tags, and writes robots.txt, sitemap.xml
 * and the update feed. Gated output (sitemap, feed, indexable robots) only
 * appears once publication is approved; see README.md.
 */
export function stillleafSite() {
  return {
    name: "stillleaf-site",
    buildStart() {
      const errors = validateSite(site);
      if (site.ios.state === "available" && !existsSync(badge))
        errors.push(
          "iOS is available but public/badges/app-store.svg is missing. Add Apple's official badge (ASSETS.md).",
        );
      if (errors.length) throw new Error(`Site configuration failed:\n  - ${errors.join("\n  - ")}`);
    },
    transformIndexHtml: {
      order: "pre",
      handler(html, context) {
        return {
          html: fillTokens(html, site),
          tags: headTags(publicPath(context.path), site, undefined, {
            csp: !context.server,
          }),
        };
      },
    },
    generateBundle() {
      this.emitFile({ type: "asset", fileName: "robots.txt", source: robotsTxt(site) });
      const sitemap = sitemapXML(site);
      if (sitemap) this.emitFile({ type: "asset", fileName: "sitemap.xml", source: sitemap });
      for (const file of updateFeedFiles(releases, site))
        this.emitFile({ type: "asset", ...file });
    },
  };
}
