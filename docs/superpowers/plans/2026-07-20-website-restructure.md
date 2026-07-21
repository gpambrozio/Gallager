# Gallager Website Restructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the four self-unpacking artifact bundles in `deploy/` with an Astro static site in `website/` sharing one design system, one nav, one footer — plus Caddy vhost and `deploy.sh website` deployment.

**Architecture:** Astro 5 static output. Shared chrome lives in `src/layouts/Base.astro` + `src/components/{Nav,Footer,Hero}.astro`; the "Modernist" design-system CSS becomes the single `src/styles/modernist.css`; page content (currently `sc-for` loops fed by DCLogic data in each bundle) becomes frontmatter const arrays rendered with `.map()`. The only client JS on the whole site is the index FAQ accordion.

**Tech Stack:** Astro ^5, @astrojs/sitemap, vanilla JS, Caddy (existing box), bash (deploy.sh), python3 (one-off extraction script).

**Spec:** `docs/superpowers/specs/2026-07-20-website-structure-design.md`

## Global Constraints

- Node ≥ 20 with npm (dev machine has v24.4.1 / 11.4.2). No other new toolchains.
- No client framework — no React, no dc-runtime. Only the FAQ accordion ships JS.
- Rendered pages must look identical to the originals, except the deliberate normalizations called out inside tasks (each is listed where it happens).
- Internal links are root-relative with trailing slash: `/`, `/docs/`, `/pricing/`, `/security/`, `/#download`. Never `*.html`.
- All work on branch `website-restructure`. Commit at the end of every task.
- `deploy/` is untracked today. Task 1 commits it verbatim FIRST so git history preserves the originals; Task 11 deletes it.
- The original bundles' pages have NO `@media` queries. Do not add responsive rules — faithful port.
- macOS-only helper tools are fine (`sips`, `python3`) — this is a maintainer-machine workflow.

## Reading the originals (context for every page task)

Each `deploy/<page>.html` is a self-unpacking bundle. The real page markup is the JSON string inside `<script type="__bundler/template">`; binary assets are in `<script type="__bundler/manifest">` (UUID → base64, sometimes gzipped). Task 1's script decodes these into `website/.originals/` — after that, never read `deploy/` directly.

Inside an extracted original:

- The head has the design-system CSS in the first `<style>` block.
- The body is one wrapper `<div>` (page background/font) containing `<nav>`, `<header>`, content sections, `<footer>`.
- Dynamic content uses `<sc-for list="{{ items }}" as="x">…{{ x.field }}…</sc-for>` loops whose data lives in the page's `<script type="text/x-dc">` as `renderVals()` return values. **That DCLogic data is the authoritative content.** (The docs page also contains a pre-rendered copy of some content in its body — trust the DCLogic data and the rendered page, not stray fallback markup.)
- To see a rendered original: `python3 -m http.server 8899 --directory deploy` and open `http://localhost:8899/<page>.html` (they need JS to render).

---

### Task 1: Branch, snapshot originals, extraction script

**Files:**
- Create: `scripts/extract-website-originals.py`
- Commit (verbatim, first commit): `deploy/index.html`, `deploy/docs.html`, `deploy/pricing.html`, `deploy/security.html` (NOT `deploy/.DS_Store`)

**Interfaces:**
- Produces: `website/.originals/{index,docs,pricing,security}.html` (decoded page markup), `website/.originals/modernist.css`, `website/.originals/logo-full.png`, `website/public/fonts/archivo-{vietnamese,latin-ext,latin}.woff2`, `website/public/favicon.svg`. All later tasks read from `website/.originals/`, never from `deploy/`.

- [ ] **Step 1: Create the branch and snapshot the untracked originals**

```bash
git checkout -b website-restructure
git add deploy/index.html deploy/docs.html deploy/pricing.html deploy/security.html
git commit -m "Snapshot original website artifact bundles before Astro port"
```

- [ ] **Step 2: Write the extraction script**

Create `scripts/extract-website-originals.py`:

