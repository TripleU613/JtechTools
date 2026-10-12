// Prepares a post's HTML (already sanitised by Discourse) for a small
// screen: forum links open inside Dumbcourse, outside links open in a new
// window, images honour the data-saver setting, embeds become plain links,
// and every link is collected so the post's action sheet can list them —
// much easier with a D-pad than tabbing through a paragraph.

import { closest } from "../compat.ts";
import { $$ } from "../dom.ts";
import { APP_ROOT, settings } from "../config.ts";
import { raw, type SafeHtml } from "../html.ts";
import { prefs } from "../prefs.ts";
import { dateTime, longDate, parseDate } from "../format.ts";

export interface PostLink {
  text: string;
  href: string;
  internal: boolean;
}

// A picture in a post, for the picture viewer (a post is one D-pad stop, so
// its pictures open from the post's menu).
export interface Picture {
  // As the post shows it (often resized): used for gallery thumbnails.
  src: string;
  // The full-size original.
  full: string;
  // Downloads it, or "" for pictures from other sites.
  save: string;
  // Its own name, or "" when it has none worth showing.
  name: string;
}

export interface Processed {
  html: SafeHtml;
  links: PostLink[];
  images: number;
  pictures: Picture[];
}

// A forum upload's download link. Discourse sends the file as a download
// with ?dl=1. Only the path is kept: Discourse writes its links with its own
// hostname, and the forum may be open under another one, where the reader's
// session (needed to download) lives. Pictures from other sites have none.
export function pictureSaveUrl(
  downloadHref: string,
  base62: string,
  full: string
): string {
  let path = "";
  const m = /^(?:https?:)?\/\/[^/]+(\/.*)$/.exec(downloadHref);
  if (m) path = m[1];
  else if (downloadHref.charAt(0) === "/") path = downloadHref;
  if (path && path.indexOf(settings.subfolder + "/uploads/") !== 0) path = "";
  if (!path && base62) {
    const ext = /\.([a-z0-9]+)(?:[?#]|$)/i.exec(full);
    if (ext)
      path = settings.subfolder + "/uploads/short-url/" + base62 + "." + ext[1];
  }
  if (!path) return "";
  return path + (path.indexOf("?") >= 0 ? "&" : "?") + "dl=1";
}

// Pasted pictures are all called "image", and phone photos are named with
// digits: neither is worth showing.
function pictureName(alt: string): string {
  const name = alt.replace(/^\s+|\s+$/g, "");
  return /[a-z]/i.test(name) && !/^image$/i.test(name) ? name.slice(0, 80) : "";
}

let inert: Document | null = null;

// Parsing into a separate document keeps the browser from fetching images
// we may decide not to show.
function scratch(): HTMLElement {
  if (!inert) {
    try {
      inert = document.implementation.createHTMLDocument("");
    } catch {
      inert = document;
    }
  }
  return inert.createElement("div");
}

function origin(): string {
  return location.protocol + "//" + location.host;
}

// A forum URL (relative or absolute on this host) → the matching
// Dumbcourse path, or null if Dumbcourse has no screen for it.
export function appPathFor(url: string): string | null {
  let u = url;
  if (u.indexOf(origin()) === 0) u = u.slice(origin().length);
  if (u.indexOf("//") === 0 || /^[a-z][a-z0-9+.-]*:/i.test(u)) return null;
  if (u.charAt(0) !== "/") return null;
  if (settings.subfolder && u.indexOf(settings.subfolder + "/") === 0)
    u = u.slice(settings.subfolder.length);
  if (u.indexOf(settings.basePath + "/") === 0 || u === settings.basePath)
    return u.slice(settings.basePath.length) || "/";
  const path = u.split("#")[0];
  if (
    /^\/(t|u|c|tag|tags|search|latest|new|unread|top|hot|categories|notifications|my\/(bookmarks|messages|activity))(\/|\?|$)/.test(
      path
    )
  ) {
    return path
      .replace(/^\/my\/bookmarks/, "/bookmarks")
      .replace(/^\/my\/messages/, "/messages")
      .replace(/^\/my\/activity/, "/u/me");
  }
  if (path === "/" || path === "") return "/";
  return null;
}

function absolute(url: string): string {
  if (/^https?:\/\//i.test(url) || url.indexOf("//") === 0) return url;
  if (url.charAt(0) === "/") return url;
  return url;
}

function linkText(a: Element): string {
  const text = (a.textContent || "")
    .replace(/\s+/g, " ")
    .replace(/^\s+|\s+$/g, "");
  if (text) return text.length > 80 ? text.slice(0, 79) + "…" : text;
  const img = a.querySelector("img");
  return (
    (img && (img.getAttribute("alt") || img.getAttribute("title"))) || "Link"
  );
}

function isEmojiOrAvatar(img: Element): boolean {
  const cls = " " + (img.getAttribute("class") || "") + " ";
  return (
    cls.indexOf(" emoji ") >= 0 ||
    cls.indexOf(" avatar ") >= 0 ||
    cls.indexOf(" site-icon ") >= 0
  );
}

function formatLocalDate(el: Element): void {
  const date = el.getAttribute("data-date");
  const time = el.getAttribute("data-time");
  if (!date) return;
  const iso =
    date +
    "T" +
    (time || "00:00:00") +
    (el.getAttribute("data-timezone") ? "" : "Z");
  let d = parseDate(iso);
  const tz = el.getAttribute("data-timezone");
  if (tz && d) {
    // Without Intl time-zone support we cannot convert; show it as written.
    d = parseDate(date + "T" + (time || "00:00:00"));
  }
  if (!d) return;
  el.textContent = time
    ? dateTime(d) + (tz ? " (" + tz + ")" : "")
    : longDate(d);
  el.setAttribute("class", "local-date");
}

export function processCooked(cooked: string | null | undefined): Processed {
  const box = scratch();
  box.innerHTML = cooked || "";
  const links: PostLink[] = [];
  const pictures: Picture[] = [];
  let images = 0;

  // Embeds that cannot play on a flip phone become plain links.
  for (const frame of $$("iframe", box)) {
    const src = frame.getAttribute("src") || "";
    const a = box.ownerDocument.createElement("a");
    a.setAttribute("href", src);
    a.textContent = "▶ Open embedded content";
    if (frame.parentNode) frame.parentNode.replaceChild(a, frame);
  }
  for (const lazy of $$(".lazy-video-container, .lazyYT", box)) {
    const url =
      lazy.getAttribute("data-video-url") ||
      lazy.querySelector("a")?.getAttribute("href") ||
      "";
    const title = lazy.getAttribute("data-video-title") || "Video";
    if (!url) continue;
    const a = box.ownerDocument.createElement("a");
    a.setAttribute("href", url);
    a.setAttribute("class", "video-link");
    a.textContent = "▶ " + title;
    if (lazy.parentNode) lazy.parentNode.replaceChild(a, lazy);
  }

  // Lightbox chrome is for big screens.
  for (const meta of $$(
    ".lightbox-wrapper .meta, .onebox-metadata, .quote-controls, .cooked-selection-barrier",
    box
  )) {
    if (meta.parentNode) meta.parentNode.removeChild(meta);
  }

  // Images.
  for (const img of $$("img", box)) {
    img.removeAttribute("srcset");
    img.removeAttribute("sizes");
    const src = img.getAttribute("src") || "";
    if (isEmojiOrAvatar(img)) {
      img.setAttribute("loading", "lazy");
      continue;
    }
    images++;
    img.setAttribute("loading", "lazy");
    img.setAttribute("src", absolute(src));
    // The post's own pictures, for the viewer: the full-size original is
    // the lightbox link around a resized picture. Link previews' thumbnails
    // aren't the post's pictures. Tapping one opens the viewer on it (the
    // topic view's "view-picture" action; elsewhere the link works as before).
    let picture = "";
    if (!closest(img, ".onebox")) {
      const parent = img.parentNode as Element | null;
      const lightbox =
        parent &&
        parent.getAttribute &&
        /\blightbox\b/.test(parent.getAttribute("class") || "")
          ? parent
          : null;
      const full = absolute((lightbox && lightbox.getAttribute("href")) || src);
      picture = String(pictures.length);
      const tapped = lightbox || img;
      tapped.setAttribute("data-act", "view-picture");
      tapped.setAttribute("data-pic", picture);
      pictures.push({
        src: absolute(src),
        full,
        save: pictureSaveUrl(
          (lightbox && lightbox.getAttribute("data-download-href")) || "",
          img.getAttribute("data-base62-sha1") || "",
          full
        ),
        name: pictureName(img.getAttribute("alt") || ""),
      });
    }
    if (prefs.images === "show") continue;
    const w = img.getAttribute("width");
    const h = img.getAttribute("height");
    const alt = img.getAttribute("alt") || "";
    const btn = box.ownerDocument.createElement("button");
    btn.setAttribute("type", "button");
    btn.setAttribute("class", "img-placeholder");
    btn.setAttribute("data-act", "load-image");
    btn.setAttribute("data-src", absolute(src));
    if (picture) btn.setAttribute("data-pic", picture);
    if (w) btn.setAttribute("data-w", w);
    if (h) btn.setAttribute("data-h", h);
    btn.textContent =
      prefs.images === "tap"
        ? "Show image" +
          (alt && !/^image$/i.test(alt) ? ": " + alt.slice(0, 40) : "")
        : "Image hidden";
    const lightbox =
      img.parentNode &&
      (img.parentNode as Element).getAttribute &&
      (img.parentNode as Element).getAttribute("class") === "lightbox"
        ? img.parentNode
        : null;
    const target = lightbox || img;
    if (target.parentNode) target.parentNode.replaceChild(btn, target);
  }

  // Links.
  for (const a of $$("a[href]", box)) {
    const hrefValue = a.getAttribute("href") || "";
    if (!hrefValue || hrefValue.charAt(0) === "#") continue;
    if (/^javascript:/i.test(hrefValue)) {
      a.removeAttribute("href");
      continue;
    }
    const appPath = appPathFor(hrefValue);
    if (appPath) {
      a.setAttribute("href", APP_ROOT + (appPath === "/" ? "/" : appPath));
      a.removeAttribute("target");
      links.push({
        text: linkText(a),
        href: APP_ROOT + appPath,
        internal: true,
      });
    } else {
      const abs = absolute(hrefValue);
      a.setAttribute("href", abs);
      a.setAttribute("target", "_blank");
      a.setAttribute("rel", "noopener noreferrer nofollow ugc");
      if (
        !/^(mailto|tel|sms):/i.test(abs) &&
        !(a.getAttribute("class") || "").match(/lightbox/)
      ) {
        links.push({ text: linkText(a), href: abs, internal: false });
      } else if (/^(mailto|tel|sms):/i.test(abs)) {
        links.push({ text: linkText(a), href: abs, internal: false });
      }
    }
    // Links inside a post are reached through the post's action sheet, so
    // they do not add D-pad stops in the text.
    a.setAttribute("tabindex", "-1");
  }

  // Quotes: make the header jump to the quoted post.
  for (const quote of $$("aside.quote", box)) {
    const topic = quote.getAttribute("data-topic");
    const post = quote.getAttribute("data-post");
    const title = quote.querySelector(".title");
    if (title && topic && !title.querySelector("a")) {
      const a = box.ownerDocument.createElement("a");
      a.setAttribute("href", APP_ROOT + "/t/" + topic + "/" + (post || "1"));
      a.setAttribute("tabindex", "-1");
      a.setAttribute("class", "quote-jump");
      while (title.firstChild) a.appendChild(title.firstChild);
      title.appendChild(a);
    }
  }

  for (const el of $$(".discourse-local-date, span[data-date]", box))
    formatLocalDate(el);

  for (const table of $$("table", box)) {
    const wrap = box.ownerDocument.createElement("div");
    wrap.setAttribute("class", "table-wrap");
    if (table.parentNode) {
      table.parentNode.replaceChild(wrap, table);
      wrap.appendChild(table);
    }
  }

  // Spoilers and details need to be operable without a mouse.
  for (const el of $$(".spoiler, .spoiled, .spoiler-blurred", box)) {
    el.setAttribute("data-act", "spoiler");
    el.setAttribute("role", "button");
  }
  for (const s of $$("details > summary", box))
    s.setAttribute("tabindex", "-1");

  // Polls are drawn from post.polls instead (see polls.ts).
  for (const poll of $$("div.poll", box)) {
    const name = poll.getAttribute("data-poll-name") || "poll";
    const holder = box.ownerDocument.createElement("div");
    holder.setAttribute("class", "poll-slot");
    holder.setAttribute("data-poll-slot", name);
    if (poll.parentNode) poll.parentNode.replaceChild(holder, poll);
  }

  return { html: raw(box.innerHTML), links, images, pictures };
}

// Plain text of a post for quoting when the raw source is unavailable.
export function cookedToText(cooked: string): string {
  const box = scratch();
  box.innerHTML = cooked
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/(p|div|li|h\d|blockquote)>/gi, "\n");
  return (box.textContent || "")
    .replace(/\n{3,}/g, "\n\n")
    .replace(/^\s+|\s+$/g, "");
}
