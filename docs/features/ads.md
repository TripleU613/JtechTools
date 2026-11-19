# Ads

One ad space: the welcome area at the top of the home page (the homepage, Latest and Categories, not inside a category or tag), on desktop and on phones. Ads are **text and links only**, take the look of the active theme and palette, play like a billboard, and can't be closed.

Off by default. Turn on `jtech_ads_enabled`: **Admin → Plugins → Jtech Tools → Ads** has every ad setting, the ads list and a preview.

## The space

The space has one fixed size, set by the space and never by an ad: about 224px tall on a phone, up to 272px on a wide screen, the width of the content column. An ad fills it; anything that doesn't fit is cut, never grown into. Switching ads never moves the page.

- **JTech theme, hero on** (`hero_enabled`): the hero card is the space. While ads show, the whole card is theirs: no welcome text, search, sign-up buttons, globe or ✕.
- **Any other theme, or the JTech theme with its hero off**: a card in the same place, built from core's colour scheme.

## Who sees what, and when

- **Members** (logged in): the ads, straight away.
- **A new visitor** (not logged in, within `jtech_ads_new_visitor_seconds`, default 60, of their first page): the forum's welcome for `jtech_ads_welcome_seconds` (default 10), then the ads slide in and the card eases to the ad space's height. Remembered in their browser only (nothing is sent to the server); a browser that doesn't keep it counts as not new.
- **Everyone else**, and anyone who closed the welcome before: the ads, straight away.
- A theme without a welcome goes straight to the ads.

When someone can see more than one ad, they take turns like a billboard, each for `jtech_ads_rotate_seconds` (default 60), sliding in. A turn waits while the pointer or keyboard focus is on the ad, while the tab is hidden and while the space is scrolled away. People who ask their system for reduced motion get one ad per page and no sliding.

`jtech_ads_label` is the small word in the corner of every ad (default "Ad"), so people always know.

## The ads

Everything is in **`jtech_ads_list`**, a list with its own editor (Ads tab → **Launch Editor**). Each ad:

| Field | What it does |
|---|---|
| **Name** | Your name for it, unique, shown nowhere. Thumbs are counted per name: renaming starts the count over. |
| **Running** | Off keeps it saved without showing it. Keep many saved, switch which run. |
| **Headline**, **Text** | The simple ad: a headline and a line, in inline HTML (`<a href>`, `<b>`, `<i>`, `<u>`, `<s>`, `<small>`, `<mark>`, `<code>`, `<br>`, `<span>`, `<sub>`, `<sup>`). Also what's shown where the full card can't be. |
| **Whole card** | Optional. The ad as a small page filling the whole space, built from the kit below. |
| **Who sees it** | `everyone`, `visitors` (not logged in), `members` (logged in), or `groups`. |
| **Groups** | With `groups`: only members of these. Trust levels are groups too (`trust_level_2`…). |
| **Weight** | 1–10. How often it comes up next to the others the same person can see. |
| **Starts / Ends** | Optional schedule. |

Changes reach visitors right away and logged-in members on their next page load. The plugin's default list has one ad, "Your ad here", linking to /about.

### The kit (whole-card ads)

A whole-card ad is HTML made of block and inline tags (`div`, `section`, `header`, `footer`, `h2`–`h4`, `p`, `ul`, `ol`, `li`, `blockquote`, `hr`, `kbd` and the inline ones above) and **only these classes**:

| Class | What it is |
|---|---|
| `jl-split` | Two columns: main, and a side (the side drops away on phones). Both always fill the space; content is centred in them. |
| `jl-row`, `jl-stack`, `jl-grid` | A row, a column, a grid of equal cells. |
| `jl-center`, `jl-end`, `jl-spacer` | Centre, push to the end, take up the gap. |
| `jl-kicker` | A small capitals line above a title. |
| `jl-title`, `jl-title-xl` | A title, a big title. |
| `jl-lead` | The line under a title (two lines at most). |
| `jl-text`, `jl-muted`, `jl-small`, `jl-mono`, `jl-accent` | Text styles. |
| `jl-panel`, `jl-glow` | A raised box; with a soft glow. |
| `jl-stat`, `jl-stat-label` | A big number and its label. |
| `jl-chips` + `jl-chip` | A row of pills. |
| `jl-list` | A checklist. |
| `jl-quote`, `jl-big` | A quote; one big glyph or emoji. |
| `jl-button`, `jl-button-alt` | A link as a main or second button. |
| `jl-float`, `jl-pulse`, `jl-marquee` | Gentle motion (none for reduced motion). |

