// Topic lists: Latest, New, Unread, Top, Hot — plus one category or tag.
// Left/Right switch tabs; the list keeps loading as you move down it.

import { errorMessage, get, put } from "../api.ts";
import { go } from "../app.ts";
import { invalidate, swr } from "../cache.ts";
import { settings } from "../config.ts";
import { appendHtml, byId, nearBottom } from "../dom.ts";
import { html, type SafeHtml } from "../html.ts";
import { subscribe } from "../messagebus.ts";
import { focusContent } from "../nav.ts";
import { prefs } from "../prefs.ts";
import { buildQuery, href, type RouteContext } from "../router.ts";
import {
  addCategories,
  category,
  categoryName,
  categoryPath,
} from "../site.ts";
import type { TopicListResponse } from "../types.ts";
import { icon } from "../ui/icons.ts";
import {
  actionSheet,
  confirmDialog,
  toast,
  type SheetItem,
} from "../ui/layers.ts";
import { topicRow, usersById } from "../ui/topic-row.ts";
import { renderCategories } from "./categories.ts";
import { useScreen } from "./common.ts";
import { openComposer } from "./composer.ts";
import { categoryLevelSheet } from "./levels.ts";

export const VIEWS: Array<{ key: string; label: string }> = [
  { key: "latest", label: "Latest" },
  { key: "new", label: "New" },
  { key: "unread", label: "Unread" },
  { key: "top", label: "Top" },
  { key: "hot", label: "Hot" },
  { key: "categories", label: "Categories" },
];

const TOP_PERIODS = [
  { key: "daily", label: "Today" },
  { key: "weekly", label: "This week" },
  { key: "monthly", label: "This month" },
  { key: "quarterly", label: "This quarter" },
  { key: "yearly", label: "This year" },
  { key: "all", label: "All time" },
];

export function homeView(): string {
  const v = prefs.defaultView || settings.defaultView || "latest";
  return v === "unseen" ? "unread" : v;
}

interface ListSpec {
  title: string;
  sub: string;
  view: string;
  endpoint: string;
  categoryId: number | null;
  tag: string | null;
  base: string;
}

function tabs(active: string, base: string): SafeHtml {
  return html`<nav class="tabs" data-tabs data-row aria-label="Topic lists">
    ${VIEWS.map((v) => {
      const target =
        v.key === "categories"
          ? base
            ? base + "/subcategories"
            : "/categories"
          : base + "/" + v.key;
      if (v.key === "categories" && base.indexOf("/tag/") === 0) return html``;
      return html`<a
        class="tab${v.key === active ? " on" : ""}"
        href="${href(target)}"
        data-tab="${v.key}"
        data-key="tab-${v.key}"
        ${v.key === active ? html` aria-current="page"` : ""}
        >${v.label}</a
      >`;
    })}
  </nav>`;
}

function emptyText(view: string): string {
  switch (view) {
    case "new":
      return "Nothing new.";
    case "unread":
      return "No unread topics.";
    case "hot":
      return "Nothing's hot right now.";
    case "top":
      return "No top topics for this period.";
    default:
      return "No topics here yet.";
  }
}

