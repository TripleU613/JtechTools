# Discord mirror

A live, read-only copy of the forum's public categories in a Discord server.

| Forum | Discord |
|---|---|
| Top-level category | Channel category |
| Category or subcategory | Forum channel (read-only for members) |
| Topic | Thread (forum post) |
| Post | Message under the author's name and avatar, with a link back and the original time |

## What is sent

Only what a logged-out visitor can read on the forum. Never sent: private
categories, private messages, whispers (core and ours), staff notes, hidden
posts, unlisted topics, category "About" topics and categories listed in
`discord_mirror_excluded_categories`. Posts never ping anyone on Discord.

When something stops being public it is taken down from Discord: a deleted,
hidden or whispered post loses its message; a deleted, unlisted or privately
moved topic loses its thread; a category made private loses its channel. Events
trigger this straight away, and a check every 10 minutes catches anything that
changed without one (posts hidden by flags, for example).

Edits update the message. Closed topics lock their thread. An anonymized
member's messages are sent again under the new name.

## Setup

1. Discord Developer Portal → the app → Bot: reset the token and paste it into
   `discord_mirror_bot_token`. Invite the bot with Manage Channels, Manage
   Roles, Manage Webhooks, Manage Threads, View Channels, Send Messages, Send
   Messages in Threads, Embed Links, Attach Files and Read Message History.
2. Put the server ID in `discord_mirror_guild_id`.
3. Turn on `discord_mirror_enabled`. The channels are built within a minute,
   then `discord_mirror_backfill_days` of past topics are copied, oldest first.
   Backfilled threads are archived when quiet so they don't count toward
   Discord's active-thread cap.

The mirror only touches channels it created. Delete one on Discord and it is
rebuilt on the next hourly check.
