# Gallager website restructure (design)

- **Date:** 2026-07-20
- **Status:** Approved (design); pending implementation plan
- **Feature area:** Marketing website (gallager.app)
- **Related:** `docs/self-hosting.md` (deploy.sh conventions), issue #664 / PR #666
  (updates.gallager.app hosting pattern this mirrors)

## Summary

Replace the four self-contained artifact-export pages in `deploy/` (index, docs,
pricing, security) with an **Astro** static site in a new top-level `website/`
directory. Shared chrome (design-system CSS, nav, footer, page-header pattern,
fonts, logo) is extracted into one copy each; per-page content becomes plain
Astro pages; the artifact runtime (React, ReactDOM, dc-runtime, self-unpacking
loader) is dropped entirely. Deployment wiring is included: a Caddy vhost for
`gallager.app` on the existing Hetzner relay box plus a `website` mode in
`scripts/deploy.sh`, mirroring the `updates.gallager.app` flow. `deploy/` is
deleted once the port is verified.

## Motivation

Each current page is a ~360–390KB self-unpacking bundle:

- The real page content (~20–46KB of HTML) is stored as a JSON-encoded template
  string; JS reconstructs the page at load time. No JS → blank page; poor SEO,
  slow first paint.
- Every page duplicates the 13.7KB "Modernist" design-system CSS, three Archivo
  woff2 fonts (~105KB), a 123KB logo PNG, and the nav/footer markup. The CSS and
  chrome have **already drifted** between pages.
- Each bundle also embeds React + ReactDOM (~142KB) that nothing references.
- Adding a page means copying a 360KB blob and editing inside a JSON string.

The only real interactivity across the whole site is a FAQ accordion (index) and
a monthly/annual toggle (pricing).

## Decisions (settled during brainstorming)

| Decision | Choice |
| --- | --- |
| Hosting | `gallager.app` apex on the Hetzner relay box, served by the existing Caddy |
| Tooling | Static site generator: **Astro** (npm, static output, zero client JS by default) |
| Source location | New `website/` dir at repo root; **`deploy/` deleted** after port verification |
| Scope | Includes deploy wiring (Caddy vhost + `deploy.sh website`) |
| Port fidelity | **Full cleanup pass**: repeated inline styles promoted to design-system classes; the rendered look stays identical |

---

## Project structure

```
website/
  package.json            # astro + @astrojs/sitemap; npm
  astro.config.mjs        # site: https://gallager.app, static output
  README.md               # dev/build/deploy instructions
  public/
    fonts/                # Archivo woff2 ×3 subsets (self-hosted, extracted from the bundles)
    favicon.svg           # orange "G" mark (exists as SVG in the current bundles)
    logo.png              # optimized; current 123KB PNG downscaled for its 28px usage
    robots.txt
  src/
    styles/modernist.css  # THE design system: tokens + component classes, one copy
    layouts/Base.astro    # html skeleton → head (meta/title/OG/fonts/css) + Nav + <slot/> + Footer
    components/
      Nav.astro           # active-link highlight derived from Astro.url
      Footer.astro
      Hero.astro          # eyebrow/h1/lede page-header pattern shared by all 4 pages
    pages/
      index.astro
      docs.astro
      pricing.astro
      security.astro
      404.astro
```

Adding a page = create `src/pages/foo.astro`, wrap content in `Base`, use
existing classes. Nav/footer/CSS update in exactly one place.

Fonts stay self-hosted (no Google Fonts request — consistent with the product's
privacy stance). The `@font-face` blocks live in `modernist.css` and point at
`/fonts/…`.

## Cleanup pass

- `modernist.css` becomes the single source of truth for the look (its own
  header comment already claims this). The drift between the four current copies
  collapses into one file.
- Repeated inline-style patterns are promoted to classes: the 1200px container,
  section spacing, hero type sizes, card grids, button size variants,
  mono-caption text. Genuinely one-off styles may remain inline.
- The rendered result must be visually identical to the current pages
  (verification below).

## Interactivity — no framework

- Index FAQ accordion: styled `<details>`/`<summary>` if it can match the
  current look, else a few lines of vanilla JS in a page `<script>`.
- Pricing monthly/annual toggle: small vanilla `<script>` swapping
  price/period/note text.
- React, ReactDOM, and the 66KB dc-runtime are dropped. No client framework.

Net effect: pages go from ~380KB requiring JS to render, to roughly 15–50KB of
real HTML that renders without JS and is crawlable, with proper per-page
`<title>`/meta-description/OG tags and a generated sitemap.

## Deploy wiring

Mirrors the `updates.gallager.app` pattern (#666):

- `ClaudeSpyPackage/caddy/website.caddy`: vhost for `gallager.app` +
  `www.gallager.app` (www 308-redirects to apex), `root /opt/gallager-website`,
  `file_server`, long-lived `Cache-Control` for hashed `/_astro/*` assets and
  `/fonts/*`.
- `scripts/deploy.sh website`: `npm ci && npm run build` in `website/`, rsync
  `website/dist/` → `/opt/gallager-website` on the deploy host (same
  `DEPLOY_HOST` > `hcloud cleancast` resolution as updates), install the Caddy
  config, reload Caddy.
- Manual one-time step (documented in `website/README.md`, not scripted): DNS A
  records for `gallager.app` and `www.gallager.app` pointing at the box; Caddy
  then provisions per-hostname LE certs automatically.

## Verification

- Build locally (`npm run build`, `npm run preview`) and compare each page
  side-by-side against the current rendered bundles before deleting `deploy/`.
- `deploy/` is currently **untracked**, so plain deletion would lose the
  originals: commit `deploy/` as-is in the first commit of the implementation
  branch, then delete it in the final commit — git history preserves the
  bundles (the `__bundler/template` script block JSON-decodes back to each
  page's HTML if ever needed).
- Check the FAQ accordion and pricing toggle behave as they do today.
- After deploy: `curl -I https://gallager.app` returns 200 with HTML,
  `www.gallager.app` redirects to apex, fonts and hashed assets serve with
  cache headers.

## Out of scope (structure accommodates later without rework)

- Markdown content collections (worth adding when docs grow beyond one page;
  Starlight is the natural path if docs expand substantially).
- CI build-check on `website/**` PRs.
- A blog.
