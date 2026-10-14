# JTech theme

The forum's own theme ships with the plugin: AMOLED black and pure white, monochrome everywhere, hairline borders, rounded ("squircle") corners and the Geist typeface. Light and dark are exact inverses and follow each person's colour-mode choice. People who want stock Discourse can pick **Discourse** (its look as well as its colours, on soft greys in dark), and people who want colour can pick one of eight palettes; black and white stays the default. The palette button in the sidebar footer (in the ☰ menu on a phone) switches with one click, no reload.

What it adds on top of a restyle:

- **Topic cards** instead of table rows, with the first image beside the title and a Quick look preview.
- **A front-page hero**: the headline, search and a way in for visitors beside a turning planet of dots (setting `hero_planet`), with **category and tag banners** and a **footer** with link columns.
- The **about page** with its counts as tiles and the staff as cards.
- **⌘K / Ctrl+K command menu** to jump to pages, categories, topics and people. The header's search field opens it. For people who can use chat, ⌘K stays chat's channel switcher (core binds it) and the menu opens from the search field only; "/" still opens Discourse's own search.
- **Header**: search (in the middle of the bar on wide screens), JTech homepage, messages and notifications (with unread counts), new topic. Light/dark is in the sidebar's Color mode menu and the command menu; setting `header_color_toggle` puts an icon for it in the header too. The avatar opens your profile menu (account, preferences, log out); staff keep core's review-queue badge on it, and while that shows, the avatar opens the review queue.
- **Sidebar**, **profiles**, **users directory**, **full-page search** and **empty pages** redesigned; site notices get a dismiss button.
- A **login gate** for chosen categories and tags: logged-out visitors see a topic's first lines fade into a card to log in or create an account.
- **Lucide icons**: Discourse's icons in Lucide's thin outline style (lucide.dev) instead of Font Awesome, as ChatGPT and Gemini use.
- The **tags page** as chips with their counts, instead of columns of "name x 190".
- An overlay page scrollbar, a back-to-top button, reading progress, language labels on code blocks, category icons on the categories page.

Each of those has its own switch in the theme's settings.

The command menu shows each command's keyboard shortcut beside it: Discourse's own (`g l` Latest, `g n` New, …), plus `g g` Tags, `g i` Notifications, `g e` Preferences, `g a` Admin and `g o` light / dark, which the theme adds and lists in the `?` help. They work anywhere outside a text field; in the open menu, typing searches.

## Installing it

Installing or updating the plugin (a rebuild) installs the theme and keeps it up to date. It runs with the database migrations, the way Discourse installs its own themes.

The plugin **never** makes it the default theme and never offers it to users. To use it, go to **Admin → Customize → Themes → JTech** and:

