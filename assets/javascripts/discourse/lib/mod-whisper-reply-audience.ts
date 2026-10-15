// Compute the reply audience for a moderator whisper: the original post's
// author plus every explicit target, deduplicated by id, minus the current
// user themself.
//
// Returns an array of { id, username, avatar_template } objects. Safe to call
// with any shape of post / currentUserId — returns [] when inputs are missing.
export interface WhisperTargetUser {
  id: number;
  username: string;
  avatar_template?: string;
}

export interface WhisperTargetGroup {
  id: number;
  name: string;
}

export interface WhisperTargetBadge {
  id: number;
  name: string;
}

// The whisper attributes the post serializer adds to a post.
export interface WhisperPostFields {
  mod_is_whisper?: boolean;
  mod_whisper_target_user_ids?: number[];
  mod_whisper_targets?: WhisperTargetUser[];
  mod_whisper_target_group_ids?: number[];
  mod_whisper_target_groups?: WhisperTargetGroup[];
  mod_whisper_target_badge_ids?: number[];
  mod_whisper_target_badges?: WhisperTargetBadge[];
  mod_whisper_is_staff_only?: boolean;
  mod_whisper_admins_only?: boolean;
  mod_whisper_author_is_staff?: boolean;
}

// The whisper state the composer carries while a whisper is armed.
export interface WhisperComposerFields {
  modWhisperArmed?: boolean;
  modWhisperTargetUserIds?: number[] | null;
  modWhisperTargetUsernames?: string[] | null;
  modWhisperTargets?: WhisperTargetUser[] | null;
  modWhisperTargetGroupIds?: number[] | null;
  modWhisperTargetGroupNames?: string[] | null;
  modWhisperTargetGroups?: WhisperTargetGroup[] | null;
  modWhisperTargetBadgeIds?: number[] | null;
  modWhisperTargetBadges?: WhisperTargetBadge[] | null;
}

interface ReplyAudiencePost {
  user_id?: number;
  username?: string;
  avatar_template?: string;
  mod_whisper_targets?: unknown;
}

export function computeReplyAudience(
  post: ReplyAudiencePost | null | undefined,
  currentUserId: number | null | undefined
): WhisperTargetUser[] {
  if (!post || !currentUserId) {
    return [];
  }
  const byId = new Map<number, WhisperTargetUser>();
  const add = (
    id: number | undefined,
    username: string | undefined,
    avatarTemplate: string | undefined
  ) => {
    if (!id || id === currentUserId) {
      return;
    }
    if (!byId.has(id)) {
      byId.set(id, { id, username, avatar_template: avatarTemplate });
    }
  };
  add(post.user_id, post.username, post.avatar_template);
  const targets = Array.isArray(post.mod_whisper_targets)
    ? post.mod_whisper_targets
    : [];
  targets.forEach((t: Partial<WhisperTargetUser> | null) => {
    if (t && typeof t === "object") {
      add(t.id, t.username, t.avatar_template);
    }
  });
  return [...byId.values()];
}
