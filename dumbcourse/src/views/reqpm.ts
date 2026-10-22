// REQ-PM in Dumbcourse: ask someone for their contact details, answer
// requests, send yours, and call or text people with one press — which is
// exactly what a flip phone is good at. Uses the same JSON API as the full
// site (/jtech-reqpm/*); the server does every check.

import { del, errorMessage, get, post, put } from "../api.ts";
import { go } from "../app.ts";
import { settings } from "../config.ts";
import { emojiImg } from "../content/emoji.ts";
import { $$, byId } from "../dom.ts";
import { longDate, timeAgo } from "../format.ts";
import { html, safeUrl, type SafeHtml } from "../html.ts";
import { focusContent } from "../nav.ts";
import { href, type RouteContext } from "../router.ts";
import { updateCounts } from "../session.ts";
import { avatar, userPath } from "../site.ts";
import { icon } from "../ui/icons.ts";
import {
  actionSheet,
  confirmDialog,
  promptDialog,
  toast,
  type SheetItem,
} from "../ui/layers.ts";
import { useScreen } from "./common.ts";

interface Method {
  id: number;
  kind: string;
  label?: string | null;
  emoji?: string | null;
  value: string;
  note?: string | null;
  share_by_default?: boolean;
  unreadable?: boolean;
}

interface Person {
  id: number;
  username: string;
  name?: string | null;
  avatar_template: string;
}

interface Relationship {
  user: Person;
  their_methods: Method[];
  my_methods: Method[];
  my_shared_method_ids: number[];
  incoming_request: {
    id: number;
    wanted_kinds: string[];
    created_at: string;
  } | null;
  outgoing_request: {
    id: number;
    state: string;
    wanted_kinds: string[];
    created_at: string;
    can_cancel: boolean;
  } | null;
  can_request: boolean;
  request_blocked: string | null;
  retry_at: string | null;
  can_share: boolean;
  share_blocked: string | null;
}

interface Inbox {
  received: Array<{ user: Person; methods: Method[]; shared_at: string }>;
  sent: Array<{ user: Person; method_ids: number[]; shared_at: string }>;
  incoming: Array<{
    id: number;
    user: Person;
    wanted_kinds: string[];
    created_at: string;
  }>;
  outgoing: Array<{
    id: number;
    user: Person;
    wanted_kinds: string[];
    state: string;
    created_at: string;
    can_cancel: boolean;
  }>;
}

const KIND_NAMES: Record<string, string> = {
  phone: "Phone",
  sms: "Text message",
  whatsapp: "WhatsApp",
  email: "Email",
  website: "Website",
  telegram: "Telegram",
  signal: "Signal",
  discord: "Discord",
  custom: "Something else",
};
const KIND_ICONS: Record<string, string> = {
  phone: "phone",
  sms: "sms",
  whatsapp: "whatsapp",
  email: "mail",
  website: "globe",
  telegram: "send",
  signal: "chat",
  discord: "chat",
  custom: "smile",
};
const KIND_ORDER = [
  "phone",
  "sms",
  "whatsapp",
  "email",
  "website",
  "telegram",
  "signal",
  "discord",
  "custom",
];

function kindName(m: { kind: string; label?: string | null }): string {
  return m.kind === "custom" && m.label
    ? m.label
    : KIND_NAMES[m.kind] || m.kind;
}

function kindIcon(m: { kind: string; emoji?: string | null }): SafeHtml {
  if (m.kind === "custom" && m.emoji) return emojiImg(m.emoji, "emoji kind");
  return icon(KIND_ICONS[m.kind] || "smile");
}

// ── One-press actions (mirrors lib/reqpm-kinds.js) ────────────────────

function digits(v: string): string {
  return (v || "").replace(/[^\d]/g, "");
}

export function internationalDigits(
  value: string,
  defaultCode: string
): string | null {
  const rawValue = (value || "").replace(/^\s+|\s+$/g, "");
  const d = digits(rawValue);
  if (rawValue.charAt(0) === "+") return d;
  if (rawValue.slice(0, 2) === "00") return d.slice(2);
  const code = String(defaultCode || "").replace(/\D/g, "");
  if (!code || d.charAt(0) === "0") return null;
  if (d.length === 10) return code + d;
  if (d.indexOf(code) === 0 && d.length === 10 + code.length) return d;
  return null;
}

function looksLikePhone(v: string): boolean {
  return /^\+?[\d ().-]+$/.test(v || "") && digits(v).length >= 5;
}