No images, video, iframes, scripts, `style`, `id`, forms or other classes: they're dropped before the page sees them. Links get `rel="nofollow noopener"`; links to other sites open in a new tab.

Example:

```html
<div class="jl-split">
  <div class="jl-stack">
    <p class="jl-kicker">JTech Market</p>
    <h2 class="jl-title-xl">Buy and sell tech, member to member.</h2>
    <p class="jl-lead">Verified sellers, checkout on the site.</p>
    <div class="jl-row">
      <a class="jl-button" href="https://market.jtechforums.org">Open the Market</a>
      <a class="jl-button-alt" href="/about">How it works</a>
    </div>
  </div>
  <div class="jl-panel jl-glow jl-center">
    <p class="jl-stat">1,300+</p>
    <p class="jl-stat-label">members</p>
  </div>
</div>
```

## Apps

An ad with **CSS** (the CSS field) is an **app**: its whole-card HTML and its CSS run inside a closed shadow root in the space, sealed off from the page. Its class names, animations and SVG ids are its own; it can't reach the page, the label, the thumbs or the space's size. This is how the forum's own welcome and its showcase ads are made.

- **HTML:** block and inline tags, any classes, and inline SVG (shapes, gradients, text; no `use`, `image`, `foreignObject`, `animate`). No images, video, frames, scripts, forms or styles. Up to 8000 characters and 400 elements.
- **CSS:** up to 8000 characters; `@keyframes`, `@media`, `@container`, `@supports`. **Refused whole** (the ad then shows as a plain kit card) if it contains `url(`, `image-set(`, `image(`, `src(`, `@import`, `@font-face`, a backslash, `expression(`, `behavior` or `-moz-binding`: nothing may load from anywhere. The app's root is a size container for `@container` queries.
- **Colours:** the `--jl-*` variables (below) reach inside, so an app fits every theme and palette, light and dark.
- **Reserved corners:** the label sits top right and the thumbs bottom right, above the app. Leave them clear. An app can't cover or remove them.
- **Pieces it can ask for:** `<div class="jl-search"></div>` becomes a search box, `<div class="jl-auth"></div>` Sign up / Log in for visitors.
- **Performance:** animate transform and opacity, few elements, slow loops. The space pauses an app's animations when it's off screen or the tab is hidden, and stops them for reduced motion. Only the ad showing is on the page (two during a swap).

**The forum's own** (house) ads, for the forum's own content only, show without the Ad label and thumbs, and take no thumbs. **Welcome** ads are shown first to new visitors, for the welcome's seconds, in place of the theme's own welcome; then the next ad takes over. Give a welcome app the `visitors` audience so members go straight to the ads.

## Preview

A preview shows one ad in the real space, to the admin who opens it, for an hour; nothing changes for anyone else. The Ads tab's **Preview an ad** opens a saved ad (running or paused) or a draft that isn't saved (a headline, and optionally the whole-card HTML) in a new tab, marked "Preview · only you see this". The link is `/latest?jl_preview=<token>`.

## Thumbs

Logged-in members get a thumbs up and down on each ad; pressing the same one again takes it back. One per member per ad, rate-limited. Staff see each ad's counts next to the thumbs on the site. Visitors don't get thumbs.

## For agents (MCP)

Discourse's MCP server can expose five tools, admins only. Each stays off until an admin turns it on under **Admin → MCP**; scopes `mcp:jtech-ads:read` and `mcp:jtech-ads:write`.

