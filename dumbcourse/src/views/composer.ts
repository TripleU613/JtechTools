// The composer: a full-screen panel for replies, new topics, messages and
// edits. Drafts save as you type; Back or Close keeps the draft, and asks
// first when there's writing in it. Soft keys: left closes, right sends.

import { errorMessage, get, post, put, request } from "../api.ts";
import { go } from "../app.ts";
import { invalidate } from "../cache.ts";
import { fire } from "../compat.ts";
import { settings } from "../config.ts";
import {
  allEmojiNames,
  COMMON_EMOJI,
  emojiImg,
  searchEmoji,
} from "../content/emoji.ts";
import { processCooked } from "../content/cooked.ts";
import { $, byId, debounce, setHtml } from "../dom.ts";
import {
  clearDraft,
  getDraft,
  saveDraft,
  type Draft,
  type TagRef,
} from "../drafts.ts";
import { html, raw, type SafeHtml } from "../html.ts";
import { focus } from "../nav.ts";
import { busClientId } from "../messagebus.ts";
import {
  category,
  categoryName,
  postableCategories,
  topicPath,
} from "../site.ts";
import { user } from "../session.ts";
import type { Post } from "../types.ts";
import { icon } from "../ui/icons.ts";
import {
  actionSheet,
  confirmDialog,
  openLayer,
  promptDialog,
  toast,
  type Layer,
  type SheetItem,
} from "../ui/layers.ts";
import { avatar } from "../site.ts";

// A staff reply only some can read: core's whisper (staff only), or this
// plugin's whisper to the users named (and staff).
export interface Whisper {
  core: boolean;
  userIds: number[];
  groupIds?: number[];
  badgeIds?: number[];
  label: string;
}

export type ComposerOptions =
  | {
      kind: "reply";
      whisper?: Whisper;
      topicId: number;
      topicTitle: string;
      categoryId: number | null;
      replyTo: { postNumber: number; username: string } | null;
      quote?: string;
      participants?: Array<{ username: string; avatar_template: string }>;
      onPosted?: (p: Post) => void;
    }
  | {
      kind: "topic";
      categoryId?: number | null;
      tags?: string[];
      title?: string;
      body?: string;
    }
  | {
      kind: "message";
      to?: string;
      title?: string;
      body?: string;
      // Staff: send it as an official warning.
      warning?: boolean;
    }
  | {
      kind: "edit";
      topicId: number;
      topicTitle: string;
      postId: number;
      postNumber: number;
      raw: string;
      categoryId: number | null;
      editTitle: string | null;
      onSaved?: () => void;
    };

function draftKey(o: ComposerOptions): string {
  // Never saved: a whisper reopened from Drafts would go out as a reply.
  if (o.kind === "reply" && o.whisper) return "whisper:" + o.topicId;
  if (o.kind === "reply") return "reply:" + o.topicId;
  if (o.kind === "edit") return "edit:" + o.postId;
  return o.kind;
}

let open: Layer | null = null;