export function actionFor(
  m: Method,
  defaultCode = settings.reqpmCountryCode
): { href: string; label: string } | null {
  const value = (m.value || "").replace(/^\s+|\s+$/g, "");
  if (!value) return null;
  const dial = () => {
    const intl = internationalDigits(value, defaultCode);
    return intl ? "+" + intl : digits(value);
  };
  switch (m.kind) {
    case "phone":
      return { href: "tel:" + dial(), label: "Call" };
    case "sms":
      return { href: "sms:" + dial(), label: "Text" };
    case "whatsapp": {
      const intl = looksLikePhone(value)
        ? internationalDigits(value, defaultCode)
        : null;
      return intl && intl.length >= 8
        ? { href: "https://wa.me/" + intl, label: "WhatsApp" }
        : null;
    }
    case "email":
      return /^[^\s@<>"?&#%]+@[^\s@<>"?&#%]+$/.test(value)
        ? { href: "mailto:" + value, label: "Email" }
        : null;
    case "website":
    case "custom":
      return /^https?:\/\/[^\s]+$/i.test(value)
        ? { href: value, label: "Open" }
        : null;
    case "telegram": {
      if (looksLikePhone(value)) return null;
      const handle = value.replace(/^@/, "");
      return /^[A-Za-z0-9_]{4,32}$/.test(handle)
        ? { href: "https://t.me/" + handle, label: "Telegram" }
        : null;
    }
    case "signal": {
      const intl = looksLikePhone(value)
        ? internationalDigits(value, defaultCode)
        : null;
      return intl
        ? { href: "https://signal.me/#p/+" + intl, label: "Signal" }
        : null;
    }
    default:
      return null;
  }
}

function methodRow(m: Method, key: string): SafeHtml {
  const a = actionFor(m);
  const external = a && /^https?:/.test(a.href);
  return html`<li class="row method" data-key="${key}">
    <span class="row-icon">${kindIcon(m)}</span>
    <div class="row-main">
      <div class="row-meta">${kindName(m)}</div>
      <div class="row-title method-value">${m.value}</div>
      ${m.note ? html`<div class="row-meta">${m.note}</div>` : ""}
    </div>
    ${a
      ? html`<a
          class="btn small primary"
          href="${safeUrl(a.href)}"
          ${external ? html` target="_blank" rel="noopener noreferrer"` : ""}
          data-key="${key}-go"
          >${a.label}</a
        >`
      : html`<button
          type="button"
          class="btn small"
          data-act="copy-value"
          data-value="${m.value}"
          data-key="${key}-copy"
        >
          Copy
        </button>`}
  </li>`;
}

const BLOCKED: Record<string, string> = {
  self: "That's you.",
  unavailable: "can't be asked for contact details right now.",
  pending: "You already asked — it's up to them.",
  cooldown: "You asked recently.",
};

function copyValue(value: string): void {
  const ta = document.createElement("textarea");
  ta.value = value;
  document.body.appendChild(ta);
  ta.select();
  let ok = false;
  try {
    ok = document.execCommand("copy");
  } catch {
    ok = false;
  }
  document.body.removeChild(ta);
  if (ok) toast("Copied.", "success");
  else void promptDialog("Copy this", { value, ok: "Done" });
}

// ── Hub ───────────────────────────────────────────────────────────────

const TABS = [
  { key: "requests", label: "Requests" },
  { key: "contacts", label: "Contacts" },
  { key: "card", label: "My card" },
  { key: "shared", label: "Shared with" },
];

export function contactsRoute(ctx: RouteContext): Promise<void> {
  const s = useScreen();
  const tab = TABS.filter((t) => t.key === ctx.query.tab)[0] || TABS[0];
  s.title("Contact requests", { back: true, sub: "REQ-PM" });
  s.render(
    html`<nav class="tabs" data-tabs data-row>
        ${TABS.map(
          (t) =>
            html`<a
              class="tab${t.key === tab.key ? " on" : ""}"
              href="${href("/contacts?tab=" + t.key)}"
              data-tab="${t.key}"
              >${t.label}</a
            >`
        )}
      </nav>
      <div id="reqpmBody">
        <div class="state state-loading">
          <span class="spinner"></span>Loading…
        </div>
      </div>`
  );
  s.act("copy-value", (el) => copyValue(el.getAttribute("data-value") || ""));

  if (tab.key === "card") return renderCard(s, ctx);

  return get<Inbox>("/jtech-reqpm/inbox.json").then(
    (d) => {
      const box = byId("reqpmBody");
      if (!box || !s.alive()) return;
      let body: SafeHtml;
      if (tab.key === "requests") {
        updateCounts({ reqpm_incoming_count: d.incoming.length });
        body = html`<h2 class="section-title">Waiting for your answer</h2>
          ${d.incoming.length
            ? html`<ul class="rows">
                ${d.incoming.map(
                  (r) =>
                    html`<li>
                      <a
                        class="row"
                        href="${href(
                          "/contacts/u/" + encodeURIComponent(r.user.username)
                        )}"
                        data-key="in${r.id}"
                      >
                        ${avatar(r.user.avatar_template, 28)}
                        <div class="row-main">
                          <div class="row-title">
                            <b>${r.user.username}</b> wants your contact details
                          </div>
                          <div class="row-meta">
                            ${r.wanted_kinds.length
                              ? html`<span
                                  >Asked for:
                                  ${r.wanted_kinds
                                    .map((k) => KIND_NAMES[k] || k)
                                    .join(", ")}</span
                                >`
                              : ""}<span>${timeAgo(r.created_at)}</span>
                          </div>
                        </div>
                        <span class="btn small primary">Answer</span></a
                      >
                    </li>`
                )}
              </ul>`
            : html`<p class="hint pad">No one is waiting for you.</p>`}
          <h2 class="section-title">Your requests</h2>
          ${d.outgoing.length
            ? html`<ul class="rows">
                ${d.outgoing.map(
                  (r) =>
                    html`<li>
                      <a
                        class="row"
                        href="${href(
                          "/contacts/u/" + encodeURIComponent(r.user.username)
                        )}"
                        data-key="out${r.id}"
                      >
                        ${avatar(r.user.avatar_template, 28)}
                        <div class="row-main">
                          <div class="row-title">${r.user.username}</div>
                          <div class="row-meta">
                            <span class="pill ${r.state}"
                              >${r.state === "answered"
                                ? "Answered"
                                : r.state === "expired"
                                  ? "Expired"
                                  : "Waiting"}</span
                            ><span>${timeAgo(r.created_at)}</span>
                          </div>
                        </div></a
                      >
                    </li>`
                )}
              </ul>`
            : html`<p class="hint pad">You haven't asked anyone yet.</p>`}`;
      } else if (tab.key === "contacts") {
        body = d.received.length
          ? html`${d.received.map(
              (c) =>
                html`<section class="contact-card">
                  <a
                    class="row contact-head"
                    href="${href(
                      "/contacts/u/" + encodeURIComponent(c.user.username)
                    )}"
                    data-key="c-${c.user.username}"
                    >${avatar(c.user.avatar_template, 28)}
                    <div class="row-main">
                      <div class="row-title">
                        ${c.user.name || c.user.username}
                      </div>
                      <div class="row-meta">
                        @${c.user.username} · shared ${timeAgo(c.shared_at)}
                      </div>
                    </div></a
                  >
                  <ul class="rows">
                    ${c.methods.map((m) => methodRow(m, `m${m.id}`))}
                  </ul>
                </section>`
            )}`
          : html`<div class="state state-empty">
              ${icon("phone")}
              <p>No one has sent you their details yet.</p>
              <p class="hint">Ask from someone's profile.</p>
            </div>`;
      } else {
        body = d.sent.length
          ? html`<ul class="rows">
              ${d.sent.map(
                (x) =>
                  html`<li>
                    <a
                      class="row"
                      href="${href(
                        "/contacts/u/" + encodeURIComponent(x.user.username)
                      )}"
                      data-key="s-${x.user.username}"
                      >${avatar(x.user.avatar_template, 28)}
                      <div class="row-main">
                        <div class="row-title">${x.user.username}</div>
                        <div class="row-meta">
                          ${x.method_ids.length} shared ·
                          ${timeAgo(x.shared_at)}
                        </div>
                      </div>
                      <span class="btn small">Change</span></a
                    >
                  </li>`
              )}
            </ul>`
          : html`<div class="state state-empty">
              ${icon("users")}
              <p>You haven't sent your details to anyone yet.</p>
            </div>`;
      }
      box.innerHTML = body.value;
      if (!ctx.restore) focusContent(".row");
    },
    (e: unknown) =>
      s.error(errorMessage(e), () =>
        go(ctx.path + location.search, { replace: true })
      )
  );
}