| Tool | Does |
|---|---|
| `jtech_ads_get` | Settings, every ad (paused too) with its thumbs, and the kit (classes, tags, notes). |
| `jtech_ads_configure` | `enabled`, `rotate_seconds`, `welcome_seconds`, `new_visitor_seconds`, `label`. |
| `jtech_ads_save` | Creates an ad or replaces the one with the same name. Returns what it will show, what the cleaning dropped, and a preview link. |
| `jtech_ads_delete` | Removes an ad by name. To stop one without losing it, save it with `enabled: false`. |
| `jtech_ads_preview` | A preview link for a saved ad (name only) or a draft (name, headline, text, card), plus what it will show. |

Every change goes through the setting, so it's validated the same way and logged as a staff action.

## Theming

Everything is drawn from `--jl-*` variables (`assets/stylesheets/lines.scss`): `--jl-fg`, `--jl-muted`, `--jl-border`, `--jl-raised`, `--jl-accent`, `--jl-accent-fg`, `--jl-radius`, `--jl-radius-lg`, `--jl-gap`, and `--jl-height` (the space's height).

### Any theme (vanilla Discourse)

The variables come from core's colour scheme (`--primary`, `--primary-medium`, `--primary-low`, `--primary-very-low`, `--tertiary`, `--secondary`, `--d-border-radius`…), so every scheme already fits. To restyle the space, set the variables, not the properties:

```scss
.jt-lines {
  --jl-accent: var(--quaternary);
  --jl-raised: var(--tertiary-very-low);
  --jl-height: 15rem;
}
```

The card is `.jt-lines` → `.jl-card` (one per ad) with `.jt-lines__label`, the ad's content, `.jt-lines__thumbs` / `.jt-lines__thumb` (`[aria-pressed="true"]` when chosen) and `.jt-lines__tally` (staff).

A theme that wants to carry the ads itself (as the JTech hero does) looks up the `jt-lines` service and, in an api-initializer (before anything renders), calls `hostInTheme()`; the plain card then stays out. The service gives `stage` (`"welcome"` or `"ads"`), `line`, `card` (the component that draws one ad, so it looks the same everywhere), `startIntro()`, `rotate(element)` and `watch(element)` (each returns its cleanup). See `themes/jtech/javascripts/discourse/api-initializers/jt-lines.ts` and `components/jt-hero.gts`.

### JTech theme

The hero gets `.--lines` while the ads have it, and `.jt-hero__lines` holds them over the card; the theme sets the `--jl-*` variables to its own `--jt-*` tokens there (`stylesheets/jt-hero.scss`), so every palette fits.

## Naming, and why

Ad blockers hide elements and block requests by name: anything called ad, ads, advert, sponsor, banner or promo, and files and paths like them (Discourse's own ad plugin is blocked by its name, `adplugin`). So, in everything the browser sees, nothing is named after ads:

- **No request of its own.** The ads come inside the page's preloaded site data (`site.jt_lines`), filtered for the person on the server. The thumbs go to `/jtech-lines/:key`.
- **Neutral names** for classes (`jt-lines`, `jl-*`, `jt-hero__lines`), the service and the data (`h`, `t`, `c`).
- **In the JTech theme the ad is the hero**, so a rule that hides it hides the welcome with it.
- **One fallback.** About a second and a half after the page settles, the space checks it's actually showing. If something hid it, the ad (its headline and text) moves once to the top of the page, inside a closed shadow root, which page-level hiding rules can't reach into. No nagging, no wall, no second attempt.

Checked against EasyList, uBlock's own filters and Fanboy's annoyances list: nothing matches. A filter written for this forum specifically can still hide it, and since this code is public, someone could write one; that's a limit of any ad on the open web. Keep new names neutral when changing any of this: no `ad`, `ads`, `advert`, `sponsor`, `banner`, `promo` in class names, ids, data attributes, aria labels, file names, connector names, URLs, link targets or JSON keys that reach the browser. The word "Ad" as visible text is fine and stays: people should know.

## Not here

- Images and video: text only, on purpose.
- Impression and click counts.
- Other placements. Discourse's bundled ad plugin (house ads) covers the topic list and posts, but has no welcome-area placement and is blocked by its name, which is why this is separate. It's left as it is.