1. Preview it as staff first (**Preview**, or `?preview_theme_id=<id>`).
2. Attach the components you still want; [Your current components](#your-current-components) says which ones JTech already covers and which clash with it.
3. Make it the default, or let users choose it.

Your choices there stay put: the default and user-selectable choice, attached components, the theme's settings and any colour-palette or theme site-setting changes all survive updates. What doesn't survive is editing the theme's files in the admin theme editor (CSS, JS): the next update replaces them with the plugin's copy. Put local tweaks in a small component instead, or change `themes/jtech` in the plugin.

- **Already had JTech installed by hand** (from its old Git repo, as an uploaded zip, or synced with the theme CLI)? The first install takes that theme over and updates it in place, so its default status, components and settings carry on and you don't get a second "JTech". It stops following the Git repo from then on.
- **Deleting the theme** keeps it deleted. To bring it back, turn `jtech_theme_install` off and on again, or run `rake jtech:theme:install`.
- **Turning off `jtech_theme_install`** stops installs and updates. The installed theme stays as it is. Turning it back on installs straight away (it doesn't wait for a rebuild).

## Your current components

JTech replaces the forum's theme components: each one it covers has a JTech setting, and the rest either clash with it or aren't needed any more (below). The forum runs without components since October 2026.

**Built in (the JTech setting is on by default unless the notes say otherwise):**

| Component | JTech setting | Notes |
| --- | --- | --- |
| Header Glass Fork JUNIV | — | JTech's own header. |
| Welcome Link Banner | `hero_*` | The hero takes its place, without the four links. |
| Landing page links (leave the forum) | — | Header, footer and links in posts all open non-forum pages as a page load. |
| Be the first to reply | `first_reply_prompt` | Copy the component's hidden categories into `first_reply_prompt_hidden_categories` (13, 15, 22, 25, 28, 29, 30, 31, 34, 49 on the forum today). |
| Discourse Code Block Line Numbers | `code_line_numbers` | A gutter beside the code, so copying a block copies only the code. |
| Hide Lock Badge Icon | `hide_lock_icons` | |
| Last Seen User Card | `user_card_last_seen` | People who turn on "hide my public profile and presence" are left out. That preference also replaces the CSS that hides it for one user. |
| Discourse Jump Buttons | `topic_jump_buttons` | Under the timeline, and beside the progress button on phones. |
| Copy post button | `copy_post_button`, `copy_post_groups` | Copies the post's Markdown, beside Copy link. Trust level 1 and up by default, as on the forum. |
| Admin Warnings | `closed_reply_warning` | The same note when staff or a category moderator reply to a closed or archived topic, with Open Topic / Unarchive buttons. Its custom message setting isn't carried over (the forum left it blank). |
| Discourse Highlight to Search | `selection_search` | Search beside Quote, Edit and Copy over selected text; opens the search page. Selections over 100 characters don't get it. |
| Unanswered Filter | `replies_filter` | A third dropdown beside categories and tags: all topics, with replies, no replies (core's `max_posts` / `min_posts` list filters). For everyone, as on the forum; like the component's dropdown, phones don't show it (core hides those dropdowns there). |
| Topic PDF Download Button | `print_button_categories` | Off until you list categories (Exclusive on the forum today; subcategories count). Print on the topic's first post, which prints that post on its own (or saves it as a PDF from the print dialog), as the component did with its default "first post only". Discourse's own print view (Ctrl+P on a topic) prints the whole topic. |
| DiscoTOC | `table_of_contents`, `table_of_contents_categories` | Copy the auto categories (Android Guides on the forum today). First posts there, and any first post with DiscoTOC's marker (the composer's ⚙ menu → Table of contents still adds it), get contents once they have 3 headings: in the timeline's column on desktop, with the section being read marked (Contents folds it and brings the timeline back), and a card at the top of the post on phones. |
| Voice Recorder | `voice_recorder` | A microphone in the composer's toolbar: record, listen back, add to the post through the normal uploader. It records m4a (Safari, Chrome) or ogg (Firefox) instead of the component's mp3, so it needs no encoder and plays as audio everywhere; both are in the forum's `authorized_extensions` today. A recording stops before it would pass `max_attachment_size_kb`. |
| Post Badges | `post_badges` | Copy the component's badge names without the stray spaces: on the forum today `Senior Mitmachim Top Member\|JS monster\|Phone Distributor\|Senior Apps4flip Member\|Jose Briones Badge\|Linux Master\|Sunday Off\|Kdroid Badge\|Megalife Support\|GreenTouch Official\|Sonim Engineer`. Discourse matches the names exactly apart from case, so the component's `Phone Distributor ` (trailing space) and `$Administrator ` never matched anything. The badges link to their badge page, as the forum had it. |
| Post Image Carousel | `image_carousels` | Posts written with its `[wrap=Carousel]` show their pictures in Discourse's own carousel, the one `[grid mode=carousel]` makes (use that for new posts); any text in the wrap stays. Its autoplay, loop and thumbnails aren't carried over (four of the forum's five carousels had them off), and nothing is loaded from a CDN any more. |
| Messages section for sidebar | `sidebar_inboxes` | An Inboxes section for people in a group with a shared inbox (moderators and admins on the forum): My messages and each group's inbox, with unread counts and a + for a new message. Everyone else has Discourse's My Messages link, which the section would only repeat. |
| Who's Online | `online_box` | With the Who's Online plugin, a button beside the topic list's tabs, "Online: 3", instead of the plugin's row of avatars over the list. Clicked, a box pops out under it with everyone online, each linking to their profile. Shown to whoever the plugin shows its row to, while its minimum are online. |
| Reader Mode | `reader_mode` | The switch at the top of the timeline, and Ctrl+Alt+R, as before: the sidebar goes, the header and the posts' buttons fade until pointed at, and the text can be made larger, the column narrower or wider, or the type a serif (kept per browser). The component's sepia and dark colours aren't carried over: the forum's own light and dark (and the palettes) cover them. |
| QR Code Shareables | `qr_code_share` | QR code among the share options (a topic, a post, the buttons over a quote): the link as a code to scan with a phone, black on white in both colour modes, with Save image. Made in the browser by the theme (Discourse only makes QR codes on the server, for two-factor setup); the component's colour, dot-style and logo settings aren't carried over. |
| Unhide composer fullscreen toggle for tablets | — | Always on. |
| Sidebar Theme Toggle | `color_mode_toggle` | Keep the component only if people should also be able to switch to another theme. |
| Gated Topics in Category | `gated_categories`, `gated_tags` | Copy the component's categories and tags (General, Android Apps, Android ROMs, Android Guides and the `roms` tag on the forum today). Off until you list some. Like the component, it's for logged-out visitors only. |
| Modern Category + Group Boxes | — | Set the site setting `desktop_category_page_style` to **Boxes**: JTech styles core's category boxes, which already show each category's icon. |

**Clash with JTech (detach):** discourse-left-side-burger (JTech keeps the ☰ at the right), Discourse Avatar Component (JTech sets avatar shape), Full width (JTech sets the page width), Density Toggle (JTech's type scale), Topic List Item Click Animation (a pressed topic card sinks in and springs back when let go, with a finger or a mouse), User Card Directory and Users Top Nav (JTech's People page).

**Not needed any more:**

- **Auto linkify words**: Discourse does this itself. Admin → Customize → Watched Words → Link turns a word into a link when a post is saved (new and edited posts; rebake older ones), so it also works in emails and excerpts. The forum's list: JTech Forums, JTech Phone Finder, JTech Apps Page, JTech Guides Page, JTech ROMs Page, JTech Resources Page, eGate, Contact JTech Forums, WebADB, zemer.
- **Reply Templates**: Discourse's bundled Templates plugin is on. No post used the component's `[wrap=template]`.
- **Sidebar Menu Reorder**: the forum kept its default order, which is Discourse's own.
- **Quick Profile Links Menu**: JTech's avatar menu and Discourse's profile tab cover it.
- **Shared Draft Button**: shared drafts aren't set up (`shared_drafts_category` is empty), so it did nothing.
- **Wikipedia Lookup**: used once, in a test message.
- **Restricted reactions (like) by group**: it never restricted anyone (it compared the setting's group IDs with group names), and hiding a button wouldn't stop the like API anyway. A real restriction belongs on the server, in the plugin.
- **chat-bubbles**: it wasn't attached to any theme.

**Not a real restriction:** JTech's login gate (like "Gated Topics in Category" before it) only hides topics in the browser. They're still sent to logged-out visitors (`/t/….json` reads them). If that needs to hold, it belongs in category permissions.

## Settings

| Setting | Default | What it does |
| --- | --- | --- |
| `jtech_theme_install` | on | Install the bundled theme and update it when the plugin updates. Never made the default. Turning it on installs now and brings back a deleted theme. |

The look itself is configured in the theme's own settings (corner style, cards, hero text, footer links, header home link and the other switches).

The theme brings its palettes in pairs, a light and a dark of each:

- **JTech Light** / **JTech Dark** (OLED black): the defaults, black and white.
- **Discourse**: stock Discourse, more than its colours. Its white and blue in light; in dark, JTech Dim's soft greys (it replaces Dim, and whoever had picked Dim moves to it) with Discourse's blue and a top bar darker than the page. Picked, the forum also takes stock Discourse's look: its topic lists (rows on a computer, its own list on a phone, not the theme's cards), its shades instead of the flattened greys (solid lines, its hover and selection tints), colour where Discourse has it (category icons and badges, letter avatars, the timeline, the online ring), 4px corners, round avatars, a solid header, uppercase sidebar headings with a line under each section, and Font Awesome icons instead of Lucide. Spacing and the header's search stay the theme's. Switching to or from it in the palette menu reloads the page, for the icons.
- **Nord**, **Catppuccin** (Latte / Mocha), **Rosé Pine** (Dawn / main), **Gruvbox**, **Tokyo Night** (Day / Night), **Everforest**, **Paper** (warm sepia for long reads) and **Horizon** (Discourse's Horizon theme: near-black on white, a periwinkle accent, periwinkle hover and selection). These follow the well-known editor palettes of the same names: their paper, ink and one accent, which colours buttons, links, the active tab, unread badges, focus rings and selected text. Where a palette's own accent or grey reads under 4.5:1 it is darkened (or lightened) until it does.

The plugin marks every palette but the two defaults "users can select" once, when it first installs it (or when an update adds it); turn one off under Customize → Colors and it stays off. Being user-selectable, they're also offered with other themes that let people pick any palette.

**Palette menu** (theme setting `palette_menu`, on): a palette button in the sidebar footer, beside Discourse's light / dark menu, lists every palette with a swatch and switches on the spot. A member's choice is saved to their account, the same setting as Preferences → Interface → Color Palette, so it follows them to other devices; a visitor's is kept in that browser. Under the palettes the same menu has **Density**, as in Gmail: Default (the cards as they are), Comfortable (cards without excerpt or picture, a little tighter) and Compact (one row a topic, in one divided list); it's kept in that browser.

## Things outside the theme

- **Brand assets.** The JTech mark, app icon and favicon are in [`docs/theme/brand/`](../theme/brand/). They're site settings (`logo_small`, `favicon`, `apple_touch_icon`…), so they apply to every theme; upload them yourself if you want them. The installed app's icon is the exception: the plugin's web manifest serves the app icon (the mark on a solid square) instead of `manifest_icon`, so it shows on a light taskbar too; setting `jtech_app_icon`. On phones the header shows `logo_small` (the square mark) instead of the wide logo, unless a `mobile_logo` is uploaded; theme setting `mobile_small_logo`. Setting `base_font` and `heading_font` to `system` stops browsers downloading Roboto, which JTech doesn't use.
- **Trust level flair.** Discourse only shows a flair someone picked under Preferences → Account, so most members show none. With `jtech_trust_level_flair` on (off by default), everyone without a flair of their own shows their highest trust level group's that has one (set the flair icons on the trust level groups under Groups; the theme draws them as rings and chevrons with `monochrome_flair`). It follows their trust level up and down, daily and whenever it changes. Picking another flair, or taking it off, keeps that choice.
- **Card thumbnails.** The theme asks Discourse for 320 px topic thumbnails, so after it's installed Sidekiq makes them for listed topics once, a few at a time.
- **Color mode menu.** The sidebar's light / dark / auto menu is Discourse's own: site setting `interface_color_selector` set to **Sidebar footer** (the forum's today). With JTech's header icon off (the default), it and the command menu are where people switch.
- **Links to the landing site** (`/home`, `/dumb`, `/terms`…): the header, footer and links inside posts open any same-site link that isn't a forum page as a normal page load, so they reach the landing site instead of the forum's 404 page.

## Before updating Discourse

A theme that breaks on a new Discourse version doesn't take the forum down: CSS keeps working, but all of JTech's JavaScript stops (hero, cards, footer) and admins see "a theme has errors". Check on a local forum first. See [development/jtech-theme.md](../development/jtech-theme.md#before-updating-discourse).