// ── My card ───────────────────────────────────────────────────────────

function renderCard(
  s: ReturnType<typeof useScreen>,
  ctx: RouteContext
): Promise<void> {
  return get<{
    methods: Method[];
    allow_requests: boolean;
    max_methods: number;
  }>("/jtech-reqpm/card.json").then(
    (card) => {
      const box = byId("reqpmBody");
      if (!box || !s.alive()) return;
      box.innerHTML = html`<ul class="rows">
          ${card.methods.map(
            (m) =>
              html`<li>
                <button
                  type="button"
                  class="row"
                  data-act="edit-method"
                  data-id="${m.id}"
                  data-key="me${m.id}"
                >
                  <span class="row-icon">${kindIcon(m)}</span>
                  <div class="row-main">
                    <div class="row-meta">
                      ${kindName(m)}${m.share_by_default
                        ? " · sent by default"
                        : ""}
                    </div>
                    <div class="row-title method-value">
                      ${m.unreadable
                        ? "Unreadable — edit and enter it again"
                        : m.value}
                    </div>
                  </div>
                </button>
              </li>`
          )}
        </ul>
        ${card.methods.length < card.max_methods
          ? html`<div class="pad">
              <button
                type="button"
                class="btn primary block"
                data-act="add-method"
                data-key="add"
              >
                ${icon("plus")}Add a way to reach you
              </button>
            </div>`
          : html`<p class="hint pad">Limit of ${card.max_methods} reached.</p>`}
        <ul class="rows">
          <li>
            <button
              type="button"
              class="row setting"
              data-act="toggle-requests"
              data-key="allow"
              role="switch"
              aria-checked="${card.allow_requests ? "true" : "false"}"
            >
              <span class="row-icon">${icon("bell")}</span>
              <div class="row-main">
                <div class="row-title">Let members request my details</div>
              </div>
              <span
                class="switch${card.allow_requests ? " on" : ""}"
                aria-hidden="true"
                ><span></span
              ></span>
            </button>
          </li>
        </ul>`.value;

      const again = () => go("/contacts?tab=card", { replace: true });
      s.act("toggle-requests", () =>
        put("/jtech-reqpm/card/preferences.json", {
          allow_requests: !card.allow_requests,
        }).then(again, (e: unknown) => toast(errorMessage(e), "error"))
      );
      s.act("add-method", () => {
        actionSheet(
          "How can people reach you?",
          KIND_ORDER.map((k) => ({
            label: KIND_NAMES[k],
            icon: KIND_ICONS[k],
            run: () => editMethod(null, k, again),
          }))
        );
      });
      s.act("edit-method", (el) => {
        const m = card.methods.filter(
          (x) => String(x.id) === el.getAttribute("data-id")
        )[0];
        if (!m) return;
        actionSheet(kindName(m), [
          {
            label: "Edit",
            icon: "edit",
            run: () => editMethod(m, m.kind, again),
          },
          {
            label: m.share_by_default
              ? "Don't tick by default"
              : "Tick by default when sending",
            icon: "check",
            run: () =>
              put(`/jtech-reqpm/card/methods/${m.id}.json`, {
                reqpm_contact: { share_by_default: !m.share_by_default },
              }).then(again, (e: unknown) => toast(errorMessage(e), "error")),
          },
          {
            label: "Remove",
            icon: "trash",
            danger: true,
            run: () =>
              confirmDialog(
                `Remove ${kindName(m)}? Anyone you sent it to will lose it too.`,
                { ok: "Remove", danger: true }
              ).then((ok) => {
                if (ok)
                  del(`/jtech-reqpm/card/methods/${m.id}.json`).then(
                    again,
                    (e: unknown) => toast(errorMessage(e), "error")
                  );
              }),
          },
        ]);
      });
      if (!ctx.restore) focusContent(".row, [data-act=add-method]");
    },
    (e: unknown) => s.error(errorMessage(e))
  );
}

