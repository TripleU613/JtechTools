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
