# Ads

One ad spot: the welcome area at the top of the home page (the homepage, Latest and Categories, not inside a category or tag), on desktop and on phones. Ads are **text and links only**, take the look of the active theme, and can't be closed.

Off by default. Turn on `jtech_ads_enabled` (Admin → Settings, search "jtech_ads").

## Setting up ads

Everything is in one setting, **`jtech_ads_list`**, a list with its own editor: **Add** an ad, fill it in, save. Each ad has:

| Field | What it does |
|---|---|
| **Name** | Your name for it, unique, shown nowhere. Thumbs are counted per name: renaming starts the count over. |
| **Running** | Off keeps it saved without showing it. The quick way to swap ads: keep many saved, switch which run. |
| **Headline** | The big line. |
| **Text** | The line under it. |
| **Who sees it** | `everyone`, `visitors` (not logged in), `members` (logged in), or `groups`. |
| **Groups** | With `groups`: only members of these. Trust levels are groups too (`trust_level_2`…). |
| **Weight** | 1–10. How often it comes up next to the others the same person can see: 2 shows twice as often as 1. |
| **Starts / Ends** | Optional schedule. |

Headline and text take plain text and inline tags: `<a href>`, `<b>`/`<strong>`, `<i>`/`<em>`, `<u>`, `<s>`, `<small>`, `<mark>`, `<code>`, `<br>`, `<span>`, `<sub>`, `<sup>`. Anything else (images, video, iframes, scripts, styles, classes, event attributes) is dropped before it reaches the page. Links get `rel="nofollow noopener"`; links to other sites open in a new tab.

When someone can see more than one ad, they take turns every `jtech_ads_rotate_seconds` (default 8). The turn waits while the pointer or keyboard focus is on the ad, while the tab is hidden and while the spot is scrolled away; people who ask their system for reduced motion get one ad per page and no turns. The spot keeps its height, so a turn never moves the page.

`jtech_ads_label` is the small word in front of every ad (default "Ad"), so people always know.

Changes reach visitors right away (their cached page data is cleared when the setting changes) and logged-in members on their next page load. A tab left open keeps what it had.

The default list has one ad, **"Your ad here"**, linking to /about. Edit or switch it off.

## Thumbs

Logged-in members get a thumbs up and a thumbs down on each ad; pressing the same one again takes it back. One per member per ad, rate-limited. Staff see each ad's counts next to the thumbs on the site itself. Visitors don't get thumbs.

## Where it shows

- **JTech theme, hero on** (`hero_enabled`): the ad takes the hero's headline and the line under it, with its globe and search still there. The hero's ✕ disappears while an ad shows: an ad can't be closed. Someone who closed the welcome hero before sees the ad as a slim strip in the same place (no globe, no search).
- **Any other theme, or the JTech theme with the hero off**: a card in the same place, built only from core's colour and size variables.

## Theming

### Any theme (vanilla Discourse)

The card is `.jt-lines` (stylesheet `assets/stylesheets/lines.scss`):

```
.jt-lines                 the card (aside)
  .jt-lines__body
    .jt-lines__label      "Ad"
    .jt-lines__head       headline
    .jt-lines__text       text
  .jt-lines__thumbs
    .jt-lines__thumb      the two buttons ([aria-pressed="true"] when chosen)
    .jt-lines__tally      staff only
```

It's drawn with core's variables (`--secondary`, `--primary`, `--primary-medium`, `--primary-low`, `--primary-high`, `--tertiary`, `--d-border-radius-large`), so any colour scheme already fits. To restyle it in a theme, set its own variables rather than overriding properties:

```scss
.jt-lines {
  --jt-lines-bg: var(--tertiary-very-low);
  --jt-lines-fg: var(--primary);
  --jt-lines-muted: var(--primary-medium);
  --jt-lines-border: transparent;
  --jt-lines-radius: 0;
}
```

A theme that wants to draw the ad itself (as the JTech hero does) looks up the `jt-lines` service and, in an api-initializer (so before anything renders), calls `hostInTheme()`; the plain card then stays out. The service gives `line` (the current ad: `h` headline and `t` text, both already-cleaned HTML; `k` key), `label`, `canVote`, `isStaff`, `vote(line)`, `tally(line)`, `setVote(line, 1 | -1)`, and two helpers to run on the element that shows it: `rotate(element)` and `watch(element)` (each returns its cleanup). See `themes/jtech/javascripts/discourse/api-initializers/jt-lines.ts` and `components/jt-hero.gts`.

### JTech theme

The hero (`components/jt-hero.gts`, `stylesheets/jt-hero.scss`) gets `.--line` while it carries an ad and `.--slim` for the strip. Inside: `.jt-hero__line`, `.jt-hero__tag` (the label), `.jt-hero__title` and `.jt-hero__subtitle` (the hero's own), `.jt-hero__thumbs`, `.jt-hero__thumb`, `.jt-hero__tally`. Colours are the theme's `--jt-*` tokens, so every palette fits.

## Naming, and why

Ad blockers hide elements and block requests by name: anything called ad, ads, advert, sponsor, banner or promo, and files and paths like them (Discourse's own ad plugin is blocked by its name, `adplugin`). So, in everything the browser sees, nothing is named after ads:

- **No request of its own.** The ads come inside the page's preloaded site data (`site.jt_lines`), filtered for the person on the server. There's no ads file, script, stylesheet or URL to block. The thumbs go to `/jtech-lines/:key`.
- **Neutral names** for classes, the service and the data (`jt-lines`, `h`, `t`).
- **In the JTech theme the ad is the hero's own headline**, so a rule that hides it hides the welcome with it.
- **One fallback.** About a second and a half after the page settles, the spot checks it's actually showing. If something hid it, the ad moves once to the top of the page, inside a closed shadow root, which page-level hiding rules can't reach into. No nagging, no wall, no second attempt.

This beats the general filter lists everyone uses. A filter written for this forum specifically can still hide it, and since this code is public, someone could write one; that's a limit of any ad on the open web. Keep new names neutral when changing any of this.

When adding to it: no `ad`, `ads`, `advert`, `sponsor`, `banner`, `promo` in class names, ids, data attributes, aria labels, file names, connector names, URLs or JSON keys that reach the browser. The word "Ad" as visible text is fine and stays: people should know.

## Not here

- Images and video: text only, on purpose.
- Impression and click counts.
- Other placements. Discourse's bundled ad plugin (house ads) covers the topic list and posts, but has no welcome-area placement and is blocked by its name, which is why this is separate. It's left as it is.