function editMethod(m: Method | null, kind: string, done: () => void): void {
  const tel = kind === "phone" || kind === "sms";
  const askLabel = (): Promise<string | null> =>
    kind === "custom"
      ? promptDialog("What is it called?", {
          title: "Something else",
          value: (m && m.label) || "",
          placeholder: "e.g. Office",
        })
      : Promise.resolve("");
  askLabel().then((label) => {
    if (label === null) return;
    promptDialog(KIND_NAMES[kind] || "Value", {
      title: m ? "Edit" : "Add " + (KIND_NAMES[kind] || kind),
      value: m ? m.value : "",
      type:
        kind === "email"
          ? "email"
          : tel
            ? "tel"
            : kind === "website"
              ? "url"
              : "text",
      hint: tel
        ? `Saved as +${settings.reqpmCountryCode} unless you add a country code.`
        : "",
      ok: "Save",
    }).then((value) => {
      if (value === null) return;
      const body = {
        reqpm_contact: {
          kind,
          value,
          label: kind === "custom" ? label : undefined,
        },
      };
      const req = m
        ? put(`/jtech-reqpm/card/methods/${m.id}.json`, body)
        : post("/jtech-reqpm/card/methods.json", body);
      req.then(
        () => {
          toast("Saved.", "success");
          done();
        },
        (e: unknown) => toast(errorMessage(e), "error")
      );
    });
  });
}