export function renderTopicList(
  ctx: RouteContext,
  spec: ListSpec
): Promise<void> {
  const s = useScreen();
  s.title(spec.title, { back: spec.base !== "", sub: spec.sub });
  s.compose("compose-topic", "New topic");
  const period = ctx.query.period || "weekly";
  let page = 0;
  let more = true;
  let loadingMore = false;
  let fresh = 0;
  const seen: Record<number, boolean> = {};

  const params = (p: number): string => {
    const q: Record<string, string | number | null> = { page: p || null };
    if (spec.view === "top") q.period = period;
    // With Discourse's Unified New on, New also lists unread topics; here
    // Unread has its own tab, so New asks for new topics only (ignored
    // while it's off).
    if (spec.view === "new") q.subset = "topics";
    if (settings.paginationEnabled) q.per_page = settings.topicsPerPage;
    return buildQuery(q);
  };

  const pathFor = (p: number) => spec.endpoint + params(p);

  s.render(
    html`${tabs(spec.view, spec.base)}
      <div id="freshBanner" class="fresh" hidden>
        <button type="button" class="btn small primary" data-act="show-fresh">
          ${icon("arrowUp")}<span id="freshText"></span>
        </button>
      </div>
      <ul id="topicList" class="rows topics" aria-label="${spec.title}"></ul>
      <div id="listFoot" class="list-foot"></div>`
  );

  const list = byId("topicList") as HTMLElement;
  const foot = byId("listFoot") as HTMLElement;

  function footer(state: "more" | "loading" | "end" | "none"): void {
    if (state === "loading")
      foot.innerHTML =
        '<div class="state state-loading"><span class="spinner"></span>Loading…</div>';
    else if (state === "more")
      foot.innerHTML =
        '<button type="button" class="btn block" data-act="load-more" data-key="load-more">Load more topics</button>';
    else if (state === "end")
      foot.innerHTML = '<p class="list-end">That’s everything.</p>';
    else foot.innerHTML = "";
  }

  function paint(d: TopicListResponse, replace: boolean): number {
    const topics = (d.topic_list && d.topic_list.topics) || [];
    if (d.topic_list && d.topic_list.categories)
      addCategories(d.topic_list.categories as never);
    const users = usersById(d.users);
    const rows: SafeHtml[] = [];
    for (let i = 0; i < topics.length; i++) {
      if (!replace && seen[topics[i].id]) continue;
      seen[topics[i].id] = true;
      rows.push(topicRow(topics[i], users));
    }
    if (replace) list.innerHTML = html`${rows}`.value;
    else appendHtml(list, html`${rows}`);
    more =
      !!(d.topic_list && d.topic_list.more_topics_url) && topics.length > 0;
    return topics.length;
  }

  function loadMore(): void {
    if (!s.alive() || !more || loadingMore) return;
    loadingMore = true;
    footer("loading");
    get<TopicListResponse>(pathFor(page + 1)).then(
      (d) => {
        loadingMore = false;
        if (!s.alive()) return;
        page++;
        paint(d, false);
        footer(more ? "more" : "end");
      },
      (e: unknown) => {
        loadingMore = false;
        if (!s.alive()) return;
        footer("more");
        toast(errorMessage(e), "error");
      }
    );
  }

  s.act("load-more", () => loadMore());
  s.act("show-fresh", () => {
    fresh = 0;
    invalidate(spec.endpoint);
    go(ctx.path + (location.search || ""), { replace: true });
  });
  const newTopic = () =>
    openComposer({
      kind: "topic",
      categoryId: spec.categoryId,
      tags: spec.tag ? [spec.tag] : [],
    });
  const refresh = () => {
    invalidate(spec.endpoint);
    go(ctx.path + location.search, { replace: true });
  };
  s.act("compose-topic", newTopic);

  const onScroll = () => {
    if (!settings.paginationEnabled && nearBottom(400)) loadMore();
  };
  window.addEventListener("scroll", onScroll);
  s.onLeave(() => window.removeEventListener("scroll", onScroll));
  const onEnd = () => loadMore();
  list.addEventListener("dc:end", onEnd);

  // Live: count what changed and offer to show it, rather than shuffling
  // the list under the D-pad focus.
  if (prefs.live) {
    const bump = (data: unknown) => {
      const d = data as {
        topic_id?: number;
        message_type?: string;
        payload?: { category_id?: number };
      };
      if (!s.alive() || !d || !d.topic_id) return;
      if (
        spec.categoryId &&
        d.payload &&
        d.payload.category_id &&
        d.payload.category_id !== spec.categoryId
      )
        return;
      if (spec.view === "top" || spec.view === "hot") return;
      fresh++;
      const banner = byId("freshBanner");
      const text = byId("freshText");
      if (banner && text) {
        banner.hidden = false;
        text.textContent =
          fresh === 1
            ? "1 new or updated topic"
            : fresh + " new or updated topics";
      }
    };
    const channel =
      spec.view === "new"
        ? "/new"
        : spec.view === "unread"
          ? "/unread"
          : "/latest";
    s.onLeave(subscribe(channel, bump));
  }

  const options = () => {
    const items: SheetItem[] = [
      { label: "Refresh", icon: "refresh", run: refresh },
      { label: "New topic", icon: "plus", hint: "3", run: newTopic },
    ];
    if (spec.view === "top") {
      for (let i = 0; i < TOP_PERIODS.length; i++) {
        const p = TOP_PERIODS[i];
        items.push({
          label: "Top: " + p.label,
          icon: "star",
          active: p.key === period,
          run: () =>
            go(ctx.path + buildQuery({ period: p.key }), { replace: true }),
        });
      }
    }
    if (spec.view === "new")
      items.push({ label: "Dismiss all new", icon: "check", run: dismissNew });
    if (spec.view === "unread")
      items.push({
        label: "Dismiss all unread",
        icon: "check",
        run: dismissUnread,
      });
    if (spec.categoryId) {
      items.push({
        label: "Category notifications…",
        icon: "bell",
        run: () => categoryLevelSheet(spec.categoryId as number),
      });
    }
    actionSheet(spec.title, items);
  };

  const dismissNew = () => {
    confirmDialog("Mark every new topic here as seen?", { ok: "Dismiss" }).then(
      (ok) => {
        if (!ok) return;
        // Unified New dismisses nothing unless told what (and ignores this
        // while it's off)
        const body: Record<string, unknown> = { dismiss_topics: true };
        if (spec.categoryId) body.category_id = spec.categoryId;
        if (spec.tag) body.tag_name = spec.tag;
        put("/topics/reset-new.json", body).then(
          () => {
            toast("Dismissed.", "success");
            refresh();
          },
          (e: unknown) => toast(errorMessage(e), "error")
        );
      }
    );
  };

  const dismissUnread = () => {
    confirmDialog("Mark every unread topic here as read?", {
      ok: "Dismiss",
    }).then((ok) => {
      if (!ok) return;
      const body: Record<string, unknown> = {
        filter: "unread",
        operation: { type: "dismiss_posts" },
      };
      if (spec.categoryId) body.category_id = spec.categoryId;
      put("/topics/bulk.json", body).then(
        () => {
          toast("Dismissed.", "success");
          refresh();
        },
        (e: unknown) => toast(errorMessage(e), "error")
      );
    });
  };

  s.softkeys({ right: { label: "Options", run: options } });
  s.keys({ "3": newTopic, "9": options, "5": refresh });

  let first = true;
  list.innerHTML =
    '<li class="state state-loading"><span class="spinner"></span>Loading…</li>';
  return swr<TopicListResponse>(pathFor(0), (d) => {
    if (!s.alive()) return;
    const n = paint(d, true);
    if (!n) {
      list.innerHTML = html`<li class="state state-empty">
        ${icon("check")}
        <p>${emptyText(spec.view)}</p>
      </li>`.value;
      footer("none");
    } else {
      footer(more ? "more" : "end");
    }
    if (first && !ctx.restore) focusContent(".row.topic");
    first = false;
  }).catch((e: unknown) => {
    if (!s.alive()) return;
    list.innerHTML = "";
    footer("none");
    s.error(errorMessage(e), refresh);
  });
}