export function openComposer(o: ComposerOptions): void {
  if (open) open.close();
  const key = draftKey(o);
  const saved = getDraft(key);

  let text = "";
  let title = "";
  let to = "";
  let categoryId: number | null = null;
  let tags: TagRef[] = [];
  if (o.kind === "reply") {
    if (!o.replyTo && saved && saved.replyTo) o.replyTo = saved.replyTo;
    text = saved ? saved.text : "";
    if (o.quote)
      text = (text ? text.replace(/\s+$/, "") + "\n\n" : "") + o.quote;
  } else if (o.kind === "edit") {
    text = saved ? saved.text : o.raw;
    title =
      saved && saved.title !== undefined ? saved.title : o.editTitle || "";
  } else if (o.kind === "topic") {
    text = saved ? saved.text : o.body || "";
    title = saved ? saved.title || "" : o.title || "";
    categoryId =
      saved && saved.categoryId !== undefined
        ? saved.categoryId || null
        : o.categoryId || null;
    tags =
      saved && saved.tags
        ? saved.tags
        : (o.tags || []).map((name) => ({ name }));
  } else {
    text = saved ? saved.text : o.body || "";
    title = saved ? saved.title || "" : o.title || "";
    to = saved ? saved.to || "" : o.to || "";
  }

  const heading =
    o.kind === "reply"
      ? o.whisper
        ? "Whisper"
        : "Reply"
      : o.kind === "edit"
        ? `Edit #${o.postNumber}`
        : o.kind === "topic"
          ? "New topic"
          : o.warning
            ? "Warning"
            : "New message";
  const sendLabel =
    o.kind === "edit"
      ? "Save"
      : o.kind === "reply"
        ? "Reply"
        : o.kind === "topic"
          ? "Create"
          : "Send";

  const context =
    o.kind === "reply" || o.kind === "edit"
      ? html`<div class="c-context">
          ${icon(o.kind === "reply" ? "reply" : "edit")}<span
            >${o.kind === "reply" && o.replyTo
              ? html`@${o.replyTo.username} · #${o.replyTo.postNumber} in `
              : ""}<b>${o.topicTitle}</b></span
          >
        </div>`
      : html``;
  const notice =
    o.kind === "reply" && o.whisper
      ? html`<p class="c-notice">
          ${icon("lock")}Whisper: only ${o.whisper.label} can read it.
        </p>`
      : o.kind === "message" && o.warning
        ? html`<p class="c-notice">
            ${icon("flag")}An official warning: it goes on their record.
          </p>`
        : html``;

  const cats = postableCategories();
  const catField =
    o.kind === "topic"
      ? html`<div class="field">
          <label class="field-label" for="cCat">Category</label
          ><select id="cCat">
            <option value="">Choose a category…</option>
            ${cats.map(
              (c) =>
                html`<option
                  value="${c.id}"
                  ${c.id === categoryId ? raw(" selected") : ""}
                >
                  ${categoryName(c)}
                </option>`
            )}
          </select>
        </div>`
      : html``;
  // Categories can require tags, so a new topic gets a way to add them.
  const canTag =
    o.kind === "topic" && settings.tagsEnabled && !!user && user.can_tag_topics;
  const tagField = canTag
    ? html`<div class="field">
        <span class="field-label">Tags</span>
        <div id="cTags" class="c-tags" data-row></div>
        <p id="cTagsHint" class="hint" hidden></p>
      </div>`
    : html``;
  const toField =
    o.kind === "message"
      ? html`<div class="field">
          <label class="field-label" for="cTo">To</label
          ><input
            id="cTo"
            type="text"
            value="${to}"
            placeholder="username, another_user"
            autocomplete="off"
            autocapitalize="off"
          />
        </div>`
      : html``;
  const titleField =
    o.kind === "topic" ||
    o.kind === "message" ||
    (o.kind === "edit" && o.editTitle !== null)
      ? html`<div class="field">
          <label class="field-label" for="cTitle">Title</label
          ><input
            id="cTitle"
            type="text"
            value="${title}"
            maxlength="255"
            autocomplete="off"
          />
        </div>`
      : html``;

  let askingToClose = false;
  const layer = openLayer({
    kind: "full",
    label: heading,
    className: "composer-layer",
    body: html`<form class="composer" data-composer>
      <div class="c-head" data-row>
        <button type="button" class="tb-btn" data-c="close" aria-label="Close">
          ${icon("x")}
        </button>
        <div class="c-title">${heading}</div>
        <button type="submit" class="btn primary small" data-c="send">
          ${icon("send")}${sendLabel}
        </button>
      </div>
      <div class="c-body scroll">
        ${context}${notice}${toField}${titleField}${catField}${tagField}
        <label class="sr" for="cText">Message</label>
        <textarea
          id="cText"
          placeholder="${o.kind === "reply"
            ? "Write your reply…"
            : "Write here…"}"
        >
