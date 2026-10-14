// The module core's theme compiler gives every file of a theme
// (themes/jtech): that theme's settings and its translation-key prefix.
// @discourse/types doesn't describe it. Keep JtechThemeSettings in step with
// themes/jtech/settings.yml; files take the setting types from here too
// (`import type { JtechThemeFooterLink } from "virtual:theme"`).

declare module "virtual:theme" {
  export interface JtechThemeFooterLink {
    section: string;
    title: string;
    url: string;
  }

  export interface JtechThemeSettings {
    monochrome_categories: boolean;
    monochrome_letter_avatars: boolean;
    monochrome_heatmap: boolean;
    lucide_icons: boolean;
    monochrome_flair: boolean;
    corner_style: "squircle" | "sharp" | "soft" | "round";
    topic_cards: boolean;
    hero_enabled: boolean;
    hero_title: string;
    hero_subtitle: string;
    hero_search_placeholder: string;
    hero_dismissible: boolean;
    hero_planet: boolean;
    footer_enabled: boolean;
    footer_tagline: string;
    footer_links: JtechThemeFooterLink[];
    category_banners: boolean;
    tag_banners: boolean;
    external_link_icon: boolean;
    header_home_url: string;
    color_mode_toggle: boolean;
    header_color_toggle: boolean;
    palette_menu: boolean;
    density_menu: boolean;
    overlay_scrollbar: boolean;
    back_to_top: boolean;
    command_menu: boolean;
    card_thumbnails: boolean;
    code_language_labels: boolean;
    code_line_numbers: boolean;
    // List settings arrive as one "|"-separated string.
    internal_hosts: string;
    reading_progress: boolean;
    quick_look: boolean;
    first_reply_prompt: boolean;
    first_reply_prompt_hidden_categories: string;
    user_card_last_seen: boolean;
    topic_jump_buttons: boolean;
    hide_lock_icons: boolean;
    mobile_small_logo: boolean;
    gated_categories: string;
    gated_tags: string;
    copy_post_button: boolean;
    copy_post_groups: string;
    // added by core for a group list with resolve_group_membership
    user_in_copy_post_groups?: boolean;
    closed_reply_warning: boolean;
    selection_search: boolean;
    replies_filter: boolean;
    print_button_categories: string;
    table_of_contents: boolean;
    table_of_contents_categories: string;
    voice_recorder: boolean;
    post_badges: string;
    image_carousels: boolean;
    sidebar_inboxes: boolean;
    online_box: boolean;
    reader_mode: boolean;
    qr_code_share: boolean;
  }

  export const settings: JtechThemeSettings;
  export function themePrefix(key: string): string;
}
