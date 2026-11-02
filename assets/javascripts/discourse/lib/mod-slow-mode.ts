import { i18n } from "discourse-i18n";

// A user's own slow mode, as the current-user serializer and
// GET /discourse-mod-categories/slow-mode send it.
export interface SlowModeSummary {
  seconds: number;
  ends_at: string | null;
  next_post_at: string | null;
  waiting: boolean;
}

// A user's slow mode on their admin page.
export interface SlowModeAdminSummary {
  seconds: number;
  ends_at: string | null;
}

// "15 minutes", "1 hour 30 minutes": the server's own words for it
// (UserSlowMode.interval_words), so the note, the admin page and the user's
// message agree.
export function slowModeInterval(seconds: number): string {
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const parts: string[] = [];
  if (hours > 0) {
    parts.push(
      i18n("discourse_mod_categories.slow_mode.hours", { count: hours })
    );
  }
  if (minutes > 0) {
    parts.push(
      i18n("discourse_mod_categories.slow_mode.minutes", { count: minutes })
    );
  }
  return parts.join(" ");
}

// How long until the user may post, rounded up to a minute so it never says
// "0 minutes" while they still have to wait.
export function slowModeWait(milliseconds: number): string {
  const minutes = Math.max(1, Math.ceil(milliseconds / 60000));
  return slowModeInterval(minutes * 60);
}