${text}</textarea
        >
        <div id="cMentions" class="c-mentions" data-row hidden></div>
        <div id="cPreview" class="c-preview cooked" hidden tabindex="0"></div>
        <div class="c-tools" data-row>
          <button
            type="button"
            class="btn small icon-only"
            data-c="emoji"
            aria-label="Emoji"
          >
            ${icon("smile")}
          </button>
          <button
            type="button"
            class="btn small icon-only"
            data-c="format"
            aria-label="Formatting"
          >
            ${icon("format")}
          </button>
          ${settings.allowUploads
            ? html`<button
                type="button"
                class="btn small icon-only"
                data-c="upload"
                aria-label="Attach a file"
              >
                ${icon("upload")}
              </button>`
            : ""}
          <button
            type="button"
            class="btn small icon-only"
            data-c="preview"
            aria-label="Preview"
          >
            ${icon("eye")}
          </button>
          ${settings.languagetoolEnabled
            ? html`<button
                type="button"
                class="btn small icon-only"
                data-c="refine"
                aria-label="Fix spelling and grammar"
              >
                ${icon("sparkle")}
              </button>`
            : ""}
          <span class="spacer"></span>
          <button type="button" class="btn small ghost" data-c="discard">
            ${icon("trash")}Discard
          </button>
        </div>
        <p id="cStatus" class="hint" aria-live="polite"></p>
        <input id="cFile" type="file" hidden tabindex="-1" />
      </div>
    </form>`,
    softkeys: { left: "Close", center: "", right: sendLabel },
    focusSelector:
      o.kind === "topic" || o.kind === "message"
        ? to || o.kind === "topic"
          ? "#cTitle"
          : "#cTo"
        : "#cText",
    onClose: () => {
      open = null;
      stopPresence();
    },
    // Close, Back and the backdrop ask first when there's writing to lose
    // track of; the draft stays saved either way.
    beforeClose: () => {
      if (askingToClose) return true;
      if (!hasWriting()) return false;
      askingToClose = true;
      // Short labels: they also go on a 240px phone's soft-key bar.
      void confirmDialog(
        o.kind === "reply" && o.whisper
          ? "Close? A whisper isn't kept as a draft."
          : "Close? Your draft stays on this phone.",
        {
          ok: "Close",
        }
      ).then((ok) => {
        askingToClose = false;
        if (ok) layer.close();
      });
      return true;
    },
  });
  open = layer;
  layer.el.setAttribute("data-softright", "[data-c=send]");

  const form = $("[data-composer]", layer.el) as HTMLFormElement;
  const ta = $("#cText", layer.el) as HTMLTextAreaElement;
  const titleEl = $("#cTitle", layer.el) as HTMLInputElement | null;
  const toEl = $("#cTo", layer.el) as HTMLInputElement | null;
  const catEl = $("#cCat", layer.el) as HTMLSelectElement | null;
  const status = $("#cStatus", layer.el) as HTMLElement;
  const previewEl = $("#cPreview", layer.el) as HTMLElement;
  const fileEl = $("#cFile", layer.el) as HTMLInputElement;

  if (o.kind === "reply" && o.quote) {
    // Put the caret after the quote, ready to type.
    requestAnimationFrame(() => {
      ta.focus();
      ta.selectionStart = ta.selectionEnd = ta.value.length;
    });
  }

  const hasWriting = (): boolean => {
    const blank = (v: string) => !v.replace(/\s+/g, "");
    if (o.kind === "edit")
      return (
        ta.value !== o.raw ||
        (!!titleEl && titleEl.value !== (o.editTitle || ""))
      );
    return !blank(ta.value) || (!!titleEl && !blank(titleEl.value));
  };

  const currentDraft = (): Draft => ({
    key,
    kind: o.kind,
    text: ta.value,
    title: titleEl ? titleEl.value : undefined,
    categoryId: catEl ? parseInt(catEl.value, 10) || null : undefined,
    tags: canTag ? tags : undefined,
    to: toEl ? toEl.value : undefined,
    topicId: o.kind === "reply" || o.kind === "edit" ? o.topicId : undefined,
    topicTitle:
      o.kind === "reply" || o.kind === "edit" ? o.topicTitle : undefined,
    postId: o.kind === "edit" ? o.postId : undefined,
    replyTo: o.kind === "reply" ? o.replyTo : undefined,
    updatedAt: Date.now(),
  });

  const persist = debounce(() => {
    if (o.kind === "reply" && o.whisper) return;
    if (
      o.kind === "edit" &&
      ta.value === o.raw &&
      (!titleEl || titleEl.value === (o.editTitle || ""))
    ) {
      clearDraft(key);
      return;
    }
    saveDraft(currentDraft());
    status.textContent = "Draft saved on this phone.";
  }, 600);

  const counter = () => {
    const n = ta.value.length;
    if (n > settings.maxPostLength)
      status.textContent = `Too long: ${n} of ${settings.maxPostLength} characters.`;
  };

  ta.addEventListener("input", () => {
    persist();
    counter();
    mentions.onInput();
    typing();
  });
  if (titleEl) titleEl.addEventListener("input", persist);
  if (toEl) toEl.addEventListener("input", persist);
  if (catEl)
    catEl.addEventListener("change", () => {
      persist();
      drawTags();
    });

  // ── Tags ─────────────────────────────────────────────────────────────
  const tagsBox = $("#cTags", layer.el) as HTMLElement | null;
  const tagsHint = $("#cTagsHint", layer.el) as HTMLElement | null;
  const chosenCategory = () =>
    catEl ? parseInt(catEl.value, 10) || null : null;

  // How many the chosen category asks for: its minimum, or its required
  // groups' together if that's more. The server checks each group itself.
  const tagsNeeded = (): number => {
    const c = category(chosenCategory());
    if (!c) return 0;
    let fromGroups = 0;
    (c.required_tag_groups || []).forEach(
      (g) => (fromGroups += g.min_count || 0)
    );
    return Math.max(c.minimum_required_tags || 0, fromGroups);
  };

  const drawTags = (focusAdd = false) => {
    if (!tagsBox) return;
    setHtml(
      tagsBox,
      html`${tags.map(
          (t) =>
            html`<button
              type="button"
              class="chip"
              data-tag="${t.name}"
              aria-label="Remove #${t.name}"
            >
              #${t.name} ×
            </button>`
        )}<button type="button" class="btn small" data-tag-add>
          ${icon("tag")}Add tag
        </button>`
    );
    const need = tagsNeeded();
    if (tagsHint) {
      tagsHint.hidden = !need;
      tagsHint.textContent =
        need === 1
          ? "This category needs a tag."
          : `This category needs at least ${need} tags.`;
    }
    if (focusAdd) focus($("[data-tag-add]", tagsBox) as HTMLElement);
  };

  const hasTag = (name: string) =>
    tags.some((t) => t.name.toLowerCase() === name.toLowerCase());

  const addTag = (t: TagRef) => {
    if (!hasTag(t.name)) tags = tags.concat([t]);
    persist();
    drawTags(true);
  };

  // The category's tags, most used first, or those matching what was
  // typed. Someone allowed to make tags can use a new one. `why` says what
  // the category still needs, when sending found it short.
  const pickTag = (q: string, why = "") => {
    const cat = chosenCategory();
    // No limit: asking for more than max_tag_search_results is refused, so
    // the forum's own setting decides.
    const selected = tags
      .filter((t) => t.id)
      .map((t) => "&selected_tag_ids[]=" + t.id)
      .join("");
    get<{
      results?: Array<{ id: number; name: string; count?: number }>;
      required_tag_group?: { name: string; min_count: number };
    }>(
      `/tags/filter/search.json?q=${encodeURIComponent(q)}&filterForInput=true${cat ? "&categoryId=" + cat : ""}${selected}`
    ).then(
      (res) => {
        const found = (res.results || []).filter((r) => !hasTag(r.name));
        const typed = q.replace(/^\s+|\s+$/g, "").replace(/\s+/g, "-");
        const items: SheetItem[] = [
          {
            label: "Search…",
            icon: "search",
            run: () =>
              void promptDialog("Tag", {
                title: "Find a tag",
                value: q,
                ok: "Search",
              }).then((text) => {
                if (text !== null) pickTag(text, why);
              }),
          },
        ];
        found.forEach((r) =>
          items.push({
            label: "#" + r.name,
            hint: r.count ? String(r.count) : undefined,
            run: () => addTag({ id: r.id, name: r.name }),
          })
        );
        if (
          typed &&
          user &&
          user.can_create_tag &&
          !hasTag(typed) &&
          !found.some((r) => r.name.toLowerCase() === typed.toLowerCase())
        )
          items.push({
            label: `New tag #${typed}`,
            icon: "plus",
            run: () => addTag({ name: typed }),
          });
        if (items.length === 1)
          items.push({
            label: q ? "No tags match." : "No tags to pick here.",
            disabled: true,
          });
        const group = res.required_tag_group;
        actionSheet(q ? `Tags matching "${q}"` : "Add a tag", items, {
          subtitle: group
            ? `Pick at least ${group.min_count} from ${group.name}.`
            : why || undefined,
        });
      },
      (err: unknown) => toast(errorMessage(err), "error")
    );
  };

  if (tagsBox) {
    drawTags();
    tagsBox.addEventListener("click", (e) => {
      // No Element.closest on the oldest phones.
      let el = e.target as HTMLElement | null;
      while (
        el &&
        el !== tagsBox &&
        !el.getAttribute("data-tag") &&
        el.getAttribute("data-tag-add") === null
      )
        el = el.parentNode as HTMLElement | null;
      if (!el || el === tagsBox) return;
      e.preventDefault();
      const name = el.getAttribute("data-tag");
      if (name) {
        tags = tags.filter((t) => t.name !== name);
        persist();
        drawTags(true);
      } else pickTag("");
    });
  }

  // ── Mentions ─────────────────────────────────────────────────────────
  const mentions = mentionHelper(
    ta,
    $("#cMentions", layer.el) as HTMLElement,
    o.kind === "reply" ? o.topicId : null,
    o.kind === "reply" ? o.participants || [] : []
  );

  // ── Presence ("typing…") for replies ────────────────────────────────
  let lastPresence = 0;
  let presenceTimer: ReturnType<typeof setTimeout> | null = null;
  const presenceChannel =
    o.kind === "reply"
      ? `/discourse-presence/reply/${o.topicId}`
      : o.kind === "edit"
        ? `/discourse-presence/edit/${o.postId}`
        : "";
  const typing = () => {
    if (!presenceChannel) return;
    const now = Date.now();
    if (now - lastPresence < 5000) return;
    lastPresence = now;
    post(
      "/presence/update",
      { client_id: busClientId(), present_channels: [presenceChannel] },
      { urlencoded: true }
    ).catch(() => undefined);
    if (presenceTimer) clearTimeout(presenceTimer);
    presenceTimer = setTimeout(stopPresence, 20000);
  };
  const stopPresence = () => {
    if (presenceTimer) clearTimeout(presenceTimer);
    presenceTimer = null;
    if (!presenceChannel || !lastPresence) return;
    lastPresence = 0;
    post(
      "/presence/update",
      { client_id: busClientId(), leave_channels: [presenceChannel] },
      { urlencoded: true }
    ).catch(() => undefined);
  };

  // ── Tools ────────────────────────────────────────────────────────────

  const insert = (before: string, after = "", placeholder = "") => {
    const start = ta.selectionStart || 0;
    const end = ta.selectionEnd || 0;
    const selected = ta.value.slice(start, end) || placeholder;
    ta.value =
      ta.value.slice(0, start) +
      before +
      selected +
      after +
      ta.value.slice(end);
    const caret = start + before.length + selected.length;
    ta.focus();
    ta.selectionStart = start + before.length;
    ta.selectionEnd = caret;
    fire(ta, "input");
  };

  const linePrefix = (prefix: string) => {
    const start = ta.selectionStart || 0;
    const lineStart = ta.value.lastIndexOf("\n", start - 1) + 1;
    ta.value =
      ta.value.slice(0, lineStart) + prefix + ta.value.slice(lineStart);
    ta.focus();
    ta.selectionStart = ta.selectionEnd = start + prefix.length;
    fire(ta, "input");
  };

  const format = () => {
    actionSheet("Formatting", [
      {
        label: "Bold",
        icon: "bold",
        run: () => insert("**", "**", "bold text"),
      },
      {
        label: "Italic",
        icon: "italic",
        run: () => insert("*", "*", "italic text"),
      },
      { label: "Quote", icon: "quote", run: () => linePrefix("> ") },
      { label: "Bulleted list", icon: "list", run: () => linePrefix("- ") },
      { label: "Numbered list", icon: "list", run: () => linePrefix("1. ") },
      {
        label: "Link",
        icon: "link",
        run: () =>
          promptDialog("Web address", {
            type: "url",
            placeholder: "https://",
            ok: "Insert",
          }).then((url) => {
            if (url && /^https?:\/\//i.test(url))
              insert("[", `](${url})`, "link text");
            else if (url)
              toast("Links must start with http:// or https://", "error");
          }),
      },
      { label: "Code", icon: "format", run: () => insert("`", "`", "code") },
      {
        label: "Spoiler",
        icon: "eyeOff",
        run: () => insert("[spoiler]", "[/spoiler]", "hidden text"),
      },
      {
        label: "Hidden details",
        icon: "info",
        run: () =>
          insert('[details="Summary"]\n', "\n[/details]", "hidden details"),
      },
      {
        label: "Poll",
        icon: "poll",
        run: () =>
          insert(
            "\n[poll type=regular]\n* ",
            "\n* Option 2\n[/poll]\n",
            "Option 1"
          ),
      },
    ]);
  };

  const refine = () => {
    const value = ta.value;
    if (!value.replace(/\s+/g, "")) {
      toast("Write something first.");
      return;
    }
    status.textContent = "Checking spelling and grammar…";
    post<{
      matches?: Array<{
        offset: number;
        length: number;
        replacements?: Array<{ value: string }>;
      }>;
    }>(settings.basePath + "/languagetool/check", {
      text: value,
    }).then(
      (d) => {
        const fixed = applyFixes(value, (d && d.matches) || []);
        if (fixed === value) {
          status.textContent = "No fixes suggested.";
          return;
        }
        ta.value = fixed;
        fire(ta, "input");
        status.textContent = "Fixes applied. Check them before sending.";
      },
      (e: unknown) => {
        status.textContent = "";
        toast(errorMessage(e), "error");
      }
    );
  };

  let previewOn = false;
  const togglePreview = () => {
    previewOn = !previewOn;
    previewEl.hidden = !previewOn;
    ta.hidden = previewOn;
    if (!previewOn) {
      ta.focus();
      return;
    }
    setHtml(
      previewEl,
      html`<div class="state state-loading">
        <span class="spinner"></span>Preparing preview…
      </div>`
    );
    post<{ cooked?: string }>(settings.basePath + "/api/preview", {
      raw: ta.value,
    }).then(
      (d) => setHtml(previewEl, processCooked((d && d.cooked) || "").html),
      () =>
        setHtml(
          previewEl,
          html`<p class="muted">Preview unavailable offline.</p>
            <pre>${ta.value}</pre>`
        )
    );
    focus(previewEl);
  };

  const upload = () => fileEl.click();
  fileEl.addEventListener("change", () => {
    const file = fileEl.files && fileEl.files[0];
    if (!file) return;
    const fd = new FormData();
    fd.append("file", file); // old-browser-ok (FormData, not DOM)
    fd.append("type", "composer"); // old-browser-ok
    fd.append("synchronous", "true"); // old-browser-ok
    status.textContent = "Uploading… 0%";
    request<{
      short_url?: string;
      url?: string;
      original_filename?: string;
      width?: number;
      height?: number;
    }>("/uploads.json", {
      method: "POST",
      form: fd,
      timeout: 120000,
      onProgress: (f) => {
        status.textContent = `Uploading… ${Math.round(f * 100)}%`;
      },
    }).then(
      (u) => {
        fileEl.value = "";
        const name = (u.original_filename || file.name || "file").replace(
          /[[\]|]/g,
          ""
        );
        const link = u.short_url || u.url || "";
        const isImage =
          /^image\//.test(file.type) ||
          /\.(png|jpe?g|gif|webp|bmp|heic)$/i.test(name);
        const md = isImage
          ? `![${name}${u.width && u.height ? `|${u.width}x${u.height}` : ""}](${link})`
          : `[${name}|attachment](${link})`;
        insert(
          (ta.value && !/\n$/.test(ta.value.slice(0, ta.selectionStart || 0))
            ? "\n"
            : "") +
            md +
            "\n"
        );
        status.textContent = "Uploaded.";
      },
      (e: unknown) => {
        fileEl.value = "";
        status.textContent = "";
        toast(errorMessage(e), "error");
      }
    );
  });

  const discard = () => {
    confirmDialog("Throw away this draft?", {
      ok: "Discard",
      danger: true,
    }).then((ok) => {
      if (!ok) return;
      clearDraft(key);
      layer.close();
    });
  };

  // ── Send ─────────────────────────────────────────────────────────────

  let sending = false;
  const send = () => {
    if (sending) return;
    const body = ta.value.replace(/\s+$/, "");
    if (
      body.replace(/\s+/g, "").length < Math.min(settings.minPostLength, 1) ||
      !body.replace(/\s+/g, "")
    ) {
      toast("Write something first.", "error");
      focus(ta);
      return;
    }
    if (body.length > settings.maxPostLength) {
      toast(
        `That's too long (${body.length}/${settings.maxPostLength}).`,
        "error"
      );
      return;
    }
    let req: Promise<unknown>;
    if (o.kind === "reply") {
      req = post<Post>("/posts.json", {
        topic_id: o.topicId,
        raw: body,
        reply_to_post_number: o.replyTo ? o.replyTo.postNumber : undefined,
        archetype: "regular",
        nested_post: true,
        dumbcourse: true,
        whisper: o.whisper && o.whisper.core ? true : undefined,
        mod_whisper: o.whisper && !o.whisper.core ? "true" : undefined,
        mod_whisper_target_user_ids:
          o.whisper && !o.whisper.core && o.whisper.userIds.length
            ? o.whisper.userIds
            : undefined,
        mod_whisper_target_group_ids:
          o.whisper && !o.whisper.core && o.whisper.groupIds
            ? o.whisper.groupIds
            : undefined,
        mod_whisper_target_badge_ids:
          o.whisper && !o.whisper.core && o.whisper.badgeIds
            ? o.whisper.badgeIds
            : undefined,
      });
    } else if (o.kind === "edit") {
      const edits: Array<Promise<unknown>> = [
        put(`/posts/${o.postId}.json`, {
          post: { raw: body, edit_reason: "" },
        }),
      ];
      if (
        titleEl &&
        o.editTitle !== null &&
        titleEl.value.replace(/\s+/g, "") &&
        titleEl.value !== o.editTitle
      ) {
        edits.push(put(`/t/-/${o.topicId}.json`, { title: titleEl.value }));
      }
      req = Promise.all(edits);
    } else if (o.kind === "topic") {
      const t = titleEl ? titleEl.value.replace(/^\s+|\s+$/g, "") : "";
      if (t.length < settings.minTitleLength) {
        toast(
          `The title needs at least ${settings.minTitleLength} characters.`,
          "error"
        );
        if (titleEl) focus(titleEl);
        return;
      }
      const need = canTag ? tagsNeeded() : 0;
      if (tags.length < need) {
        pickTag(
          "",
          need === 1
            ? "This category needs a tag."
            : `This category needs at least ${need} tags.`
        );
        return;
      }
      const cat = catEl ? parseInt(catEl.value, 10) || undefined : undefined;
      req = post("/posts.json", {
        title: t,
        raw: body,
        category: cat,
        tags: tags.length ? tags : undefined,
        archetype: "regular",
        dumbcourse: true,
      });
    } else {
      const t = titleEl ? titleEl.value.replace(/^\s+|\s+$/g, "") : "";
      const recipients = toEl
        ? toEl.value
            .replace(/@/g, "")
            .replace(/\s+/g, "")
            .replace(/^,+|,+$/g, "")
        : "";
      if (!recipients) {
        toast("Who is it to?", "error");
        if (toEl) focus(toEl);
        return;
      }
      if (!t) {
        toast("Give it a title.", "error");
        if (titleEl) focus(titleEl);
        return;
      }
      req = post("/posts.json", {
        title: t,
        raw: body,
        target_recipients: recipients,
        archetype: "private_message",
        is_warning: o.warning ? true : undefined,
      });
    }
    sending = true;
    const sendBtn = $("[data-c=send]", layer.el);
    if (sendBtn) sendBtn.setAttribute("disabled", "");
    status.textContent = "Sending…";
    req.then(
      (res) => {
        sending = false;
        stopPresence();
        clearDraft(key);
        layer.close();
        if (o.kind === "reply") {
          const r = res as { post?: Post } & Post;
          const created = r && r.post ? r.post : r;
          if (created && created.id && o.onPosted) o.onPosted(created);
          toast(o.whisper ? "Whisper posted." : "Reply posted.", "success");
        } else if (o.kind === "edit") {
          if (o.onSaved) o.onSaved();
          toast("Saved.", "success");
        } else {
          const r = res as {
            topic_id?: number;
            topic_slug?: string;
            post?: { topic_id: number; topic_slug: string };
          };
          const topicId = r.topic_id || (r.post && r.post.topic_id);
          const slug = r.topic_slug || (r.post && r.post.topic_slug) || "";
          invalidate();
          toast(
            o.kind === "topic" ? "Topic created." : "Message sent.",
            "success"
          );
          if (topicId) go(topicPath(topicId, slug));
        }
      },
      (e: unknown) => {
        sending = false;
        if (sendBtn) sendBtn.removeAttribute("disabled");
        status.textContent = "";
        const err = e as {
          body?: { action?: string; pending_count?: number } | null;
        };
        if (err && err.body && err.body.action === "enqueued") {
          clearDraft(key);
          layer.close();
          toast("Sent for approval.", "success");
          return;
        }
        toast(errorMessage(e), "error");
      }
    );
  };

  form.addEventListener("submit", (e) => {
    e.preventDefault();
    send();
  });

  layer.el.addEventListener("click", (e) => {
    const t = e.target as HTMLElement;
    const btn =
      t && t.getAttribute
        ? t.getAttribute("data-c")
          ? t
          : (t.parentNode as HTMLElement)
        : null;
    const which = btn && btn.getAttribute ? btn.getAttribute("data-c") : null;
    if (!which) return;
    if (which === "send") return; // handled by submit
    e.preventDefault();
    if (which === "close") layer.requestClose();
    else if (which === "emoji") emojiPicker((name) => insert(`:${name}: `));
    else if (which === "format") format();
    else if (which === "upload") upload();
    else if (which === "preview") togglePreview();
    else if (which === "refine") refine();
    else if (which === "discard") discard();
  });
}

