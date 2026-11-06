# Deploying the website

Nothing is deployed today. The site builds to static files in `website/dist/`, and every page carries `noindex, nofollow` with a `Disallow: /` robots.txt until publication is approved.

## Before the first deploy

These need the owner's decision. Each is enforced by `node scripts/validate-release.mjs --for-publication`:

| Decision | Where |
| --- | --- |
| Domain, e.g. `https://stillleaf.app` | `site.origin` in `src/site-config.js` |
| Support and privacy contact address | `site.contactEmail` |
| Legal publisher (person or company) and effective date | `site.legal` |
| A verified, notarized Mac release | `macos` entry in `src/releases.js` |
| Authorization to publish | `publication.approved` in `src/releases.js` |

Then also review the terms and privacy text (they aren't legal advice), recapture the screenshots against the release (`ASSETS.md`), and decide whether iOS shows `coming-soon` or stays `hidden`.

Once those are set, the build switches on its own: pages become indexable, canonical and Open Graph URLs become absolute, and `sitemap.xml` and the update feed (`UPDATES.md`) are written.

## Recommended host: GitHub Pages

The repository is already on GitHub, so Pages needs no new account. `.github/workflows/website-pages.yml` builds and deploys, but:

- it runs only when started by hand (Actions → Website deploy → Run workflow), and
- its publication-gate step fails today, so the deploy job never runs.

One-time setup when you're ready: in the repository settings, set Pages → Source to **GitHub Actions**, add the custom domain there, and create the DNS records GitHub shows (an `ALIAS`/`A` record for the apex domain, or a `CNAME` for a subdomain). Turn on **Enforce HTTPS** once the certificate is issued.

The site uses root-relative URLs (`base: "/"` in `vite.config.js`), so it expects its own domain. To preview at `https://<user>.github.io/<repo>/` instead, build with `npx vite build --base=/<repo>/`. In that case the shared header's root links won't resolve, so don't publish that way.

### Headers

GitHub Pages can't set custom response headers. The build adds the Content-Security-Policy as a `<meta>` tag, which covers scripts, styles, images, fonts and connections. If you later move to a host that supports headers (Cloudflare Pages, Netlify), also send:

```
Content-Security-Policy: <same value as the meta tag>; frame-ancestors 'none'
X-Content-Type-Options: nosniff
Referrer-Policy: strict-origin-when-cross-origin
Cache-Control: public, max-age=31536000, immutable   (for /assets/* only)
```

Files under `/assets/` have content hashes in their names and can be cached for a year; HTML, `/updates/*`, `robots.txt` and `sitemap.xml` should not be cached for long.

`/updates/macos.json` is read by the Mac app, which refuses redirects. Serve it from the canonical host with `Content-Type: application/json` and `Cache-Control: max-age=300`, and never redirect it (including apex to `www`). See [UPDATES.md](UPDATES.md).

## Checks before every deploy

```sh
cd website
npm ci
npm test
node scripts/validate-release.mjs --for-publication   # must pass
npm run build
npm run preview                                         # look at it
```

After deploying, confirm that `/updates/macos.json` serves the new release (if any) with status 200 and no redirect, that `robots.txt` allows crawling, and that a page's source shows `index, follow`.
