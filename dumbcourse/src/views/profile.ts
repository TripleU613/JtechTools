// A person's profile: who they are, their stats and recent activity, and
// ways to reach them (REQ-PM contact details, or a message if allowed).

import { errorMessage, get } from "../api.ts";
import { go } from "../app.ts";
import { invalidate, swr } from "../cache.ts";
import { processCooked } from "../content/cooked.ts";
import { emojify, emojiImg } from "../content/emoji.ts";
import { byId } from "../dom.ts";
import { count, longDate, timeAgo, truncate } from "../format.ts";
import { html, safeUrl, type SafeHtml } from "../html.ts";
import { focusContent } from "../nav.ts";
import { href, type RouteContext } from "../router.ts";
import { isMe, user } from "../session.ts";
import { avatar, categoryBadge, topicPath } from "../site.ts";
import { icon } from "../ui/icons.ts";
import { actionSheet, toast } from "../ui/layers.ts";
import { decodeEntities } from "../ui/topic-row.ts";
import { useScreen } from "./common.ts";
import { openComposer } from "./composer.ts";
import { canModerateUser, userStaffMenu } from "./user-staff.ts";

interface UserJson {
  id: number;
  username: string;
  name?: string | null;
  avatar_template: string;
  title?: string | null;
  bio_cooked?: string | null;
  location?: string | null;
  website?: string | null;
  website_name?: string | null;
  created_at: string;
  last_posted_at?: string | null;
  last_seen_at?: string | null;
  post_count?: number;
  topic_count?: number;
  trust_level?: number;
  admin?: boolean;
  moderator?: boolean;
  badge_count?: number;
  can_send_private_message_to_user?: boolean;
  suspended_till?: string | null;
  status?: { emoji?: string; description?: string } | null;
  user_fields?: Record<string, string | string[]>;
  reqpm_available?: boolean;
}

interface UserAction {
  action_type: number;
  created_at: string;
  excerpt?: string;
  title?: string;
  topic_id: number;
  post_number: number;
  slug: string;
  category_id?: number;
  username: string;
  target_username?: string;
  acting_username?: string;
  acting_avatar_template?: string;
}

const TABS = [
  { key: "activity", label: "Activity", filter: "4,5" },
  { key: "topics", label: "Topics", filter: "4" },
  { key: "replies", label: "Replies", filter: "5" },
  { key: "likes", label: "Likes", filter: "1" },
];

const LEVELS = ["New", "Basic", "Member", "Regular", "Leader"];

export function profileRoute(ctx: RouteContext): Promise<void> {
  const s = useScreen();
  let username = ctx.params.username || "";
  if (username === "me" && user) username = user.username;
  const tab = TABS.filter((t) => t.key === ctx.query.tab)[0] || TABS[0];
  s.title("@" + username, { back: true });
  s.loading();

  let first = true;
  return swr<{ user: UserJson }>(
    `/u/${encodeURIComponent(username)}.json`,
    (d) => {
      const u = d.user;
      if (!u || !s.alive()) return;
      paint(s, ctx, u, tab);
      if (first) loadActivity(s, u, tab);
      if (first && !ctx.restore) focusContent(".profile-actions .btn, .row");
      first = false;
    }
  ).catch((e: unknown) =>
    s.error(errorMessage(e), () =>
      go(ctx.path + location.search, { replace: true })
    )
  );
}