// Applies LanguageTool's first suggestion for each match. Overlapping
// matches keep the earliest one; edits go back to front so offsets stay
// valid.
export function applyFixes(
  text: string,
  matches: Array<{
    offset: number;
    length: number;
    replacements?: Array<{ value: string }>;
  }>
): string {
  const usable = matches
    .filter(
      (m) =>
        typeof m.offset === "number" &&
        typeof m.length === "number" &&
        m.offset >= 0 &&
        m.length >= 0
    )
    .filter(
      (m) =>
        m.replacements &&
        m.replacements.length &&
        m.offset + m.length <= text.length
    )
    .sort((a, b) => a.offset - b.offset);
  const chosen: typeof usable = [];
  let end = -1;
  for (let i = 0; i < usable.length; i++) {
    if (usable[i].offset < end) continue;
    chosen.push(usable[i]);
    end = usable[i].offset + usable[i].length;
  }
  let out = text;
  for (let i = chosen.length - 1; i >= 0; i--) {
    const m = chosen[i];
    out =
      out.slice(0, m.offset) +
      (m.replacements as Array<{ value: string }>)[0].value +
      out.slice(m.offset + m.length);
  }
  return out;
}

// ── @mentions ─────────────────────────────────────────────────────────

function mentionHelper(
  ta: HTMLTextAreaElement,
  box: HTMLElement,
  topicId: number | null,
  seeds: Array<{ username: string; avatar_template: string }>
): { onInput: () => void } {
  let start = -1;
  let items: Array<{ username: string; avatar_template: string }> = [];
  let active = -1;
  let seq = 0;

  const close = () => {
    box.hidden = true;
    box.innerHTML = "";
    items = [];
    active = -1;
    start = -1;
    ta.removeAttribute("data-own-arrows");
  };

  const paint = () => {
    if (!items.length) {
      close();
      return;
    }
    setHtml(
      box,
      html`${items.map(
        (u, i) =>
          html`<button
            type="button"
            class="chip${i === active ? " on" : ""}"
            data-m="${u.username}"
            tabindex="-1"
          >
            ${avatar(u.avatar_template, 18)}@${u.username}
          </button>`
      )}`
    );
    box.hidden = false;
    ta.setAttribute("data-own-arrows", "");
  };

  const pick = (username: string) => {
    const caret = ta.selectionStart || 0;
    const before = ta.value.slice(0, start) + "@" + username + " ";
    ta.value = before + ta.value.slice(caret);
    ta.selectionStart = ta.selectionEnd = before.length;
    close();
    ta.focus();
    fire(ta, "input");
  };

  box.addEventListener("mousedown", (e) => e.preventDefault());
  box.addEventListener("click", (e) => {
    const t = e.target as HTMLElement;
    const b =
      t && (t.getAttribute("data-m") ? t : (t.parentNode as HTMLElement));
    const name = b && b.getAttribute ? b.getAttribute("data-m") : null;
    if (name) pick(name);
  });

  ta.addEventListener("keydown", (e: KeyboardEvent) => {
    if (box.hidden || !items.length) return;
    const k = e.key || "";
    const code = e.keyCode;
    if (
      k === "ArrowDown" ||
      k === "Down" ||
      code === 40 ||
      k === "ArrowRight" ||
      k === "Right"
    ) {
      e.preventDefault();
      active = Math.min(items.length - 1, active + 1);
      paint();
    } else if (
      k === "ArrowUp" ||
      k === "Up" ||
      code === 38 ||
      k === "ArrowLeft" ||
      k === "Left"
    ) {
      e.preventDefault();
      active = Math.max(0, active - 1);
      paint();
    } else if ((k === "Enter" || code === 13) && active >= 0) {
      e.preventDefault();
      pick(items[active].username);
    } else if (k === "Escape" || k === "Esc" || code === 27) {
      e.preventDefault();
      e.stopPropagation();
      close();
    }
  });

  const onInput = () => {
    const caret = ta.selectionStart || 0;
    const before = ta.value.slice(0, caret);
    const m = /(^|\s)@([\w.-]{0,30})$/.exec(before);
    if (!m) {
      close();
      return;
    }
    start = caret - m[2].length - 1;
    const term = m[2].toLowerCase();
    const local = seeds
      .filter((u) => u.username.toLowerCase().indexOf(term) === 0)
      .slice(0, 5);
    items = local;
    active = -1;
    paint();
    if (term.length < 1) return;
    const mine = ++seq;
    get<{ users?: Array<{ username: string; avatar_template: string }> }>(
      `/u/search/users.json?term=${encodeURIComponent(term)}&include_groups=false${topicId ? "&topic_id=" + topicId : ""}`
    ).then(
      (d) => {
        if (mine !== seq || start < 0) return;
        const found = (d.users || []).slice(0, 6);
        const names: Record<string, boolean> = {};
        items = [];
        local.concat(found).forEach((u) => {
          if (!names[u.username]) {
            names[u.username] = true;
            items.push(u);
          }
        });
        items = items.slice(0, 6);
        paint();
      },
      () => undefined
    );
  };

  return { onInput };
}

