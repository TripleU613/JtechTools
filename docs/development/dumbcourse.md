# Dumbcourse — how it's built

Dumbcourse is a small single-page Discourse client for flip phones and old
browsers, served by this plugin at `/dumb` (configurable). This page is for
people changing it.

## Layout

```
dumbcourse/
  src/            the app, in TypeScript
    main.ts         boot + the list of screens (routes)
    app.ts          shell: top bar, side menu, soft keys, global keys, links
    screen.ts       the current screen: title, content, keys, soft keys, actions
    router.ts       history routing; each entry remembers scroll + focus
    nav.ts          D-pad focus engine (reading, rows, grids, tabs)
    keys.ts         key normalisation (arrows, soft keys, keypad, old engines)
    api.ts          XMLHttpRequest JSON client with CSRF handling
    cache.ts        stale-while-revalidate cache, per account
    storage.ts      localStorage that never throws, per-account namespace
    session.ts      signed-in user and live counters
    messagebus.ts   Discourse MessageBus long-polling client
    html.ts         html`` templates that escape by default
    compat.ts       the only place old-engine workarounds live
    early.ts        tiny inline script: theme + text size before first paint
    content/        post HTML processing, emoji
    ui/             icons, layers (sheets/dialogs/drawer/toasts), soft keys,
                    topic rows, posts
    views/          one file per screen (or family of screens)
  styles/         SCSS with CSS custom properties, compiled in name order
  test/           Node unit tests
  build.ts        the build
  css.ts          the stylesheet build
  page.ts         the page template the server fills in
public/
  dumbcourse.js, dumbcourse-early.js, dumbcourse.css, index.html   ← built, committed
app/controllers/discourse_dumbcourse/
  app_controller.rb     serves the page + static files, boot data, CSP
  pair_controller.rb    "Sign in with another device"
  api_controller.rb     composer preview
lib/discourse_dumbcourse/
  pairing.rb            pairing state (Redis) and rules
  legacy_redirect.rb    old-browser / "open forum links here" redirect
```

## Building

```bash
pnpm install
pnpm dumbcourse:build   # writes public/dumbcourse.js, -early.js, .css, index.html
pnpm dumbcourse:check   # type-check + fail if the committed build is stale
pnpm dumbcourse:test    # unit tests (Node's test runner, TypeScript directly)
```

Always commit the rebuilt `public/` files with source changes; CI runs
`pnpm lint:dumbcourse` and fails on a stale build.

The pipeline: **esbuild** bundles `src/main.ts` into one file →
**TypeScript** lowers it to ES5 (async/await included; tagged templates are
rewritten to plain calls so their strings aren't stored twice) → esbuild
minifies it, still ES5 → **espree** parses the result as ECMAScript 5, and
the build fails if anything newer slipped in. The styles go through **Sass**
first, then the `var()` fallbacks below.

Colours are the tokens in `styles/00-tokens.scss` (`:root` dark, `html.light`
light), and nothing else: no colour is written into a rule. Their values are
JTech Dark and JTech Light as `lib/discourse_dumbcourse/palette.rb` maps a
palette (a spec keeps the two equal). The page adds a `<style>` after the
stylesheet (`{{PALETTE}}`) with the reader's own palettes, picked as core
picks them (this device's cookie, their account, the theme's), so browsers
with custom properties show the forum's colours.

What stops newer *APIs* (not just syntax) from reaching old phones:

- `tsconfig.json` uses `lib: ES5 + Promise`, so `Array#includes`,
  `Object.assign`, `String#startsWith` and friends are type errors.
- The build refuses DOM calls old engines lack (`.closest(`, `.remove()`,
  `fetch(`, `new Event(`, observers, `Symbol`, passive-listener objects…) —
  use the helpers in `compat.ts`/`dom.ts`. A reviewed exception can be
  marked `// old-browser-ok`.
- `compat.ts` installs a small Promise if the engine has none.
- CSS avoids flex `gap`, grid, `:is()`/`:where()`. Every `var()` gets a plain
  fallback, and the light theme is repeated inside `@supports not (--a: 0)`
  for engines without custom properties.

Target floor: roughly Chrome 30 / Android 4.4 WebView, Firefox 30, KaiOS 2.5+.

## How screens work

A route's view gets the current `Screen` (`useScreen()`), sets the title,
renders with `html```, and registers what it needs:

```ts
export function exampleRoute(ctx: RouteContext): Promise<void> {
  const s = useScreen();
  s.title("Example", { back: true });
  s.act("do-thing", (el) => { /* a [data-act="do-thing"] was clicked or OK'd */ });
  s.keys({ "5": refresh });                       // keypad shortcut
  s.softkeys({ right: { label: "Options", run: options } });
  return get<Thing>("/thing.json").then((d) => {
    if (!s.alive()) return;                        // the user moved on
    s.render(html`<ul class="rows">${d.items.map(row)}</ul>`);
    if (!ctx.restore) focusContent(".row");
  });
}
```

Everything registered is dropped when the next screen starts. Give list items
a stable `data-key` so Back can restore focus to them.

### D-pad rules (nav.ts)

- Up/Down walk focusable elements in reading order. If the focused thing (or
  the post it's in) runs past the screen edge, Down scrolls instead, and
  focus never jumps over more than a screenful of unseen content.
- `[data-row]` groups move with Left/Right and are left as a whole with
  Up/Down; `[data-grid]` moves by rows. A screen with `[data-tabs]` switches
  tabs on Left/Right. Screens can take Left/Right themselves (topics use them
  to jump between posts).
- Links inside post bodies have `tabindex="-1"`; they're listed in the post's
  action sheet instead.
- Open layers (sheets, dialogs, the drawer) own the keys and get a history
  entry, so the phone's Back closes them.

### Phone keys (keys.ts, views/phone-keys.ts)

Browsers disagree on soft keys. KaiOS names them `SoftLeft`/`SoftRight`;
Android flip-phone browsers often keep them for themselves (Chrome never
passes Menu or Back to a page) or send them nameless. So:

- `keyOf` reads `key`, then `code`, then `keyCode`. A keydown that comes as
  an anonymous `229` is finished on keyup, where Android names the key.
- Any key that reaches the page can be taught on the Phone keys screen
  (`/phone-keys`); taught keys are stored per device in `prefs.keymap` and
  checked first. In a text field, a taught key that types a character types
  it.
- For phones whose soft keys never reach the page, the screen's soft-key
  actions are repeated at the top of the menu (`*` or the ☰ button), so
  everything stays reachable with the D-pad and OK. The phone's own Back
  goes through history, which Dumbcourse already follows.
- The first unknown key pressed on a phone-sized screen gets a one-time
  toast pointing to Phone keys.

## Security notes

- The page's CSP allows scripts only from this site plus the inlined early
  script by hash; no `unsafe-inline`/`unsafe-eval`. Boot data is JSON in a
  `type="application/json"` block, escaped with `ERB::Util.json_escape`.
- `html``` escapes every interpolation; `raw()` is only for HTML Discourse
  has already sanitised (cooked posts) and our own SVG icons. URLs in
  attributes go through `safeUrl()` where they come from users.
- Per-account data on the phone (drafts, cache, recent searches) lives under
  `dc:user:` / `dc:cache:` and is wiped on logout or account switch.
- Device pairing: code (~40 bits) + a secret in an encrypted HttpOnly cookie
  held only by the requesting browser; lookups/approvals rate limited per
  person and IP; API keys and impersonation refused; the approver sees the
  device and whether it's on their network.