function paint(
  s: ReturnType<typeof useScreen>,
  ctx: RouteContext,
  u: UserJson,
  tab: (typeof TABS)[number]
): void {
  const me = isMe(u.username);
  const role = u.admin
    ? "Admin"
    : u.moderator
      ? "Moderator"
      : LEVELS[u.trust_level || 0] || "";
  s.title(u.name || u.username, { back: true, sub: "@" + u.username });

  const facts: SafeHtml[] = [];
  if (u.location) facts.push(html`<li>${icon("home")}${u.location}</li>`);
  if (u.website) {
    const url = /^https?:\/\//i.test(u.website)
      ? u.website
      : "http://" + u.website;
    facts.push(
      html`<li>
        ${icon("globe")}<a
          href="${safeUrl(url)}"
          target="_blank"
          rel="noopener noreferrer nofollow"
          >${u.website_name || u.website}</a
        >
      </li>`
    );
  }
  facts.push(html`<li>${icon("clock")}Joined ${longDate(u.created_at)}</li>`);
  if (u.last_seen_at)
    facts.push(
      html`<li>${icon("eye")}Seen ${timeAgo(u.last_seen_at)} ago</li>`
    );

  const actions: SafeHtml[] = [];
  const reqpmOn = user && user.reqpm_available && u.reqpm_available !== false;
  if (!me && reqpmOn) {
    actions.push(
      html`<a
        class="btn primary"
        href="${href("/contacts/u/" + encodeURIComponent(u.username))}"
        data-key="reqpm"
        >${icon("phone")}Contact details</a
      >`
    );
  }
  if (
    !me &&
    u.can_send_private_message_to_user &&
    user &&
    user.can_send_private_messages
  ) {
    actions.push(
      html`<button
        type="button"
        class="btn"
        data-act="message-user"
        data-key="message"
      >
        ${icon("mail")}Message
      </button>`
    );
  }
  if (canModerateUser(u)) {
    actions.push(
      html`<button
        type="button"
        class="btn"
        data-act="moderate-user"
        data-key="moderate"
      >
        ${icon("shield")}Moderate
      </button>`
    );
  }
  if (me) {
    actions.push(
      html`<a class="btn" href="${href("/preferences")}" data-key="prefs"
        >${icon("gear")}Preferences</a
      >`
    );
    actions.push(
      html`<a
        class="btn"
        href="${href("/preferences/profile")}"
        data-key="edit-profile"
        >${icon("edit")}Edit profile</a
      >`
    );
  }

  const bio = u.bio_cooked ? processCooked(u.bio_cooked).html : null;

  s.render(
    html`<section class="profile">
        <div class="profile-card" tabindex="0" data-key="card">
          ${avatar(u.avatar_template, 64, "avatar big")}
          <div class="profile-who">
            <h1>
              ${u.name || u.username}${u.status && u.status.emoji
                ? emojiImg(u.status.emoji, "emoji status")
                : ""}
            </h1>
            <div class="muted">
              @${u.username}${role ? html` · ${role}` : ""}
            </div>
            ${u.title ? html`<div class="profile-title">${u.title}</div>` : ""}
            ${u.status && u.status.description
              ? html`<div class="profile-status">
                  ${emojify(u.status.description)}
                </div>`
              : ""}
            ${u.suspended_till
              ? html`<div class="notice error small">
                  Suspended until ${longDate(u.suspended_till)}
                </div>`
              : ""}
          </div>
        </div>
        ${actions.length
          ? html`<div class="profile-actions btn-row" data-row>${actions}</div>`
          : ""}
        <ul class="profile-stats" data-row>
          <li tabindex="0"><b>${count(u.post_count)}</b><span>posts</span></li>
          <li tabindex="0">
            <b>${count(u.topic_count)}</b><span>topics</span>
          </li>
          <li tabindex="0">
            <b>${count(u.badge_count)}</b><span>badges</span>
          </li>
        </ul>
        ${bio
          ? html`<div class="profile-bio cooked" tabindex="0">${bio}</div>`
          : ""}
        <ul class="profile-facts">
          ${facts}
        </ul>
      </section>
      <nav class="tabs" data-tabs data-row>
        ${TABS.map(
          (t) =>
            html`<a
              class="tab${t.key === tab.key ? " on" : ""}"
              href="${href(
                ctx.path + (t.key === "activity" ? "" : "?tab=" + t.key)
              )}"
              data-tab="${t.key}"
              >${t.label}</a
            >`
        )}
      </nav>
      <ul id="activity" class="rows">
        <li class="state state-loading">
          <span class="spinner"></span>Loading…
        </li>
      </ul>`
  );

  s.act("message-user", () =>
    openComposer({ kind: "message", to: u.username })
  );
  s.act("moderate-user", () =>
    userStaffMenu(u, {
      reload: (message) => {
        toast(message, "success");
        invalidate("/u/" + encodeURIComponent(u.username));
        go(ctx.path + location.search, { replace: true });
      },
      gone: (message) => {
        toast(message, "success");
        invalidate();
        go("/", { replace: true });
      },
      renamed: (name, message) => {
        toast(message, "success");
        invalidate("/u/");
        go("/u/" + encodeURIComponent(name), { replace: true });
      },
    })
  );
  if (!me && reqpmOn)
    s.softkeys({
      right: {
        label: "Contact",
        run: () => go("/contacts/u/" + encodeURIComponent(u.username)),
      },
    });
  else if (me)
    s.softkeys({
      right: {
        label: "Options",
        run: () =>
          actionSheet("You", [
            { label: "Preferences", icon: "gear", href: href("/preferences") },
            {
              label: "Edit profile",
              icon: "edit",
              href: href("/preferences/profile"),
            },
            { label: "Drafts", icon: "draft", href: href("/drafts") },
            { label: "Bookmarks", icon: "bookmark", href: href("/bookmarks") },
            {
              label: "Log out",
              icon: "logout",
              danger: true,
              run: () => go("/logout"),
            },
          ]),
      },
    });
}

function loadActivity(
  s: ReturnType<typeof useScreen>,
  u: UserJson,
  tab: (typeof TABS)[number]
): void {
  get<{ user_actions?: UserAction[] }>(
    `/user_actions.json?username=${encodeURIComponent(u.username)}&filter=${tab.filter}&offset=0`
  ).then(
    (d) => {
      const box = byId("activity");
      if (!box || !s.alive()) return;
      const items = (d.user_actions || []).slice(0, 30);
      box.innerHTML = items.length
        ? html`${items.map(
            (a, i) =>
              html`<li>
                <a
                  class="row"
                  href="${href(topicPath(a.topic_id, a.slug, a.post_number))}"
                  data-key="a${i}"
                >
                  <div class="row-main">
                    <div class="row-title">
                      ${emojify(decodeEntities(a.title || ""))}
                    </div>
                    ${a.excerpt
                      ? html`<div class="row-excerpt">
                          ${truncate(
                            decodeEntities(a.excerpt.replace(/<[^>]*>/g, "")),
                            140
                          )}
                        </div>`
                      : ""}
                    <div class="row-meta">
                      ${categoryBadge(a.category_id)}<span
                        >${a.action_type === 1
                          ? "liked"
                          : a.action_type === 4
                            ? "started"
                            : "replied"}</span
                      ><span>${timeAgo(a.created_at)}</span>
                    </div>
                  </div></a
                >
              </li>`
          )}`.value
        : html`<li class="state state-empty"><p>Nothing here yet.</p></li>`
            .value;
    },
    () => {
      const box = byId("activity");
      if (box)
        box.innerHTML = html`<li class="state state-empty">
          <p>Activity is private.</p>
        </li>`.value;
    }
  );
}
