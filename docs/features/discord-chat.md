# Discord chat

JTech's Discord server is a general chat for members with a linked JTech
account. The forum runs who is in it; nothing posted on the forum goes to
Discord.

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
