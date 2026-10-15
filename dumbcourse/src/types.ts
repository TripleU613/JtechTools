// The parts of Discourse's JSON that Dumbcourse reads. Everything is
// optional-ish on purpose: plugins and versions add and drop fields.

export interface BasicUser {
  id: number;
  username: string;
  name?: string | null;
  avatar_template: string;
}

export interface TopicListItem {
  id: number;
  title: string;
  fancy_title?: string;
  slug: string;
  posts_count: number;
  reply_count?: number;
  highest_post_number: number;
  created_at: string;
  last_posted_at: string | null;
  bumped_at?: string;
  unseen?: boolean;
  last_read_post_number?: number | null;
  unread_posts?: number;
  new_posts?: number;
  pinned?: boolean;
  closed?: boolean;
  archived?: boolean;
  visible?: boolean;
  bookmarked?: boolean;
  liked?: boolean;
  excerpt?: string | null;
  views?: number;
  like_count?: number;
  category_id?: number | null;
  tags?: Array<string | { name: string }>;
  posters?: Array<{
    user_id: number;
    description?: string;
    extras?: string | null;
  }>;
  last_poster_username?: string;
  archetype?: string;
  notification_level?: number;
  is_hot?: boolean;
}

export interface TopicListResponse {
  users?: BasicUser[];
  topic_list?: {
    topics: TopicListItem[];
    more_topics_url?: string;
    per_page?: number;
    categories?: Array<{ id: number }>;
  };
}

export interface ReactionCount {
  id: string;
  type?: string;
  count: number;
}

export interface ActionSummary {
  id: number;
  count?: number;
  acted?: boolean;
  can_act?: boolean;
  can_undo?: boolean;
}

export interface PollOption {
  id: string;
  html: string;
  votes?: number;
}

export interface Poll {
  name: string;
  type: string;
  status: string;
  results: string;
  public?: boolean;
  min?: number | null;
  max?: number | null;
  options: PollOption[];
  voters: number;
  title?: string | null;
  close?: string | null;
}

export interface Post {
  id: number;
  post_number: number;
  post_type: number;
  username: string;
  name?: string | null;
  avatar_template: string;
  user_id: number;
  created_at: string;
  updated_at?: string;
  cooked: string;
  raw?: string;
  reply_count?: number;
  reply_to_post_number?: number | null;
  reply_to_user?: { username: string; avatar_template: string } | null;
  topic_id: number;
  topic_slug?: string;
  can_edit?: boolean;
  can_delete?: boolean;
  can_recover?: boolean;
  can_wiki?: boolean;
  deleted_at?: string | null;
  hidden?: boolean;
  wiki?: boolean;
  yours?: boolean;
  admin?: boolean;
  moderator?: boolean;
  staff?: boolean;
  trust_level?: number;
  user_title?: string | null;
  flair_name?: string | null;
  action_code?: string | null;
  bookmarked?: boolean;
  bookmark_id?: number | null;
  actions_summary?: ActionSummary[];
  reactions?: ReactionCount[];
  current_user_reaction?: {
    id: string;
    type: string;
    can_undo: boolean;
  } | null;
  current_user_used_main_reaction?: boolean;
  reaction_users_count?: number;
  polls?: Poll[];
  polls_votes?: Record<string, string[]>;
  read?: boolean;
  version?: number;
  mod_is_whisper?: boolean;
  mod_whisper_targets?: Array<{ username: string }>;
  mod_whisper_target_groups?: Array<{ name: string }>;
  mod_whisper_target_badges?: Array<{ name: string }>;
  mod_whisper_is_staff_only?: boolean;
  mod_whisper_admins_only?: boolean;
  user_status?: { emoji?: string; description?: string } | null;
}

export interface TopicDetails {
  can_edit?: boolean;
  can_delete?: boolean;
  can_recover?: boolean;
  can_create_post?: boolean;
  can_reply_as_new_topic?: boolean;
  can_flag_topic?: boolean;
  can_close_topic?: boolean;
  can_archive_topic?: boolean;
  can_pin_unpin_topic?: boolean;
  can_toggle_topic_visibility?: boolean;
  can_moderate_category?: boolean;
  can_split_merge_topic?: boolean;
  notification_level?: number;
  participants?: BasicUser[];
  created_by?: BasicUser;
  last_poster?: BasicUser;
  allowed_users?: BasicUser[];
}

export interface Topic {
  id: number;
  title: string;
  fancy_title?: string;
  slug: string;
  posts_count: number;
  highest_post_number: number;
  last_read_post_number?: number | null;
  created_at: string;
  last_posted_at?: string;
  category_id?: number | null;
  tags?: Array<string | { name: string }>;
  archetype: string;
  closed?: boolean;
  archived?: boolean;
  pinned?: boolean;
  pinned_at?: string | null;
  visible?: boolean;
  views?: number;
  like_count?: number;
  reply_count?: number;
  word_count?: number;
  bookmarked?: boolean;
  deleted_at?: string | null;
  message_bus_last_id?: number;
  post_stream: { posts: Post[]; stream: number[] };
  details: TopicDetails;
  suggested_topics?: TopicListItem[];
}

export interface Notification {
  id: number;
  notification_type: number;
  read: boolean;
  high_priority?: boolean;
  created_at: string;
  post_number?: number | null;
  topic_id?: number | null;
  slug?: string | null;
  fancy_title?: string | null;
  acting_user_avatar_template?: string | null;
  acting_user_name?: string | null;
  data: Record<string, unknown>;
}