// ── One person ────────────────────────────────────────────────────────

export function contactUserRoute(ctx: RouteContext): Promise<void> {
  const s = useScreen();
  const username = ctx.params.username || "";
  s.title(username, { back: true, sub: "Contact details" });
  s.loading();
  s.act("copy-value", (el) => copyValue(el.getAttribute("data-value") || ""));
  return get<Relationship>(
    `/jtech-reqpm/users/${encodeURIComponent(username)}.json`
  ).then(
    (r) => {
      if (!s.alive()) return;
      const u = r.user;
      const again = () => go(ctx.path, { replace: true });
      const theirs = r.their_methods.length
        ? html`<ul class="rows">
            ${r.their_methods.map((m) => methodRow(m, `t${m.id}`))}
          </ul>`
        : html`<p class="hint pad">
            ${u.username} hasn't sent you any contact details yet.
          </p>`;

      let ask = html``;
      if (r.can_request) {
        ask = html`<div class="pad btn-row" data-row>
          <button
            type="button"
            class="btn primary"
            data-act="ask"
            data-key="ask"
          >
            ${icon("phone")}Ask for their details</button
          ><button type="button" class="btn" data-act="ask-specific">
            Ask for…
          </button>
        </div>`;
      } else if (r.outgoing_request && r.outgoing_request.state === "waiting") {
        ask = html`<p class="notice">
            Requested ${longDate(r.outgoing_request.created_at)}
          </p>
          ${r.outgoing_request.can_cancel
            ? html`<div class="pad">
                <button type="button" class="btn" data-act="withdraw">
                  Withdraw request
                </button>
              </div>`
            : ""}`;
      } else if (r.request_blocked === "cooldown" && r.retry_at) {
        ask = html`<p class="hint pad">
          You can ask again on ${longDate(r.retry_at)}.
        </p>`;
      } else if (r.request_blocked && r.request_blocked !== "self") {
        ask = html`<p class="hint pad">
          ${u.username} ${BLOCKED[r.request_blocked] || BLOCKED.unavailable}
        </p>`;
      }

      const incoming = r.incoming_request
        ? html`<div class="notice ok">
            ${icon("bell")} <b>${u.username}</b> asked for your contact
            details${r.incoming_request.wanted_kinds.length
              ? html` — they'd like:
                ${r.incoming_request.wanted_kinds
                  .map((k) => KIND_NAMES[k] || k)
                  .join(", ")}`
              : ""}.
            Tick what you're happy to send, or say no thanks — they won't be
            told.
          </div>`
        : html``;

      const wanted = r.incoming_request ? r.incoming_request.wanted_kinds : [];
      const shareList = r.my_methods.length
        ? html`<ul class="rows checks">
            ${r.my_methods.map((m) => {
              const on =
                r.my_shared_method_ids.indexOf(m.id) >= 0 ||
                (!r.my_shared_method_ids.length &&
                  (m.share_by_default || wanted.indexOf(m.kind) >= 0));
              return html`<li>
                <label class="check row"
                  ><input
                    type="checkbox"
                    data-method="${m.id}"
                    ${on ? html` checked` : ""}${m.unreadable
                      ? html` disabled`
                      : ""}
                  />${kindIcon(m)}<span class="row-main"
                    ><span class="row-meta">${kindName(m)}</span
                    ><br />${m.value}</span
                  ></label
                >
              </li>`;
            })}
          </ul>`
        : html`<div class="pad">
            <a class="btn block" href="${href("/contacts?tab=card")}"
              >${icon("plus")}Add a way to reach you</a
            >
          </div>`;

      const shareActions =
        r.can_share && r.my_methods.length
          ? html`<div class="pad btn-row" data-row>
              <button
                type="button"
                class="btn primary"
                data-act="send"
                data-key="send"
              >
                ${icon("send")}${r.my_shared_method_ids.length
                  ? "Update what they see"
                  : "Send selected"}
              </button>
              ${r.incoming_request
                ? html`<button type="button" class="btn" data-act="no-thanks">
                    No thanks
                  </button>`
                : ""}
              ${r.my_shared_method_ids.length
                ? html`<button type="button" class="btn ghost" data-act="stop">
                    Stop sharing
                  </button>`
                : ""}
            </div>`
          : r.share_blocked && r.share_blocked !== "self"
            ? html`<p class="hint pad">
                You can't send contact details to ${u.username} right now.
              </p>`
            : html``;

      s.render(
        html`<a
            class="row contact-head"
            href="${href(userPath(u.username))}"
            data-key="who"
            >${avatar(u.avatar_template, 36)}
            <div class="row-main">
              <div class="row-title">${u.name || u.username}</div>
              <div class="row-meta">@${u.username} · profile</div>
            </div></a
          >
          ${incoming}
          <h2 class="section-title">Their details</h2>
          ${theirs}
          ${r.their_methods.length
            ? html`<div class="pad">
                <button type="button" class="btn ghost small" data-act="forget">
                  Remove from my contacts
                </button>
              </div>`
            : ""}
          ${ask}
          <h2 class="section-title">Your details</h2>
          ${shareList} ${shareActions}`
      );

      const request = (kinds: string[]) =>
        post("/jtech-reqpm/requests.json", {
          username: u.username,
          wanted_kinds: kinds,
        }).then(
          () => {
            toast("Request sent.", "success");
            again();
          },
          (e: unknown) => toast(errorMessage(e), "error")
        );
      s.act("ask", () => void request([]));
      s.act("ask-specific", () => {
        const items: SheetItem[] = KIND_ORDER.filter((k) => k !== "custom").map(
          (k) => ({
            label: KIND_NAMES[k],
            icon: KIND_ICONS[k],
            run: () => void request([k]),
          })
        );
        actionSheet("What would you like?", items, {
          subtitle: "They choose what to send.",
        });
      });
      s.act("withdraw", () => {
        if (!r.outgoing_request) return;
        del(`/jtech-reqpm/requests/${r.outgoing_request.id}.json`).then(
          again,
          (e: unknown) => toast(errorMessage(e), "error")
        );
      });
      s.act("send", () => {
        const ids = $$<HTMLInputElement>("input[data-method]")
          .filter((c) => c.checked)
          .map((c) => parseInt(c.getAttribute("data-method") || "0", 10));
        if (!ids.length) {
          toast("Pick at least one.", "error");
          return;
        }
        post("/jtech-reqpm/shares.json", {
          username: u.username,
          method_ids: ids,
        }).then(
          () => {
            toast("Sent.", "success");
            again();
          },
          (e: unknown) => toast(errorMessage(e), "error")
        );
      });
      s.act("no-thanks", () => {
        if (!r.incoming_request) return;
        post(
          `/jtech-reqpm/requests/${r.incoming_request.id}/decline.json`
        ).then(
          () => {
            toast("Request dismissed.", "success");
            go("/contacts", { replace: true });
          },
          (e: unknown) => toast(errorMessage(e), "error")
        );
      });
      s.act("stop", () =>
        confirmDialog(`Stop sharing your details with ${u.username}?`, {
          ok: "Stop sharing",
          danger: true,
        }).then((ok) => {
          if (ok)
            del(
              `/jtech-reqpm/shares/${encodeURIComponent(u.username)}.json`
            ).then(again, (e: unknown) => toast(errorMessage(e), "error"));
        })
      );
      s.act("forget", () =>
        confirmDialog(
          `Remove ${u.username}'s details? You'd have to ask again.`,
          { ok: "Remove", danger: true }
        ).then((ok) => {
          if (ok)
            del(
              `/jtech-reqpm/received/${encodeURIComponent(u.username)}.json`
            ).then(again, (e: unknown) => toast(errorMessage(e), "error"));
        })
      );
      if (!ctx.restore)
        focusContent(
          r.incoming_request
            ? "input[data-method]"
            : ".method a, .method button, [data-act=ask]"
        );
    },
    (e: unknown) =>
      s.error(errorMessage(e), () => go(ctx.path, { replace: true }))
  );
}