// ── Routes ────────────────────────────────────────────────────────────

const ENDPOINT: Record<string, string> = {
  latest: "/latest.json",
  new: "/new.json",
  unread: "/unread.json",
  top: "/top.json",
  hot: "/hot.json",
};

export function listRoute(view: string) {
  return (ctx: RouteContext) => {
    if (view === "categories") return categoriesRedirect();
    return renderTopicList(ctx, {
      title: settings.siteTitle,
      sub: VIEWS.filter((v) => v.key === view)[0]?.label || "",
      view,
      endpoint: ENDPOINT[view] || ENDPOINT.latest,
      categoryId: null,
      tag: null,
      base: "",
    });
  };
}

function categoriesRedirect(): void {
  go("/categories", { replace: true });
}

export function homeRoute(ctx: RouteContext): Promise<void> | void {
  const v = homeView();
  if (v === "categories") {
    go("/categories", { replace: true });
    return;
  }
  return listRoute(ENDPOINT[v] ? v : "latest")(ctx);
}

export function categoryRoute(ctx: RouteContext): Promise<void> | void {
  // /c/:a/:b… — the last numeric segment is the id; an optional trailing
  // list name (latest/new/…) picks the tab.
  const parts = (ctx.params.rest || "").split("/").filter(Boolean);
  let view = "latest";
  if (parts.length && ENDPOINT[parts[parts.length - 1]])
    view = parts.pop() as string;
  // Full-site style /c/slug/5/l/latest.
  if (parts.length && parts[parts.length - 1] === "l") parts.pop();
  if (parts.length && parts[parts.length - 1] === "subcategories") {
    parts.pop();
    const id = parseInt(parts[parts.length - 1], 10);
    return renderCategories(ctx, id || null);
  }
  let id = 0;
  for (let i = parts.length - 1; i >= 0; i--) {
    if (/^\d+$/.test(parts[i])) {
      id = parseInt(parts[i], 10);
      break;
    }
  }
  const c = category(id);
  if (!c) {
    const s = useScreen();
    s.title("Category");
    s.error("That category doesn't exist or you can't see it.");
    return;
  }
  const base = categoryPath(c);
  const endpoint = "/c/" + parts.join("/") + "/l/" + view + ".json";
  return renderTopicList(ctx, {
    title: categoryName(c),
    sub: VIEWS.filter((v) => v.key === view)[0]?.label || "",
    view,
    endpoint,
    categoryId: c.id,
    tag: null,
    base,
  });
}

export function tagRoute(ctx: RouteContext): Promise<void> | void {
  const parts = (ctx.params.rest || "").split("/").filter(Boolean);
  let view = "latest";
  if (parts.length > 1 && ENDPOINT[parts[parts.length - 1]])
    view = parts.pop() as string;
  if (parts.length > 1 && parts[parts.length - 1] === "l") parts.pop();
  const tag = parts[0] || "";
  return renderTopicList(ctx, {
    title: "#" + tag,
    sub: VIEWS.filter((v) => v.key === view)[0]?.label || "",
    view,
    endpoint: "/tag/" + encodeURIComponent(tag) + "/l/" + view + ".json",
    categoryId: null,
    tag,
    base: "/tag/" + encodeURIComponent(tag),
  });
}
