# Repository rules

These apply to everyone who changes this repo, people and AI agents alike. [CONTRIBUTING.md](CONTRIBUTING.md) covers the how-to; this file covers what a change has to respect.

## Permissions come first

1. **Never widen access past core.** A grant adds a right on top of core; it never lets someone reach a category, topic, post or user that core hides from them. Check `can_see_*` alongside the grant.
2. **Check before you touch.** Every endpoint that loads something by id checks the caller may see it (`guardian.ensure_can_see!` or equivalent) before reading or changing it.
3. **Send to the right people.** Notifications, MessageBus messages, pushes and emails go only to users who can see what they point at. Staff aren't all-seeing: moderators don't see every private message or every restricted category.
4. **Moderators get the least that works.** A new moderator power needs a reason core doesn't cover, its own switch, and a spec showing what it does *not* allow.
5. **Hidden stays hidden.** Turning a feature off must never make private content public (see whispers).

## Don't rebuild Discourse

If core, or a plugin bundled with core, already does it, use that and delete ours. Check `config/site_settings.yml` in the Discourse repo before adding a setting. Past examples: moderator category management → `moderators_manage_categories`; username avatars → `automatically_download_gravatars` / `gravatar_enabled`.

## Every change

- **Tests.** New behavior gets a spec, and a bug fix gets a spec that fails without the fix. Never skip, disable or loosen a test to get green.
- **Green CI.** A change is done when every workflow passes on its PR and it's merged.
- **Switches.** Every module has an `enabled?` helper that includes `jtech_enabled`. Core patches and jobs must go through it, because Discourse doesn't stop them for a disabled plugin.
- **Settings.** Every setting needs a description in `server.en.yml`. Keep existing setting names, because renaming one orphans the stored value. When removing a setting, add a migration that deletes its stored row. If people relied on it, map it to its replacement.
- **Migrations** that switch a core setting on to keep old behavior are guarded with `Migration::Helpers.existing_site?`.
- **No N+1.** Anything run per post, per topic row or per recipient is batched or preloaded.

## Words on screen

- Short and plain. Say what a thing is or does, not how clever it is.
- No explanatory text in the UI where a clear label would do, and no marketing words.
- Setting descriptions may be longer; that's where the detail and caveats go.
- Errors say what happened and what to do next.

## Code

- The frontend is TypeScript (`.ts`, `.gts`), the bundled theme in `themes/jtech/` included; no `.js`/`.gjs`. `pnpm lint:types` passes with no `@ts-ignore`. The theme also passes `pnpm lint:theme`.
- Ruby follows `rubocop-discourse` and `stree`. Frontend follows `@discourse/lint-configs`.
- Dumbcourse compiles to ES5 and must keep working on Chrome 30 / Firefox 30 / Android 4.4. `pnpm dumbcourse:check` enforces it.
- Three languages: Ruby, TypeScript, SCSS. Nothing is written by hand in JavaScript, CSS, HTML, Python or shell; scripts are Ruby or TypeScript (`.mts`). Build output that browsers need (Dumbcourse's files in `public/`) is marked `linguist-generated` in `.gitattributes`. `pnpm lint:languages` enforces it.
- Comments explain *why*, not *what*.
- Match the code around you.

## Git

- Work on a branch and open a PR against `main` using the template. PRs are squash-merged.
- Commit messages say what changed and why, in plain sentences.
