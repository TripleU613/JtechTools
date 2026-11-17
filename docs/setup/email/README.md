# JTech Forums email style

The look of every email the forum sends: the JTech logo over a rounded card, black buttons, a quiet footer, and a dark mode for clients that support it. Applied to summaries too (`apply_custom_styles_to_digest`).

To apply it:

1. Paste the `html` value of `template.yml` into the HTML tab and `email.scss` into the CSS tab at `/admin/customize/email_style`. Use the admin page rather than the console, because the page compiles the CSS.
2. Set these site settings:
   - `email_accent_bg_color`: `#000000`
   - `email_accent_fg_color`: `#FFFFFF`
   - `email_link_color`: `#000000`

How it's built:

- **Layout.** Tables, with an Outlook fallback and system fonts, so it holds up in Gmail, Apple Mail and Outlook. The dark-mode and narrow-screen rules are in the template's `<style>`, since Discourse inlines everything in the CSS tab.
- **Placeholders.** Discourse's template placeholders are `%{email_content}`, `%{email_preview}`, `%{html_lang}`, `%{dark_mode_meta_tags}` and `%{dark_mode_styles}`. The template uses all but the last, which it replaces with its own dark mode. Unsubscribe links come inside `%{email_content}` and the `List-Unsubscribe` header, not from the template.
- **Logo.** It's `/plugins/jtech-tools/jtech-app-icon.png`, which this plugin serves. The forum's `logo_small` is black on transparent and disappears in dark mode.
- **Size.** A large summary is about 88 KB of HTML. Gmail clips messages over about 102 KB, which hides the unsubscribe line. If clipped summaries show up, lower `digest_posts`.