```python
#!/usr/bin/env python3
"""One-off extractor for the artifact bundles in deploy/.

Decodes each deploy/*.html self-unpacking bundle into:
  website/.originals/<page>.html    the real page markup (JSON-decoded template)
  website/.originals/modernist.css  the shared design-system CSS (from index)
  website/.originals/logo-full.png  the full-size logo
  website/public/fonts/*.woff2      the three Archivo subsets
  website/public/favicon.svg        the orange G mark

Part of the Astro port (docs/superpowers/plans/2026-07-20-website-restructure.md).
Delete this script together with deploy/ once the port is verified.
"""
import base64
import gzip
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEPLOY = ROOT / "deploy"
ORIGINALS = ROOT / "website" / ".originals"
PUBLIC = ROOT / "website" / "public"
# @font-face src order in the design CSS (each subset repeats for 3 weights).
FONT_SUBSETS = ["vietnamese", "latin-ext", "latin"]


def read_block(text, kind):
    m = re.search(
        rf'<script type="__bundler/{kind}">\n(.*?)\n  </script>', text, re.S
    )
    if not m:
        sys.exit(f"missing __bundler/{kind} block")
    return m.group(1)


def asset_bytes(entry):
    raw = base64.b64decode(entry["data"])
    return gzip.decompress(raw) if entry.get("compressed") else raw


def main():
    ORIGINALS.mkdir(parents=True, exist_ok=True)
    (PUBLIC / "fonts").mkdir(parents=True, exist_ok=True)

    for page in sorted(DEPLOY.glob("*.html")):
        text = page.read_text()
        template = json.loads(read_block(text, "template"))
        manifest = json.loads(read_block(text, "manifest"))
        (ORIGINALS / page.name).write_text(template)

        if page.stem != "index":
            continue

        # Shared design-system CSS: first <style> block of the template head.
        css = re.search(r"<style>(.*?)</style>", template, re.S).group(1)
        (ORIGINALS / "modernist.css").write_text(css)

        # Fonts, deduped in first-appearance order (vietnamese, latin-ext, latin).
        seen = []
        for uuid in re.findall(r'src: url\("([0-9a-f-]+)"\)', css):
            if uuid not in seen:
                seen.append(uuid)
        if len(seen) != len(FONT_SUBSETS):
            sys.exit(f"expected {len(FONT_SUBSETS)} font files, found {len(seen)}")
        for uuid, subset in zip(seen, FONT_SUBSETS):
            (PUBLIC / "fonts" / f"archivo-{subset}.woff2").write_bytes(
                asset_bytes(manifest[uuid])
            )

        # Logo: the manifest's only image/png.
        pngs = [v for v in manifest.values() if v["mime"] == "image/png"]
        if len(pngs) != 1:
            sys.exit(f"expected 1 png in manifest, found {len(pngs)}")
        (ORIGINALS / "logo-full.png").write_bytes(asset_bytes(pngs[0]))

        # Favicon: the orange G placeholder SVG in the loader shell.
        svg = re.search(
            r'<div id="__bundler_thumbnail">(<svg.*?</svg>)', text
        ).group(1)
        (PUBLIC / "favicon.svg").write_text(svg + "\n")

    print("extracted OK")


if __name__ == "__main__":
    main()
```

- [ ] **Step 3: Run it and verify outputs**

```bash
chmod +x scripts/extract-website-originals.py
./scripts/extract-website-originals.py
ls -la website/.originals website/public/fonts website/public
```

Expected: `extracted OK`; `.originals/` has 4 `.html` (≈20–46KB each, index largest), `modernist.css` (≈13.7KB), `logo-full.png` (≈123KB); `public/fonts/` has 3 `.woff2` (≈30–40KB each); `public/favicon.svg` exists. Sanity: `grep -c sc-for website/.originals/security.html` → `1`.

- [ ] **Step 4: Commit**

```bash
git add scripts/extract-website-originals.py website/public
git commit -m "Add website originals extraction script; extract fonts + favicon"
```

