# Disteleplus: team chat bridged to Telegram

A private one-room chat inside Discourse for staff, or any groups you allow, mirrored both ways with a Telegram group. It doesn't need the official Discourse Chat plugin.

## In Discourse

- Opens as a small drawer in the bottom-right or as a full page. On phones it's always full page.
- Supports messages, replies, edits, deletes, reactions, images, files, video, voice notes (record in the composer) and polls from Telegram.
- Right-click a message to react, reply, copy, link, quote into a new topic, edit or delete. Double-tap to react.
- `@mentions` and `:emoji:` suggestions, pasting or dragging files in, drafts kept while you browse, search, link previews and typing indicators.
- A count on the header icon and in the browser tab of the messages that @mention you (or a group you're in), which are also the only ones that notify you. Reading them clears it.
- Message text is encrypted in the database.

## In Telegram

- People you map post as their Discourse account. Everyone else shows with their Telegram name.
- Discourse messages arrive with the author's name linked to their profile.
- When someone reacts in Discourse, Telegram gets a quiet "**Name** reacted 👍" reply. The bot's own single reaction can't say who reacted.
- Optional: announce new forum posts into the group, filtered by category or tag.
- Optional: mirror the review queue (flags, queued posts) into a **Reports** topic the plugin creates. Each item has **Approve / Deny / More** buttons, which work for mapped staff and for chat admins whose Telegram username matches a staff account.

## Setup (about 5 minutes)

1. In Telegram, message **@BotFather**: `/newbot`, then copy the token. Then send `/setprivacy` and choose **Disable**, or the bot can't read the group.
2. Add the bot to your group and make it an **admin**.
3. In Discourse, go to Admin → Plugins → Jtech Tools → **Disteleplus**:
   - paste the token;
   - choose who may use the chat (`disteleplus_allowed_groups`, staff by default);
   - turn on `disteleplus_enabled`;
   - press **Register Telegram webhook**.
4. In the Telegram group, send `/disteleplus_setup` and follow the checklist.
5. Send a message from each side to check. **Send test message** and the admin dashboard help if something's off.

Telegram's own limits apply:

- the bot can't delete messages older than 48 hours;
- it can't see when Telegram users are typing;
- it shows only one reaction per message;
- converting the group to a supergroup changes its ID, so you have to bind it again.

The Reports topic needs **Topics** enabled in the group and the bot's *Manage Topics* right.

Moving from the old Chat-based bridge? An admin can import the old channel (`POST /jtech-disteleplus/legacy-import`, progress with `GET`) before switching Chat off. Nothing is deleted from the old Chat data.

## Settings

Admin → Plugins → Jtech Tools → **Disteleplus**. The full text of each setting is shown next to it in the admin.

| Setting | Default | What it does |
| --- | --- | --- |
| `disteleplus_enabled` | `false` | Two-way bridge between one Telegram group and the native /disteleplus conversation. |
| `disteleplus_bot_token` | `(blank)` | Token from @BotFather (/newbot). |
| `disteleplus_telegram_chat_id` | `(blank)` | The bridged group's numeric chat ID — a negative number such as -1001234567890. |
| `disteleplus_chat_topic_id` | `0` | Optional Telegram Forum Topic ID for the two-way conversation bridge. |
| `disteleplus_webhook_secret` | `(blank)` | Shared secret that Telegram sends back in the X-Telegram-Bot-Api-Secret-Token header; it is the only thing authenticating the inbound webhook. |
| `disteleplus_setup_commands_enabled` | `true` | Allow Telegram group administrators to bind General, bind an existing upload topic, create the upload topic, bind the moderation-reports topic, and inspect setup through /disteleplus_* commands. |
| `disteleplus_chat_channel_id` | `0` | The legacy bridged channel's numeric ID — the last part of its old URL. |
| `disteleplus_allowed_groups` | `3` | Groups allowed to open and participate in the native Disteleplus conversation. |
| `disteleplus_bridge_bot_username` | `telegram_bridge` | The Discourse account that posts Telegram messages from senders who are not mapped to a Discourse user. |
| `disteleplus_user_map` | `[]` | Telegram accounts that post into chat as a specific Discourse user. |
| `disteleplus_auto_match_usernames` | `true` | Match Telegram senders to Discourse accounts automatically when the Telegram @username is identical to a Discourse username. |
| `disteleplus_encrypt_at_rest` | `true` | Encrypt message text in the database (AES-256, key derived from the site secret) so a database dump alone does not expose the conversation. |
| `disteleplus_typing_to_telegram` | `true` | Show a "typing…" status in the Telegram group while a Discourse member is typing. |
| `disteleplus_read_receipts_enabled` | `true` | Show read receipts on your own messages in the conversation — a double check plus "Seen by N" once other members' read cursors pass the message. |
| `disteleplus_quote_in_topic_enabled` | `false` | Offer "Quote in new topic" in a message's context menu, prefilling a new forum topic with the quoted message. |
| `disteleplus_polls_enabled` | `true` | Create real Discourse polls from the conversation composer — voting, results and auto-close all run on core's poll engine via a hidden backing topic. |
| `disteleplus_event_messages` | `user_suspended|user_silenced` | Forum events that post an automatic system message into the conversation — new topics, first logins, suspensions, silences. |
| `disteleplus_bridge_uploads` | `true` | Copy photos, documents, video and audio across the bridge, in both directions, up to the size limit below. |
| `disteleplus_max_upload_mb` | `10` | Files above this size are not copied — a Telegram file becomes a placeholder line in chat, and a Discourse upload becomes a link to the forum (which needs a login if secure uploads are on). |
| `disteleplus_bridge_edits` | `true` | Editing a message updates the copy on the other side. |
| `disteleplus_bridge_deletes` | `true` | Deleting a bridged chat message also deletes it in Telegram. |
| `disteleplus_bridge_polls` | `true` | Bridge Telegram polls into chat as a text snapshot of the question and options, rewritten as votes come in so the counts stay roughly current. |
| `disteleplus_bridge_reactions` | `true` | Telegram reactions appear as chat reactions — from the matching Discourse user when there is one, from the bridge bot otherwise. |
| `disteleplus_bridge_reaction_notices` | `true` | When a Discourse member reacts to a bridged message, post a short "Name reacted 👍" reply under the Telegram copy (silently, no push). |
| `disteleplus_forum_post_notifications_enabled` | `false` | Post a summary of new forum posts into the bridged Telegram conversation (and the native conversation), the way the chat-integration plugin does. |
| `disteleplus_forum_post_categories` | `(blank)` | Only announce posts in these categories (subcategories of a listed category count). |
| `disteleplus_forum_post_tags` | `(blank)` | Only announce topics carrying at least one of these tags. |
| `disteleplus_forum_post_first_post_only` | `true` | Announce only the first post of a topic. |
| `disteleplus_forum_post_excerpt_length` | `300` | Characters of the post to include under the title. |
| `disteleplus_forum_post_link_preview` | `false` | Let Telegram render its link preview card under the announcement. |
| `disteleplus_reports_enabled` | `false` | Mirror the Discourse review queue into a Telegram topic. |
| `disteleplus_reports_chat_id` | `(blank)` | Numeric Telegram chat ID that receives moderation reports. |
| `disteleplus_reports_topic_id` | `0` | Telegram Forum Topic ID (message_thread_id) of the reports topic. |
| `disteleplus_reports_topic_name` | `Reports` | Name given to the Telegram forum topic the plugin creates for moderation reports. |
| `disteleplus_reports_excerpt_length` | `300` | Characters of the flagged/queued content shown in the report message. |
| `disteleplus_reports_admin_notices` | `true` | Also post admin notices into the reports topic — new-feature announcements ("What's new"), admin dashboard problem alerts, and a who→whom note when an official warning is issued (the warning's text stays private). |
| `disteleplus_forum_uploads_enabled` | `false` | Copy attachments from ordinary forum posts into a dedicated Telegram Forum Topic. |
| `disteleplus_forum_upload_topic_id` | `0` | Telegram message_thread_id of the archive topic. |
| `disteleplus_forum_upload_topic_name` | `Uploads` | Human-readable name shown by setup commands and used when the bot creates the archive topic. |
| `disteleplus_forum_upload_category_ids` | `(blank)` | Categories whose post attachments are mirrored. |
| `disteleplus_forum_upload_include_restricted_categories` | `false` | Also copy uploads from read-restricted categories. |
| `disteleplus_forum_upload_max_mb` | `50` | Largest file copied into Telegram. |
| `disteleplus_forum_upload_backfill_batch_size` | `25` | Number of historical upload references examined per backfill step. |
| `disteleplus_forum_upload_backfill_pause_seconds` | `10` | Delay between historical batches. |
| `disteleplus_forum_upload_backfill_spacing_seconds` | `4` | Minimum spacing between historical Telegram sends. |
| `disteleplus_force_channel_notifications` | `true` | Enrol every user in the allowed groups into the native conversation at notification level "always" (desktop alerts and web push). |
| `disteleplus_voice_notes_enabled` | `true` | Adds a microphone button to the native composer that records a voice note in the browser and sends it as its own message, and replaces the browser's default audio controls with a compact waveform player (play, scrub, speed, download). |
| `disteleplus_voice_note_max_seconds` | `300` | Longest voice note the composer will record. |
| `disteleplus_voice_player_all_audio` | `true` | Use the waveform player for every audio file in chat, not just voice notes. |

[← All features](../README.md#features)
