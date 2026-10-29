// Everything the server puts in the page (window.DUMBCOURSE_SETTINGS), so
// the first screen needs no extra round trips on a slow connection. See
// AppController#boot_payload for the other side.

export interface BootUser {
  id: number;
  username: string;
  name: string | null;
  avatar_template: string;
  admin: boolean;
  moderator: boolean;
  trust_level: number;
  can_send_private_messages: boolean;
  can_tag_topics: boolean;
  can_create_tag: boolean;
  can_review: boolean;
  reviewable_count: number;
  unread_notifications: number;
  unread_high_priority_notifications: number;
  all_unread_notifications_count: number;
  new_personal_messages_notifications_count: number;
  reqpm_available: boolean;
  reqpm_incoming_count: number;
  // 1 while Vote Week is open and this voter hasn't voted.
  mod_election_vote_due: number;
  can_pair_devices: boolean;
  second_factor_enabled: boolean;
  can_change_post_owner: boolean;
  // May post core's staff-only whispers.
  whisperer: boolean;
}

// The forum's switches the staff menus need (see AppController#staff_settings).
export interface StaffSettings {
  badgesEnabled: boolean;
  reviewableClaiming: string;
  whisperConvert: boolean;
  whisperAddParticipant: boolean;
  whisperTargeted: boolean;
}

export interface BootCategory {
  id: number;
  name: string;
  slug: string;
  color: string;
  text_color: string;
  parent_category_id: number | null;
  description_text: string | null;
  topic_count: number;
  permission: number | null;
  read_restricted: boolean;
  position: number;
  subcategory_ids?: number[];
  // What a new topic here needs. A group's name is only there for people
  // who can edit the category.
  minimum_required_tags?: number;
  required_tag_groups?: Array<{ name?: string; min_count: number }>;
}

export interface AuthProvider {
  name: string;
  title: string;
}

export interface UserField {
  id: number;
  name: string;
  description: string;
  field_type: string;
  required: boolean;
  show_on_signup: boolean;
  options: string[];
}

export interface BootSettings {
  version: string;
  basePath: string;
  subfolder: string;
  csrf: string;
  siteTitle: string;
  siteIcon: string;
  defaultTheme: string;
  defaultView: string;
  paginationEnabled: boolean;
  topicsPerPage: number;
  showCategoryNames: boolean;
  topicPostersVisibility: string;
  onlineGlowEnabled: boolean;
  languagetoolEnabled: boolean;
  pushEnabled: boolean;
  customEmojis: Record<string, string>;
  // Emoji image URL with EMOJINAME as the placeholder.
  emojiUrl: string;
  reactions: { enabled: boolean; main: string; list: string[] };
  noReactionCategoryIds: number[];
  reqpmCountryCode: string;
  modElectionsEnabled: boolean;
  tagsEnabled: boolean;
  maxPostLength: number;
  minPostLength: number;
  minTitleLength: number;
  allowUploads: boolean;
  authorizedExtensions: string;
  notificationTypes: Record<string, number>;
  // Server-rendered text for this plugin's custom notifications, by key.
  notificationTexts: Record<string, string>;
  flagTypes: Array<{
    id: number;
    name: string;
    description: string;
    is_custom_flag: boolean;
    require_message: boolean;
  }>;
  categories: BootCategory[];
  currentUser: BootUser | null;
  staff: StaffSettings | null;
  auth: {
    local: boolean;
    emailLink: boolean;
    emailCode: boolean;
    pairing: boolean;
    signup: boolean;
    inviteOnly: boolean;
    mustApprove: boolean;
    fullNameRequired: boolean;
    fullNameVisible: boolean;
    usernameMin: number;
    usernameMax: number;
    passwordMin: number;
    userFields: UserField[];
    providers: AuthProvider[];
    hcaptchaSiteKey: string;
  };
}

const DEFAULTS: BootSettings = {
  version: "0",
  basePath: "/dumb",
  subfolder: "",
  csrf: "",
  siteTitle: "Forum",
  siteIcon: "",
  defaultTheme: "auto",
  defaultView: "latest",
  paginationEnabled: false,
  topicsPerPage: 30,
  showCategoryNames: true,
  topicPostersVisibility: "all",
  onlineGlowEnabled: true,
  languagetoolEnabled: false,
  pushEnabled: false,
  customEmojis: {},
  emojiUrl: "/images/emoji/twitter/EMOJINAME.png?v=15",
  reactions: { enabled: false, main: "heart", list: [] },
  noReactionCategoryIds: [],
  reqpmCountryCode: "1",
  modElectionsEnabled: false,
  tagsEnabled: false,
  maxPostLength: 32000,
  minPostLength: 1,
  minTitleLength: 1,
  allowUploads: true,
  authorizedExtensions: "",
  notificationTypes: {},
  notificationTexts: {},
  flagTypes: [],
  categories: [],
  currentUser: null,
  staff: null,
  auth: {
    local: true,
    emailLink: false,
    emailCode: false,
    pairing: false,
    signup: true,
    inviteOnly: false,
    mustApprove: false,
    fullNameRequired: false,
    fullNameVisible: false,
    usernameMin: 3,
    usernameMax: 20,
    passwordMin: 10,
    userFields: [],
    providers: [],
    hcaptchaSiteKey: "",
  },
};

// The server embeds the boot data as JSON in <script type="application/json"
// id="dc-boot"> — data, never executed, so the page needs no inline script.
function given(): Partial<BootSettings> {
  const el = document.getElementById("dc-boot");
  if (el) {
    try {
      return JSON.parse(el.textContent || "{}") || {};
    } catch {
      return {};
    }
  }
  return (
    (window as unknown as { DUMBCOURSE_SETTINGS?: Partial<BootSettings> })
      .DUMBCOURSE_SETTINGS || {}
  );
}

function read(): BootSettings {
  const given = givenSettings;
  const out = {} as Record<string, unknown>;
  for (const key in DEFAULTS) {
    if (!DEFAULTS.hasOwnProperty(key)) continue;
    const value = (given as Record<string, unknown>)[key];
    out[key] =
      value === undefined || value === null
        ? (DEFAULTS as unknown as Record<string, unknown>)[key]
        : value;
  }
  // currentUser is legitimately null.
  out.currentUser = given.currentUser || null;
  const auth = {} as Record<string, unknown>;
  const givenAuth = (given.auth || {}) as unknown as Record<string, unknown>;
  for (const key in DEFAULTS.auth) {
    if (!DEFAULTS.auth.hasOwnProperty(key)) continue;
    const v = givenAuth[key];
    auth[key] =
      v === undefined || v === null
        ? (DEFAULTS.auth as unknown as Record<string, unknown>)[key]
        : v;
  }
  out.auth = auth;
  return out as unknown as BootSettings;
}

const givenSettings = given();
export const settings: BootSettings = read();

// "/forum/dumb" when Discourse runs in a subfolder.
export const APP_ROOT = settings.subfolder + settings.basePath;