// ── Emoji picker ──────────────────────────────────────────────────────

export function emojiPicker(pick: (name: string) => void): void {
  const cell = (name: string): SafeHtml =>
    html`<button
      type="button"
      class="emoji-cell"
      data-e="${name}"
      aria-label="${name.replace(/_/g, " ")}"
    >
      ${emojiImg(name, "emoji big")}
    </button>`;
  const layer = openLayer({
    kind: "sheet",
    label: "Emoji",
    body: html`<div class="sheet emoji-sheet">
      <div class="sheet-head">
        <input
          id="emojiSearch"
          type="search"
          placeholder="Search emoji"
          autocomplete="off"
          aria-label="Search emoji"
        />
      </div>
      <div id="emojiGrid" class="emoji-grid scroll" data-grid>
        ${COMMON_EMOJI.map(cell)}
      </div>
    </div>`,
    softkeys: { left: "Close", center: "Insert", right: "" },
    focusSelector: ".emoji-cell",
  });
  const grid = byId("emojiGrid") as HTMLElement;
  const input = byId("emojiSearch") as HTMLInputElement;
  layer.el.addEventListener("click", (e) => {
    const t = e.target as HTMLElement;
    const b =
      t && (t.getAttribute("data-e") ? t : (t.parentNode as HTMLElement));
    const name = b && b.getAttribute ? b.getAttribute("data-e") : null;
    if (!name) return;
    layer.close();
    pick(name);
  });
  const search = debounce(() => {
    const term = input.value;
    if (!term.replace(/\s+/g, "")) {
      setHtml(grid, html`${COMMON_EMOJI.map(cell)}`);
      return;
    }
    allEmojiNames().then(
      (names) => {
        const found = searchEmoji(names, term);
        setHtml(
          grid,
          found.length
            ? html`${found.map(cell)}`
            : html`<p class="muted pad">No emoji match “${term}”.</p>`
        );
      },
      () =>
        setHtml(
          grid,
          html`<p class="muted pad">Couldn't load the emoji list.</p>`
        )
    );
  }, 250);
  input.addEventListener("input", search);
}
