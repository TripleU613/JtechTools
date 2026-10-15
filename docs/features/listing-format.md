# Listing format: sale threads that stay tidy

For threads like *Hardware: phones and computers for sale*, where every post is a listing. In the topics you choose, a post has to follow the thread's format, or it's turned away with the reason before it's saved.

- **Listings as cards.** Each listing shows as a card: the item as its title, the other sections as labelled boxes, the pictures underneath. Anything else written in the editor with the pictures ("for best offer") shows under the boxes as the seller's own words, not as pictures. Posts that aren't listings look as before.
- **Available or sold.** The foot of each listing's card says whether it's still available. The seller, admins and moderators get a button there to mark it sold, or available again. A sold listing's card is faded and its item crossed out.
- **Create listing.** Members get a centered **Create listing** button at the bottom of the topic in place of Reply, and the posts lose their Reply buttons. Staff keep Reply.
- **A form for the sections.** Create listing opens the composer with a box for each section (ITEM, QUANTITY, CONDITION, SPECS, PICKUP LOCATION OR SHIPPING AVAILABLE) above the editor. The section names can't be changed. Pictures go in the editor, which fills the IMAGES section. The post comes out in the thread's layout: `### ITEM` with the item under it, and so on. On phones the form stays in view while typing in the editor.
- **Optional sections.** IMAGES may be left empty, for a listing without pictures; it's marked optional in the form and left out of the post (`listing_format_optional_fields`).
- **Pickup needs a location.** Ticking Pickup makes the box under it required, and a post that just says "Pickup" is turned away. An option ending in `*` in the setting works this way.
- **Options to pick.** CONDITION has New, Like new, Used and For parts to pick one of; PICKUP LOCATION OR SHIPPING AVAILABLE has Pickup and Shipping available to tick either or both. Each still has a box for anything else, like where to pick up.
- **REQ-PM, not replies.** Each listing has the seller's REQ-PM button where Reply used to be. Buyers request the seller's contact details there instead of commenting in the thread. It's the same REQ-PM window as on a user card, so it's only there for people who can use REQ-PM (`reqpm_allowed_groups`), and the seller chooses what to send. A comment such as "still available?" isn't a listing, so it's turned away.
- **Sections.** Posts written by hand (editing, Dumbcourse, the API) need every section with something under it. A heading of any size, a bold name or `ITEM: …` on one line all count, in any case. Sections inside a quote don't count.
- **No outside links.** Links to other sites (eBay, Amazon, a store) are turned away, whether they're links or typed as text like `ebay.com/itm/123`. Email addresses, phone numbers, links to the forum and uploaded pictures are fine.
- **Posts from before are kept.** Adding a topic never hides or deletes what's already there. An older post can still be edited (to mark it sold, say) without adding the sections; the edit just can't add an outside link.
- **Edits.** A listing can't lose a section or gain an outside link by being edited.
- **Staff** don't have to follow it, and keep their Reply buttons, so moderators can post reminders and answer people (`listing_format_exempt_groups`).

To explain the format before people post, add a [topic checklist](moderator-tools.md#checklists) to the same topic.

## Choosing topics

Put the topic's number, or paste its address, in `listing_format_topics`. For `https://jtechforums.org/t/hardware-phones-computers-for-sale-thread/32/232` that's topic 32; pasting the whole address works too.

## Settings

Admin → Plugins → Jtech Tools → **Listing format**. The full text of each setting is shown next to it in the admin.

| Setting | Default | What it does |
| --- | --- | --- |
| `listing_format_enabled` | `false` | Makes posts in the topics below follow a set format, for sale threads where every post is a listing. |
| `listing_format_topics` | (none) | Topics where the format applies. |
| `listing_format_fields` | `ITEM\|QUANTITY\|CONDITION\|SPECS\|IMAGES\|PICKUP LOCATION OR SHIPPING AVAILABLE` | Sections each listing needs. |
| `listing_format_single_choice` | `CONDITION: New, Like new, Used, For parts` | Sections where the reply form offers options to pick one of. |
| `listing_format_optional_fields` | `IMAGES` | Sections from the list above that may be left empty. |
| `listing_format_multiple_choice` | `PICKUP LOCATION OR SHIPPING AVAILABLE: Pickup*, Shipping available` | Sections where the reply form offers options to tick any of. |
| `listing_format_editor_field` | `IMAGES` | The section filled from the composer's editor, where pictures are uploaded. |
| `listing_format_block_links` | `true` | Turns away posts in these topics that link to other sites, typed or as a link. |
| `listing_format_exempt_groups` | `3` | Groups who can post in these topics without following the format, for reminders and staff notes. |

[← All features](../README.md#features)
