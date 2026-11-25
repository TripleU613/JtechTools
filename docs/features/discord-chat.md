# Discord chat

JTech's Discord server is a general chat for members with a linked JTech
account. The forum runs who is in it. Nothing posted on the forum goes to
Discord, except public topics a slash command is asked for.

## How someone gets in

1. Join the server with an invite. Until linked, only #rules and
   #link-your-account are visible.
2. Link Discord on the forum: Preferences → Account → Discord → Connect (or
   sign up / log in with Discord).
3. Within a minute the bot gives them the member role (the chat opens) and
   sets their server nickname to their forum username.

## What follows the forum

| On the forum | On Discord |
|---|---|
| Linked, active account | Member role, forum username as nickname |
| Moderator or admin | Moderator role too |
| Admin | Admin role too |
| Suspended, silenced, deactivated or unlinked | Member and staff roles removed |

## Setup

In the server, the bot's role needs Manage Roles and Manage Nicknames and must
be above the member, moderator and admin roles. Then set
`discord_chat_bot_token`, `discord_chat_guild_id` and the three role IDs, and
turn on `discord_chat_enabled`.

## Slash commands

The forum answers these in the server itself, over Discord's Interactions
Endpoint URL; there is no bot process to run.

| Command | Answer |
|---|---|
| `/search query` | Up to 5 forum topics that match, with links |
| `/guide topic` | The same, only in the Guides category (slug `guides`) |
| `/rules` | A link to `/guidelines` |
| `/whois user` | That member's forum username, trust level, join date and profile link |
| `/leaderboard` | The top 5 of the default leaderboard if Gamification is on; otherwise a link to `/leaderboard` |

Answers show only what a logged-out visitor can see: no read-restricted
categories, private messages, whispers, hidden posts or unlisted topics. On a
login-required forum `/search`, `/guide`, `/whois` and `/leaderboard` find
nothing. `/whois` answers "Not linked to a JTech account." for anyone
unlinked, staged, suspended, silenced, deactivated or whose profile is hidden
from the public, so the reply never says which. Nobody is pinged by an answer.

### Setup

1. In the Developer Portal, use the same app as the forum's Discord login
   (`discord_client_id`). Copy General Information → Public Key into
   `discord_chat_public_key`.
2. Set Interactions Endpoint URL to
   `https://<forum>/discord-chat/interactions`. Discord checks it straight
   away, so the public key has to be saved first.
3. Turn on `discord_chat_commands_enabled`. The forum registers the commands
   in the server (needs `discord_chat_bot_token` and `discord_chat_guild_id`).
   Turning it off removes them again. Changing the public key registers them
   again too.

## Moderators' log

`discord_chat_mod_log_channel_id`: a moderators-only channel where the forum
posts what it did in the server: who got in (with their forum username), who
lost access, and timeouts set and lifted. Lines never ping anyone. If a line
can't be posted it is dropped; the sync carries on.

## Timeouts from forum restrictions

`discord_chat_sync_timeouts`: while a linked member is suspended or silenced
on the forum, they are timed out in the server until it ends. Discord caps a
timeout at 28 days, so longer ones are renewed as they run down. The forum
remembers which timeouts it set and only ever lifts those, so a moderator's
own timeout in the server stays. The bot's role needs Timeout Members, and it
can't time out anyone ranked above it.

This only runs forum → server. A kick or ban in the server doesn't touch the
forum account.

## Report to moderators

`discord_chat_reports_enabled` adds "Report to moderators" to the server's
message menu (right-click or long-press a message → Apps). The reporter gets a
private "Sent to the moderators" reply; the report goes to the moderators' log
channel and, as a message, to the forum's moderators group with the reporter,
the author (with their forum accounts when linked), a link to the message and
its text as a plain code block. Nobody is pinged or @mentioned. Each member can
send 5 reports an hour, and only reports from the configured server are taken.
It works whether or not the slash commands are on.

## Welcome message

`discord_chat_welcome_message`: a direct message sent once to each member when
the chat opens for them. `{username}` becomes their forum username. Only people
who joined the server in the last 7 days are welcomed, at most 10 a minute, and
someone with direct messages closed is marked done rather than retried. Blank
sends nothing.

## Starboard

Messages that get `discord_chat_starboard_threshold` ⭐ reactions (3 by default)
are reposted once to `discord_chat_starboard_channel_id`, with the author, the
text, the first image and a link back. Only the channel IDs in
`discord_chat_starboard_channels` are read, so private channels can't leak into
it; messages older than 7 days and bot messages are skipped. The forum checks
every 2 minutes. The bot needs the Message Content intent for the text.

## Linked Roles

`discord_chat_linked_roles_enabled` lets members connect their forum account
without leaving Discord: server menu → Linked Roles → the "Linked" role →
connect. They sign in on the forum (if they aren't already), approve the app on
Discord, and the two accounts are connected just as the Discord login connects
them. The sync then hands out whatever roles the forum allows. A Discord account
already connected to someone else, or a forum account connected to a different
Discord account, is refused.

The linked role grants nothing by itself. Keep its "Linked to JTech Forums"
requirement off the member role: Discord lets people claim linked roles from its
menu, so on the member role a suspended member could claim their way back in.

Setup: Developer Portal → General Information → Linked Roles Verification URL
`https://<forum>/discord-chat/link`; OAuth2 → Redirects → add
`https://<forum>/discord-chat/link/callback`; turn the setting on (it registers
the requirement); then Server Settings → Roles → a new role with no permissions
→ Links → add JTech Forums.
