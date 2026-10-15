# Dislike

In the categories you pick, likes stop mattering. They still show on the post, but, depending on the switches:

- the author isn't notified. This applies to discourse-reactions reactions too.
- they leave no "Likes Given / Received" history;
- they don't count toward likes given and received in the user directory, on user cards or on profiles. The totals are corrected each time the directory refreshes (hourly).

You can also hide the like button in those categories, or allow it only for some groups. Badges, trust levels and the like count on the post itself are core's and still see the likes.

Every phantom like and reaction can be recorded in an audit table (`discourse_no_likes_phantoms`), which you can query with Data Explorer.

**Purge phantom likes** on the Dislike tab applies the settings to likes made before a category was restricted. It back-fills the audit table, removes old history rows and notifications (unless history is kept), and recalculates the totals. It never deletes likes.

## Settings

Admin → Plugins → Jtech Tools → **Dislike**. The full text of each setting is shown next to it in the admin.

| Setting | Default | What it does |
| --- | --- | --- |
| `discourse_no_likes_enabled` | `false` | Turn on phantom reactions. |
| `no_reactions_category_ids` | `(blank)` | Categories in which likes and reactions are treated as "phantom". |
| `dislike_hide_like_button` | `false` | Hide the like and reaction buttons in these categories, and reject like requests that reach the API anyway. |
| `dislike_allowed_like_groups` | `(blank)` | Restrict liking in these categories to members of these groups; everyone else gets no like button. |
| `dislike_show_in_history` | `false` | Treat phantom likes like normal likes for history — the liker's "Likes Given", the author's "Likes Received" and the author's "liked" or "reacted" notification. |
| `dislike_count_in_leaderboard` | `false` | Let phantom likes count toward likes given and received — the user directory, user cards and profile summaries. |
| `dislike_record_audit_trail` | `true` | Write one row per phantom reaction to the discourse_no_likes_phantoms table — likes, plus any non-default discourse-reactions emoji. |

[← All features](../README.md#features)