(`website/.originals/` stays uncommitted — Task 2's `.gitignore` covers it; regenerate anytime with the script.)

---

### Task 2: Astro scaffold

**Files:**
- Create: `website/package.json`, `website/astro.config.mjs`, `website/tsconfig.json`, `website/.gitignore`, `website/src/pages/index.astro` (placeholder), `website/public/robots.txt`

**Interfaces:**
- Produces: `npm run dev` / `npm run build` / `npm run preview` working in `website/`; `Astro.site = https://gallager.app`; sitemap integration active. Committed `package-lock.json` (deploy uses `npm ci`).

- [ ] **Step 1: Write the config files**

`website/package.json`:

```json
{
  "name": "gallager-website",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "astro dev",
    "build": "astro build",
    "preview": "astro preview"
  },
  "dependencies": {
    "astro": "^5.0.0",
    "@astrojs/sitemap": "^3.0.0"
  }
}
```

`website/astro.config.mjs`:

```js
import { defineConfig } from "astro/config";
import sitemap from "@astrojs/sitemap";

export default defineConfig({
  site: "https://gallager.app",
  integrations: [sitemap()],
});
```

`website/tsconfig.json`:

```json
{ "extends": "astro/tsconfigs/base" }
```

`website/.gitignore`:

```
node_modules/
dist/
.astro/
.originals/
```

`website/public/robots.txt`:

```
User-agent: *
Allow: /

Sitemap: https://gallager.app/sitemap-index.xml
```

Placeholder `website/src/pages/index.astro` (replaced in Task 5):

```astro
---
---

<html lang="en">
  <body>
    <h1>Gallager — placeholder</h1>
  </body>
</html>
```

- [ ] **Step 2: Install and build**

```bash
cd website && npm install && npm run build
```

Expected: build succeeds; `dist/index.html` and `dist/sitemap-index.xml` exist:

```bash
ls dist/index.html dist/sitemap-index.xml dist/robots.txt dist/favicon.svg dist/fonts
```

- [ ] **Step 3: Commit**

```bash
cd .. && git add website/package.json website/package-lock.json website/astro.config.mjs website/tsconfig.json website/.gitignore website/src/pages/index.astro website/public/robots.txt
git commit -m "Scaffold Astro project for gallager.app website"
```

---

### Task 3: Design-system stylesheet

**Files:**
- Create: `website/src/styles/modernist.css`

**Interfaces:**
- Consumes: `website/.originals/modernist.css`, fonts in `website/public/fonts/`.
- Produces: the site's ONLY stylesheet. Existing design-system classes (`.nav`, `.nav-brand`, `.btn`, `.btn-primary`, `.btn-secondary`, `.card`, `.card-kicker`, `.text-muted`, `.hr`, `.tag*`, tokens `--space-*`, `--color-*`, `--font-*`) PLUS the site-addition classes defined below, which all later tasks use: `.page`, `.container`, `.mono`, `.page-hero` (+ `.eyebrow`, `.lede`, variants `--display`, `--tight`), `.section`, `.section-rule`, `.footer`, `.footer-inner`, `.faq-item` (+ `.faq-q`, `.faq-arrow`, `.faq-a`, `.open`).

- [ ] **Step 1: Copy the extracted CSS and rewrite font URLs**

```bash
cp website/.originals/modernist.css website/src/styles/modernist.css
```

The file has nine `@font-face` blocks (3 subsets × 3 weights) whose `src: url("<uuid>")` reference bundle assets. Replace each UUID URL with the real file by its subset comment (`/* vietnamese */`, `/* latin-ext */`, `/* latin */` immediately above each block):

- vietnamese blocks → `src: url("/fonts/archivo-vietnamese.woff2") format('woff2');`
- latin-ext blocks → `src: url("/fonts/archivo-latin-ext.woff2") format('woff2');`
- latin blocks → `src: url("/fonts/archivo-latin.woff2") format('woff2');`

Verify no UUIDs remain: `grep -c 'url("[0-9a-f-]\{36\}")' website/src/styles/modernist.css` → `0`.

- [ ] **Step 2: Append the site additions**

Append to the END of `website/src/styles/modernist.css`:

```css
/* ------------------------------------------------------------------ */
/* Site additions — shared chrome + patterns promoted from repeated    */
/* inline styles during the 2026-07 Astro port.                        */
/* ------------------------------------------------------------------ */

html,
body {
  margin: 0;
  padding: 0;
}

.page {
  min-height: 100vh;
  background: var(--color-bg);
  color: var(--color-text);
  font-family: var(--font-body);
}

.container {
  max-width: 1200px;
  margin: 0 auto;
}

.mono {
  font-family: ui-monospace, Menlo, monospace;
}

.nav-brand img {
  width: 28px;
  height: 28px;
}

/* Page hero: eyebrow + h1 + lede header shared by every page. */
.page-hero {
  padding: var(--space-8) var(--space-4) var(--space-6);
}
.page-hero .eyebrow {
  color: var(--color-accent);
  margin-bottom: var(--space-3);
}
.page-hero h1 {
  font-size: 52px;
  max-width: 820px;
  margin-bottom: var(--space-3);
  text-wrap: pretty;
}
.page-hero .lede {
  font-size: 17px;
  line-height: 1.65;
  max-width: 640px;
  margin: 0;
  text-wrap: pretty;
}
/* Index landing variant: bigger type, room for the download buttons. */
.page-hero--display h1 {
  font-size: 64px;
  max-width: 900px;
  margin-bottom: var(--space-4);
}
.page-hero--display .lede {
  font-size: 18px;
  line-height: 1.6;
  margin-bottom: var(--space-6);
}
/* Security variant: tighter bottom padding. */
.page-hero--tight {
  padding-bottom: var(--space-4);
}

.section {
  padding: var(--space-8) var(--space-4);
}
.section-rule {
  padding: 0 var(--space-4);
}
.section-rule .hr {
  margin: 0;
}

.footer {
  border-top: 2px solid var(--color-divider);
}
.footer-inner {
  padding: var(--space-6) var(--space-4);
  display: flex;
  align-items: center;
  gap: var(--space-6);
  flex-wrap: wrap;
  font-size: 13.5px;
}
.footer-inner a {
  color: inherit;
  text-decoration: none;
}

/* FAQ accordion (index). Open state animates grid-template-rows 0fr→1fr,
   matching the original DCLogic behavior. */
.faq-item {
  border-top: 1px solid var(--color-divider);
  padding: 0 var(--space-1);
}
.faq-q {
  cursor: pointer;
  font-weight: 600;
  font-family: var(--font-heading);
  font-size: 15.5px;
  padding: var(--space-3) 0;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--space-3);
}
.faq-arrow {
  flex: none;
  transition: transform 0.3s ease;
  color: var(--color-accent);
}
.faq-item.open .faq-arrow {
  transform: rotate(45deg);
}
.faq-a {
  display: grid;
  grid-template-rows: 0fr;
  transition: grid-template-rows 0.3s ease;
}
.faq-item.open .faq-a {
  grid-template-rows: 1fr;
}
.faq-a > div {
  overflow: hidden;
  min-height: 0;
}
.faq-a p {
  font-size: 14.5px;
  line-height: 1.7;
  padding-bottom: var(--space-4);
  margin: 0;
  max-width: 680px;
}

/* Terminal-cursor blink used by the index hero mockup. */
@keyframes blink {
  0%,
  49% {
    opacity: 1;
  }
  50%,
  100% {
    opacity: 0;
  }
}
```

**Deliberate normalization (recorded):** `.lede` unifies line-height at 1.65 (pricing's original was 1.6 — visually indistinguishable); per-page lede/h1 max-width differences are preserved via Hero props (Task 4).

- [ ] **Step 3: Build check + commit**

```bash
cd website && npm run build && cd ..
git add website/src/styles/modernist.css
git commit -m "Port Modernist design system CSS with site-addition classes"
```

---

### Task 4: Base layout + Nav/Footer/Hero components + images

**Files:**
- Create: `website/src/layouts/Base.astro`, `website/src/components/Nav.astro`, `website/src/components/Footer.astro`, `website/src/components/Hero.astro`, `website/public/logo.png`, `website/public/og-logo.png`

**Interfaces:**
- Consumes: `modernist.css` classes from Task 3; `website/.originals/logo-full.png`.
- Produces: `Base.astro` with `Props { title: string; description: string }` wrapping content in `.page` with Nav above and Footer below; `Hero.astro` with `Props { eyebrow: string; title: string; lede?: string; class?: string; titleMaxWidth?: string; ledeMaxWidth?: string }`. Page tasks 5–9 import these.

- [ ] **Step 1: Generate the optimized images**

The original 123KB PNG serves a 28px nav logo. Downscale (retina-safe):

```bash
sips -Z 128 website/.originals/logo-full.png --out website/public/logo.png
sips -Z 512 website/.originals/logo-full.png --out website/public/og-logo.png
ls -la website/public/logo.png website/public/og-logo.png
```

Expected: `logo.png` well under 20KB; `og-logo.png` under 80KB.

- [ ] **Step 2: Write the components**

`website/src/layouts/Base.astro`:

```astro
---
import "../styles/modernist.css";
import Nav from "../components/Nav.astro";
import Footer from "../components/Footer.astro";

interface Props {
  title: string;
  description: string;
}

const { title, description } = Astro.props;
const canonical = new URL(Astro.url.pathname, Astro.site);
---

<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>{title}</title>
    <meta name="description" content={description} />
    <link rel="canonical" href={canonical} />
    <link rel="icon" href="/favicon.svg" type="image/svg+xml" />
    <link rel="sitemap" href="/sitemap-index.xml" />
    <link
      rel="preload"
      href="/fonts/archivo-latin.woff2"
      as="font"
      type="font/woff2"
      crossorigin
    />
    <meta property="og:type" content="website" />
    <meta property="og:title" content={title} />
    <meta property="og:description" content={description} />
    <meta property="og:url" content={canonical} />
    <meta property="og:image" content={new URL("/og-logo.png", Astro.site)} />
    <meta name="twitter:card" content="summary" />
    <meta name="generator" content={Astro.generator} />
  </head>
  <body>
    <div class="page">
      <Nav />
      <slot />
      <Footer />
    </div>
  </body>
</html>
```

`website/src/components/Nav.astro`:

```astro
---
const links = [
  { href: "/docs/", label: "Docs" },
  { href: "/pricing/", label: "Pricing" },
  { href: "/security/", label: "Security" },
];
const path = Astro.url.pathname;
---

<nav class="nav container">
  <a href="/" class="nav-brand">
    <img src="/logo.png" alt="Gallager" width="28" height="28" />
    Gallager
  </a>
  {
    links.map((l) => (
      <a href={l.href} aria-current={path === l.href ? "page" : undefined}>
        {l.label}
      </a>
    ))
  }
  <a href="https://github.com/gpambrozio/Gallager">GitHub</a>
  <a href="/#download" class="btn btn-primary">Download</a>
</nav>
```

Check the extracted originals' `<nav class="nav" …>` markup: the existing `.nav`/`.nav-brand` rules in `modernist.css` must cover the inline styles the originals put on those elements (`max-width:1200px;margin:0 auto` is `.container`; `display:flex;align-items:center;gap:10px;color:inherit;text-decoration:none;margin-right:auto` should already be in `.nav-brand` — if any declaration is missing from the existing class, add it to the site-additions block of `modernist.css` rather than inline).

`website/src/components/Footer.astro` (the four original footers drifted slightly — index's version is canonical):

```astro
<footer class="footer">
  <div class="container footer-inner">
    <span class="mono text-muted">gallager.app</span>
    <div style="flex:1;"></div>
    <a href="/docs/">Docs</a>
    <a href="/pricing/">Pricing</a>
    <a href="/security/">Security</a>
    <a href="https://github.com/gpambrozio/Gallager">GitHub</a>
    <span class="text-muted">MIT licensed</span>
  </div>
</footer>
```

Diff index's extracted footer against the other three (`grep -A8 '<footer' website/.originals/*.html`); if a non-index footer has an extra link or different wording, prefer index's but note the difference in the commit message.

`website/src/components/Hero.astro`:

```astro
---
interface Props {
  eyebrow: string;
  title: string;
  lede?: string;
  class?: string;
  titleMaxWidth?: string;
  ledeMaxWidth?: string;
}

const {
  eyebrow,
  title,
  lede,
  class: className,
  titleMaxWidth,
  ledeMaxWidth,
} = Astro.props;
---

<header class:list={["container", "page-hero", className]}>
  <h6 class="eyebrow">{eyebrow}</h6>
  <h1 style={titleMaxWidth ? `max-width:${titleMaxWidth}` : undefined}>
    {title}
  </h1>
  {
    lede && (
      <p
        class="text-muted lede"
        style={ledeMaxWidth ? `max-width:${ledeMaxWidth}` : undefined}
      >
        {lede}
      </p>
    )
  }
  <slot />
</header>
```

- [ ] **Step 3: Wire the placeholder page through the layout to prove it renders**

Replace `website/src/pages/index.astro` with:

```astro
---
import Base from "../layouts/Base.astro";
---

<Base
  title="Gallager — command center for your coding agents"
  description="Run every Claude Code, Codex, opencode and pi session on your Mac from one command center — and from your iPhone, end-to-end encrypted."
>
  <h1>content placeholder</h1>
</Base>
```

```bash
cd website && npm run build && grep -c "nav-brand" dist/index.html && cd ..
```

Expected: build passes, grep prints `1` (nav rendered).

- [ ] **Step 4: Commit**

```bash
git add website/src website/public/logo.png website/public/og-logo.png
git commit -m "Add Base layout, Nav/Footer/Hero components, optimized logo assets"
```

---

## Porting procedure (applies to Tasks 5–8)

Each page task ports `website/.originals/<page>.html` into `website/src/pages/<page>.astro`:

1. **Scope:** copy everything inside the body's wrapper `<div>` EXCEPT `<nav>` (first child) and `<footer>` (last child) — those come from `Base`. The wrapper div itself is `Base`'s `.page`.
2. **Hero:** replace the original `<header>` with the `Hero` component, passing the page's exact eyebrow/h1/lede text (given per task).
3. **Data loops:** for each `<sc-for list="{{ items }}" as="x">`, copy the corresponding array literal out of the page's `<script type="text/x-dc">` `renderVals()` into a frontmatter `const`, convert to valid TS (it already is, minus any function-valued fields — drop those), and render with `{items.map((x) => (…))}` using the sc-for's inner markup with `{{ x.field }}` → `{x.field}`.
4. **Assets/links:** `<img src="<uuid>">` → `/logo.png`; `index.html` → `/`; `docs.html` → `/docs/`; `pricing.html` → `/pricing/`; `security.html` → `/security/`; `index.html#download` and `#download` links → `/#download` (on index itself: `#download`).
5. **Class promotion:** replace these exact inline-style patterns with Task 3 classes — `max-width:1200px;margin:0 auto` → `container`; section padding `var(--space-8) var(--space-4)` → `section`; the `<div style="max-width:1200px;…padding:0 var(--space-4);"><hr class="hr" style="margin:0;"></div>` divider rows → `<div class="container section-rule"><hr class="hr" /></div>`; `font-family:ui-monospace,Menlo,monospace` → `mono`. All other inline styles are page-specific: keep them inline as-is.
6. **Escaping:** `&nbsp;` and other entities in the originals must survive; in `.astro` templates plain HTML entities work as-is.
7. **Verify:** `npm run build`, then compare side by side — original at `http://localhost:8899/<page>.html` (server from "Reading the originals"), port via `npm run dev` at `http://localhost:4321/<page>/`. Same section order, same text, same look. Fix before committing.

---

### Task 5: Port index page

**Files:**
- Modify: `website/src/pages/index.astro` (replace placeholder entirely)

**Interfaces:**
- Consumes: `Base`, `Hero`, FAQ classes from Task 3.
- Produces: `/` with anchor `id="download"` on the hero button row (Nav's `/#download` target).

- [ ] **Step 1: Port the page**

Apply the porting procedure. Index's original body has, in order: nav (skip), hero header, terminal-mockup panel, then alternating `section-rule` dividers and content sections (feature grids — some driven by an `sc-for` over `features` with `kicker`/`title`/`body` fields), the FAQ section, the orange CTA band, footer (skip).

Hero (has extra content → use the slot):

```astro
<Hero
  class="page-hero--display"
  eyebrow="Open source · Mac + iOS"
  title="Run a fleet of coding agents. Carry them in your pocket."
  lede="Gallager puts every Claude Code, Codex, opencode and pi session on your Mac into one command center — then streams them to your iPhone over an end-to-end encrypted connection that pairs in seconds."
>
  <div id="download" style="display:flex;gap:var(--space-3);align-items:center;flex-wrap:wrap;">
    <a href="#" class="btn btn-primary" style="padding:var(--space-3) var(--space-6);font-size:15px;">Download for Mac</a>
    <a href="#" class="btn btn-secondary" style="padding:var(--space-3) var(--space-6);font-size:15px;">Get the iOS app</a>
    <span class="mono text-muted" style="font-size:13px;">free · self-hostable · MIT</span>
  </div>
</Hero>
```

(The download `href="#"` placeholders are intentional — real URLs are a content decision outside this plan.)

The FAQ section replaces the `sc-for`/DCLogic accordion with (data: copy the `rawFaqs` array — six `{ q, a }` entries — verbatim from the original's `text/x-dc` script into frontmatter as `const faqs`):

```astro
<section class="container section">
  <h2 style="margin-bottom:var(--space-6);">FAQ</h2>
  <div style="max-width:800px;">
    {
      faqs.map((f, i) => (
        <div class={i === 0 ? "faq-item open" : "faq-item"}>
          <div class="faq-q">
            {f.q}
            <span class="faq-arrow">+</span>
          </div>
          <div class="faq-a">
            <div>
              <p class="text-muted">{f.a}</p>
            </div>
          </div>
        </div>
      ))
    }
    <div style="border-top:1px solid var(--color-divider);"></div>
  </div>
</section>

<script>
  const items = document.querySelectorAll(".faq-item");
  items.forEach((item) => {
    item.querySelector(".faq-q")?.addEventListener("click", () => {
      const wasOpen = item.classList.contains("open");
      items.forEach((other) => other.classList.remove("open"));
      if (!wasOpen) item.classList.add("open");
    });
  });
</script>
```

(First item open on load and one-open-at-a-time both match the original `openFaq: 0` DCLogic. The original animated inline `grid-template-rows`/`rotate`; the `.open` class + Task 3 CSS reproduces it.)

- [ ] **Step 2: Build and compare**

Porting-procedure step 7. Also click through the FAQ: first item open on load; clicking another closes the first; clicking the open one closes it (all-closed state allowed).

- [ ] **Step 3: Commit**

```bash
git add website/src/pages/index.astro
git commit -m "Port index page to Astro (static FAQ accordion, no framework)"
```

---

### Task 6: Port docs page

**Files:**
- Create: `website/src/pages/docs.astro`

- [ ] **Step 1: Port the page**

Apply the porting procedure. Structure: hero, numbered install steps (`sc-for` over `steps`: `{ n, title, body, code }`, `code` nullable — render the `<code>`/`pre` block only `{s.code && (…)}`; the multi-line self-host snippet contains `\n` which must render as line breaks exactly like the original), then a guides section (`sc-for` over `guides`: `{ href, title, body }`), footer (skip).

Hero:

```astro
<Hero
  eyebrow="Documentation"
  title="Up and running in five minutes"
  lede="Install the Mac app, pair your phone, point it at your agents. Self-hosting the relay is optional and takes one more command."
/>
```

Frontmatter data: copy `steps` and `guides` arrays verbatim from the original's `text/x-dc` script. Note the docs body ALSO contains a pre-rendered copy of some step content — ignore it; the DCLogic arrays are authoritative (per "Reading the originals").

- [ ] **Step 2: Build and compare** (porting-procedure step 7)

- [ ] **Step 3: Commit**

```bash
git add website/src/pages/docs.astro
git commit -m "Port docs page to Astro"
```

---

### Task 7: Port pricing page

**Files:**
- Create: `website/src/pages/pricing.astro`

- [ ] **Step 1: Port the page**

Apply the porting procedure. Structure: hero, two-card pricing grid (self-host card + hosted-relay card), a details/fine-print section, footer (skip).

Hero:

```astro
<Hero
  eyebrow="Pricing"
  title="The software is free. The relay is a choice."
  lede="Both apps are open source and free forever. You only pay if you want us to run the relay server for you."
  ledeMaxWidth="620px"
/>
```

**No JS on this page.** The original's `{{ price }}` / `{{ period }}` / `{{ priceNote }}` bindings came from an artifact-editor prop (`annualBilling`, default false) with no on-page toggle — visitors always saw the monthly values. Bake them in statically:

- `{{ price }}` → `$5`
- `{{ period }}` → `month`
- `{{ priceNote }}` → `or $50/year`

- [ ] **Step 2: Build and compare** (porting-procedure step 7)

- [ ] **Step 3: Commit**

```bash
git add website/src/pages/pricing.astro
git commit -m "Port pricing page to Astro (monthly values baked in, no JS)"
```

---

### Task 8: Port security page

**Files:**
- Create: `website/src/pages/security.astro`

- [ ] **Step 1: Port the page**

Apply the porting procedure. Structure: hero (tight bottom padding + wider text columns), encryption-explainer panel with a mono code block (contains `&nbsp;` and accent-colored spans — preserve exactly), the security-points list (`sc-for` over `points`: `{ title, body }` — ~6 entries in a `240px 1fr` grid row each), an accent-bordered callout box, footer (skip).

Hero:

```astro
<Hero
  class="page-hero--tight"
  eyebrow="Security model"
  title="Your terminal is your secrets. We treat it that way."
  lede="Agent sessions carry API keys, source code, file paths and passwords. Gallager encrypts everything sensitive on-device, so the relay — ours or yours — only ever forwards ciphertext."
  titleMaxWidth="860px"
  ledeMaxWidth="680px"
/>
```

Frontmatter data: copy the `points` array verbatim from the original's `text/x-dc` script. The point-row markup from the sc-for body:

```astro
{
  points.map((p) => (
    <div style="border-top:2px solid var(--color-divider);padding:var(--space-4) 0 var(--space-6);display:grid;grid-template-columns:240px 1fr;gap:var(--space-4);">
      <h4 style="font-size:17px;margin:0;">{p.title}</h4>
      <p class="text-muted" style="font-size:14.5px;line-height:1.7;margin:0;">{p.body}</p>
    </div>
  ))
}
```

- [ ] **Step 2: Build and compare** (porting-procedure step 7)

- [ ] **Step 3: Commit**

```bash
git add website/src/pages/security.astro
git commit -m "Port security page to Astro"
```

---

### Task 9: 404 page + output checks

**Files:**
- Create: `website/src/pages/404.astro`

- [ ] **Step 1: Write the 404 page**

```astro
---
import Base from "../layouts/Base.astro";
import Hero from "../components/Hero.astro";
---

<Base title="Not found — Gallager" description="This page does not exist.">
  <Hero
    eyebrow="404"
    title="This page doesn't exist"
    lede="The page you're looking for was moved or never existed."
  >
    <a href="/" class="btn btn-primary" style="padding:var(--space-3) var(--space-6);font-size:15px;">Back to the homepage</a>
  </Hero>
</Base>
```

- [ ] **Step 2: Full output verification**

```bash
cd website && npm run build
test -f dist/index.html && test -f dist/docs/index.html && test -f dist/pricing/index.html \
  && test -f dist/security/index.html && test -f dist/404.html && echo "pages OK"
grep -L 'og:title' dist/index.html dist/docs/index.html dist/pricing/index.html dist/security/index.html
grep -c 'aria-current="page"' dist/docs/index.html
grep -rn 'react\|__bundler\|x-dc\|sc-for\|{{' dist/index.html | head -5
du -sh dist
cd ..
```

Expected: `pages OK`; the `grep -L` prints nothing (every page has OG tags); `aria-current` count is `1`; the react/bundler grep prints nothing (no artifact residue, no unexpanded bindings); dist is a few hundred KB total (fonts dominate).

- [ ] **Step 3: Commit**

```bash
git add website/src/pages/404.astro
git commit -m "Add 404 page"
```

---

### Task 10: Caddy vhost + deploy.sh website mode

**Files:**
- Create: `ClaudeSpyPackage/caddy/website.caddy`
- Modify: `scripts/deploy.sh` (config block ~line 40, new `deploy_website()` near `deploy_staging()`, `usage()`, main `case`)

**Interfaces:**
- Consumes: deploy.sh helpers `info`/`warn`/`error`, `resolve_remote_host`, `remote`, `package_dir`, `$CADDY_CONF_D`.
- Produces: `./scripts/deploy.sh website` builds + rsyncs + installs Caddy config + reloads Caddy.

- [ ] **Step 1: Write the Caddy vhost**

`ClaudeSpyPackage/caddy/website.caddy`:

```
# Gallager marketing site (gallager.app)
# Installed into /etc/caddy/conf.d/ by `scripts/deploy.sh website` (NOT by the
# relay deploy — this file only reaches the server when the website deploys,
# so edits here ship with the site they style).
#
# Serves the static Astro build from /opt/gallager-website, uploaded by
# scripts/deploy.sh website over rsync/SSH. One-time prerequisite: DNS A
# records for gallager.app and www.gallager.app pointing at this server
# (Caddy then provisions Let's Encrypt certs per hostname automatically).

www.gallager.app {
    redir https://gallager.app{uri} 308
}

gallager.app {
    root * /opt/gallager-website
    file_server
    encode gzip

    # Access logging (separate file from the relay + updates)
    log {
        output file /var/log/caddy/gallager-website-access.log
        format json
    }

    # Security headers
    header {
        X-Frame-Options "DENY"
        X-Content-Type-Options "nosniff"
        X-XSS-Protection "1; mode=block"
    }

    # Astro emits content-hashed assets under /_astro/; fonts change only by
    # being renamed. Both are safe to cache forever.
    @immutable path /_astro/* /fonts/*
    header @immutable Cache-Control "public, max-age=31536000, immutable"
}
```

- [ ] **Step 2: Add the deploy.sh config + function**

In `scripts/deploy.sh`, after the staging configuration block (ends ~line 40 with `STAGING_COMPOSE=…`), add:

```bash
# Website configuration (used by the `website` command). Static marketing site
# (gallager.app) built locally with Astro from website/ and served by Caddy as
# plain files — no container involved.
WEBSITE_REMOTE_DIR="${WEBSITE_REMOTE_DIR:-/opt/gallager-website}"
WEBSITE_CADDY_FILE="website.caddy"
WEBSITE_URL="${WEBSITE_URL:-https://gallager.app}"
```

After `deploy_staging()`'s closing brace, add:

```bash
# Deploy the static marketing website (gallager.app). Builds the Astro site
# locally (needs node/npm), rsyncs website/dist/ to the server, installs the
# Caddy vhost and reloads Caddy. One-time prerequisite: DNS for gallager.app
# and www.gallager.app must point at the server (see website/README.md).
deploy_website() {
    local website_dir
    website_dir="$(cd "$(dirname "$0")/../website" && pwd)"

    info "Building website..."
    (cd "$website_dir" && npm ci && npm run build)

    if [ ! -f "$website_dir/dist/index.html" ]; then
        error "Build produced no dist/index.html — aborting."
        exit 1
    fi

    resolve_remote_host
    info "Deploying website to $SERVER_HOST:$WEBSITE_REMOTE_DIR..."
    remote "mkdir -p $WEBSITE_REMOTE_DIR"
    rsync -az --delete -e ssh "$website_dir/dist/" "$REMOTE_HOST:$WEBSITE_REMOTE_DIR/"

    if remote "test -d $CADDY_CONF_D" 2>/dev/null; then
        info "Installing Caddy configuration ($WEBSITE_CADDY_FILE)..."
        rsync -az -e ssh "$(package_dir)/caddy/$WEBSITE_CADDY_FILE" "$REMOTE_HOST:$CADDY_CONF_D/"
        remote "systemctl reload caddy"
    else
        warn "Caddy conf.d not found on server; configure your web server manually."
    fi

    info "Verifying deployment..."
    if curl -sf -o /dev/null "$WEBSITE_URL"; then
        info "Website deployed: $WEBSITE_URL"
    else
        warn "Could not fetch $WEBSITE_URL — if this is the first deploy, check DNS for gallager.app."
    fi
}
```

In `usage()`, after the `staging-stop` line add:

```bash
    echo "  website         Build the Astro site and deploy it to gallager.app"
```

and in the environment-variables section after the staging block add:

```bash
    echo ""
    echo "  # Website (gallager.app static site):"
    echo "  WEBSITE_REMOTE_DIR  Website install dir (default: /opt/gallager-website)"
    echo "  WEBSITE_URL         Post-deploy check URL (default: https://gallager.app)"
```

In the main `case` block, after the `staging-stop)` entry add:

```bash
    website)
        deploy_website
        ;;
```

- [ ] **Step 3: Syntax-check and dry-verify**

```bash
bash -n scripts/deploy.sh && echo "syntax OK"
./scripts/deploy.sh help | grep website
```

Expected: `syntax OK`; help lists the `website` command and `WEBSITE_*` variables. Do NOT run the actual deploy in this task (DNS may not exist yet; deploying is the post-merge step in Task 11's notes).

- [ ] **Step 4: Commit**

```bash
git add ClaudeSpyPackage/caddy/website.caddy scripts/deploy.sh
git commit -m "Add gallager.app Caddy vhost and deploy.sh website mode"
```

---

### Task 11: Final verification, README, cleanup, docs

**Files:**
- Create: `website/README.md`
- Modify: `CLAUDE.md` (Reference Docs list)
- Delete: `deploy/` (all files), `scripts/extract-website-originals.py`

- [ ] **Step 1: Full side-by-side visual pass**

```bash
python3 -m http.server 8899 --directory deploy &
cd website && npm run dev &
```

For each of the four pages, compare `http://localhost:8899/<page>.html` against `http://localhost:4321/<page>/` (index at `/`): section order, all text content, spacing/colors/typography, nav active-state, footer, index FAQ behavior. Screenshot pairs if anything is in doubt. Fix regressions before proceeding. Kill both servers when done.

- [ ] **Step 2: Write `website/README.md`**

````markdown
# gallager.app website

Static marketing site built with [Astro](https://astro.build). Four pages
(index, docs, pricing, security) sharing one design system.

## Develop

```bash
cd website
npm install
npm run dev        # http://localhost:4321
npm run build      # → dist/
npm run preview    # serve dist/ locally
```

## Structure

- `src/styles/modernist.css` — the design system: tokens + component classes,
  the single source of truth for the site's look. Page-specific one-off styles
  stay inline in the page.
- `src/layouts/Base.astro` — html head (meta/OG/fonts) + Nav + Footer around
  every page.
- `src/components/` — `Nav` (active link from the URL), `Footer`, `Hero`
  (eyebrow/h1/lede page header).
- `src/pages/` — one `.astro` file per page. Content-as-data lives in each
  page's frontmatter (`const faqs = […]`) and renders with `.map()`.
- `public/` — fonts (self-hosted Archivo), logo, favicon, robots.txt.

## Add a page

1. Create `src/pages/<name>.astro`, wrap content in `Base`, start with `Hero`.
2. Use `container` / `section` / design-system classes from `modernist.css`;
   promote any style you repeat a second time into a class there.
3. Add the page to the `links` array in `src/components/Nav.astro` (and the
   Footer) if it belongs in the chrome.

## Deploy

```bash
./scripts/deploy.sh website
```

Builds locally, rsyncs `dist/` to `/opt/gallager-website` on the relay box,
installs `ClaudeSpyPackage/caddy/website.caddy` and reloads Caddy.

One-time prerequisite: DNS A records for `gallager.app` and
`www.gallager.app` pointing at the server. Caddy provisions Let's Encrypt
certs automatically once DNS resolves.

## History

Ported 2026-07 from four self-contained artifact-export bundles (see
`docs/superpowers/specs/2026-07-20-website-structure-design.md`). The original
bundles live in git history under `deploy/` (removed after the port);
`scripts/extract-website-originals.py` (also removed, in history) decodes them.
````

- [ ] **Step 3: Delete the originals + extraction script**

```bash
git rm -r deploy
git rm scripts/extract-website-originals.py
rm -rf website/.originals
```

(`deploy/.DS_Store` was never tracked; `git rm -r deploy` plus a stray-file check `ls deploy 2>/dev/null` — remove leftovers with `rm -rf deploy`.)

- [ ] **Step 4: Add the CLAUDE.md reference line**

In `CLAUDE.md`'s **Reference Docs** list, add:

```markdown
- **Website (gallager.app):** `website/` - Astro static site (index/docs/pricing/security) replacing the old self-contained artifact bundles; one design system (`website/src/styles/modernist.css`), shared Nav/Footer/Hero components, content-as-data in page frontmatter. `npm run dev|build` in `website/`; deployed by `scripts/deploy.sh website` → `/opt/gallager-website` behind Caddy (`ClaudeSpyPackage/caddy/website.caddy`, DNS one-time step). See `website/README.md`.
```

- [ ] **Step 5: Final build + commit**

```bash
cd website && npm run build && cd ..
git add -A
git commit -m "Replace deploy/ artifact bundles with the Astro website; add README + docs"
```

- [ ] **Step 6: Post-merge notes (not part of this branch's work)**

After merge to main: set the DNS A records, then run `./scripts/deploy.sh website` and verify `curl -I https://gallager.app` → 200, `curl -I https://www.gallager.app` → 308 to apex, `curl -sI https://gallager.app/fonts/archivo-latin.woff2 | grep -i cache-control` → immutable.

---

## Self-review notes

- Spec coverage: structure ✓ (Tasks 2–4), cleanup pass ✓ (Task 3 + porting rule 5), interactivity ✓ (Task 5 FAQ; pricing static per amended spec), SEO/meta/sitemap ✓ (Tasks 2, 4, 9), deploy wiring ✓ (Task 10), untracked-deploy/ preservation ✓ (Task 1), deletion ✓ (Task 11), README + CLAUDE.md ✓ (Task 11), verification ✓ (per-page compare + Task 11 full pass + post-merge curl checks).
- The four page bodies are ported from repo-resident originals (`website/.originals/`, regenerable from the Task 1 snapshot commit) rather than being inlined here; the porting procedure + per-task structure outlines + exact hero/FAQ/points code pin down every transformation.
