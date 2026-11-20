# Reaction levels

Higher trust levels unlock more reaction emojis. discourse-reactions has one list of reactions for everyone; this holds some of them back until a member reaches a trust level.

Off by default. **Admin → Plugins → Jtech Tools → Reaction levels** has the switch, one emoji list per trust level, and a table of what each level ends up with.

## How it works

- Each trust level (0–4) has a list of reactions. A reaction listed at a level is **unlocked** there and at every level above it. If it's listed at more than one level, the lowest wins.
- Reactions enabled in discourse-reactions (`discourse_reactions_enabled_reactions`) but **listed at no level stay open to everyone**, so only the ones to hold back need listing. Listing a reaction that isn't enabled does nothing; the table flags it.
- The **main reaction** (the like) is always open. **Staff** have every reaction.
- The reactions picker shows a member only what they've unlocked. The server refuses the rest ("The :trophy: reaction unlocks at trust level 3."), so it can't be got around.
- A reaction someone already gave stays in their picker on that post, and **taking it back always works**, even if their level no longer has it.
- With `discourse_reactions_allow_any_emoji` on, emojis that aren't listed at any level stay open as before; listed ones are still held back.

## The settings

| Setting | |
|---|---|
| `jtech_reaction_levels_enabled` | The switch. |
| `jtech_reaction_levels_tl0` | Only for trust level 0 and up. Usually empty: unlisted reactions are already open to everyone. |
| `jtech_reaction_levels_tl1` … `tl4` | The reactions each level unlocks. |

## Where it lives

`lib/discourse_reaction_levels.rb` (the rules, the server check prepended onto discourse-reactions' toggle), `sub_plugins/reaction_levels.rb` (wiring; `currentUser.jt_reactions` is each member's list), `assets/javascripts/discourse/initializers/reaction-levels.ts` (the picker), and the admin tab in `admin/…/jtech-tools-reaction-levels.gts` with its table component.
