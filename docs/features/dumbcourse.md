# Dumbcourse: the forum for flip phones

A light version of the forum at `/dumb` for flip phones, KaiOS and old Android browsers that can't run the full site. It works with the D-pad and keypad like the phone's own apps, and on touch screens and computers too.

![Dumbcourse on a keypad phone](../images/dumbcourse.png)

- **Reading.** Latest, New, Unread, Top, Hot, categories and tags:
  - **↑↓** reads; a long post scrolls before focus moves on.
  - **←→** switches tabs.
  - Unread topics open at your first unread post, and Back returns you exactly where you were.
  - Live updates and read tracking.
- **Doing.** **OK** on a post opens its actions: like or react, reply, quote, bookmark, edit, delete, flag, copy link, every link in the post, hidden text (spoilers and details), and the post's pictures. There's a full-screen composer with mentions, emoji, formatting, uploads, preview and optional spell check. A new topic can have tags, picked from the category's or found by search, and the composer says when the category needs some.
- **Moderating.** Staff get a Moderation section in a topic's Options: close and open, pin in its category or globally (until a date, or with no end), banner, archive, list and unlist, make it a private message or a public topic again, topic timers (close, open, delete, bump, delete replies, publish to a category, at a time or after the last reply), change timestamp, reset bump date, topic slow mode, delete, restore and delete permanently. Each shows only where Discourse shows it.
- **Reacting on a touch screen.** The smile beside a post's like rolls its reactions out in the post's footer, in a row to swipe through; tap one to react, or the smile again to put them away. On the keypad, React… in the post's actions picks from a grid.
- **Pictures.** **View picture** opens it full screen; with several, a gallery of thumbnails comes first. **OK** zooms (fit, 2×, 3×), the D-pad moves a zoomed picture around or, at fit, goes to the previous / next picture, `4` / `6` go to the previous / next picture at any zoom, and the right soft key saves a forum upload to the phone.
- **Your stuff.** Notifications, bookmarks, drafts, messages, profile, search and REQ-PM, with one-press **Call / Text / WhatsApp**. During mod elections, the ballot: pick a candidate and press 1–9 to rank them.
- **Signing in without typing a password on a keypad.** Approve the phone from another signed-in device, or use an emailed link or code, social logins, or password plus two-factor code. Sign-up, password reset and account activation work here too.
- **Keys.**
  - Anywhere: `*` menu, `#` search, `0` help, `1`/`7` top and bottom, `2`/`8` page up and down, `4` back.
  - In a topic: `3` reply, `5` like, `9` jump to post.
  - Soft keys that a phone names oddly can be taught under Preferences → Phone keys.
  - In the Android app on a keypad phone, the app draws the soft-key bar and handles the soft keys itself. Preferences → Phone keys → Detect soft keys finds keys it doesn't know.
- **Looks.** Light, dark or automatic; text size; compact layout; avatars on or off; data saver. All chosen per phone. The colours are the forum's: the palettes chosen on the full site (Preferences → Interface, or the sidebar's palette button), else the forum theme's own, black and white with JTech. Browsers too old for CSS custom properties (Chrome before 49) always get JTech's black and white.
- **Old phones find it by themselves.** Browsers that can't run the full forum are sent to the matching Dumbcourse page, including links in emails. Search engines never are (`dumbcourse_redirect_legacy_browsers`).
- **Safe by construction.**
  - Strict Content-Security-Policy and no framing.
  - Everything escaped by default.
  - Private data kept per account and wiped on logout.
  - Rate limits.

How it's built: [development/dumbcourse.md](../development/dumbcourse.md).

## Settings

Admin → Plugins → Jtech Tools → **Dumbcourse**. The full text of each setting is shown next to it in the admin.

| Setting | Default | What it does |
| --- | --- | --- |
| `dumbcourse_enabled` | `false` | Serve the Dumbcourse single-page app at the base path below. |
| `dumbcourse_base_path` | `dumb` | First URL segment the app is served from, without slashes — "dumb" serves it at /dumb. |
| `dumbcourse_default_theme` | `auto` | Colour scheme applied the first time someone opens the app. |
| `dumbcourse_default_view` | `latest` | Topic list shown when someone opens the app at its root URL. |
| `dumbcourse_show_category_names` | `true` | Show each topic's category name on the topic list rows. |
| `dumbcourse_topic_posters_visibility` | `all` | Which devices show the latest-poster avatars on topic list rows. |
| `dumbcourse_online_glow_enabled` | `true` | Draw a glow ring around the avatars of users who are currently online. |
| `dumbcourse_device_pairing_enabled` | `true` | Offer "Sign in with another device" — the phone shows a short code, and the member approves it from any device where they're already signed in (like signing in to a TV). |
| `dumbcourse_redirect_legacy_browsers` | `true` | Send visitors whose browser can't run the full forum (KaiOS, Opera Mini, old Android and Chrome/Firefox versions, and anything in browser update user agents) to the matching Dumbcourse page instead of the broken full site — including sign-in, email-login and password-reset links. |
| `dumbcourse_sidebar_link_enabled` | `true` | Add a Dumbcourse link to the sidebar of the main Discourse forum, pointing at the base path above. |
| `dumbcourse_pagination_enabled` | `false` | Use Prev/Next page buttons on topic lists instead of infinite scroll. |
| `dumbcourse_topics_per_page` | `30` | Topics fetched per page. |
| `dumbcourse_push_enabled` | `false` | Allow devices to register for push notifications and publish each new notification to Redis. |
| `dumbcourse_languagetool_enabled` | `false` | Add a Refine button to the Dumbcourse app's reply, edit, new-topic and new-message composers. |
| `dumbcourse_languagetool_mode` | `self_hosted` | Which LanguageTool backend to use. |
| `dumbcourse_languagetool_url` | `(blank)` | Self-hosted mode only. |
| `dumbcourse_languagetool_secret` | `(blank)` | Self-hosted mode only, optional. |
| `dumbcourse_languagetool_api_url` | `https://api.languagetool.org/v2/check` | Cloud API mode only. |
| `dumbcourse_languagetool_api_username` | `(blank)` | Cloud API mode only, optional. |
| `dumbcourse_languagetool_api_key` | `(blank)` | Cloud API mode only. |

[← All features](../README.md#features)
