// Forum-wide data: categories, notification and flag types, and the paths
// of Dumbcourse's own screens.

import { settings, type BootCategory } from "./config.ts";
import { html, type SafeHtml } from "./html.ts";
import { href } from "./router.ts";

const categories: Record<number, BootCategory> = {};

export function addCategories(
  list: Array<Partial<BootCategory>> | null | undefined
): void {
  if (!list) return;
  for (let i = 0; i < list.length; i++) {
    const c = list[i];
    if (!c || !c.id) continue;
    const existing = categories[c.id];
    const merged = (existing ? existing : {}) as Record<string, unknown>;
    const given = c as Record<string, unknown>;
    for (const k in given)
      if (given.hasOwnProperty(k) && given[k] !== undefined)
        merged[k] = given[k];
    categories[c.id] = merged as unknown as BootCategory;
  }
}

addCategories(settings.categories);

export function category(id: number | null | undefined): BootCategory | null {
  return (id && categories[id]) || null;
}

export function allCategories(): BootCategory[] {
  const out: BootCategory[] = [];
  for (const k in categories)
    if (categories.hasOwnProperty(k)) out.push(categories[k]);
  out.sort(
    (a, b) =>
      (a.position || 0) - (b.position || 0) || a.name.localeCompare(b.name)
  );
  return out;
}

// Categories the signed-in person may start a topic in (permission 1 is
// "create" in Discourse's category serializer).
export function postableCategories(): BootCategory[] {
  return allCategories().filter(
    (c) =>
      c.permission === 1 || c.permission === null || c.permission === undefined
  );
}

export function categoryName(c: BootCategory): string {
  const parent = c.parent_category_id ? category(c.parent_category_id) : null;
  return parent ? parent.name + " › " + c.name : c.name;
}

export function colour(hex: string | null | undefined): string {
  return /^[0-9a-f]{3,6}$/i.test(hex || "") ? "#" + hex : "#888";
}

export function categoryBadge(id: number | null | undefined): SafeHtml {
  const c = category(id);
  if (!c) return html``;
  const parent = c.parent_category_id ? category(c.parent_category_id) : null;
  const style = `border-color:${colour(c.color)}`;
  if (!settings.showCategoryNames) {
    return html`<span
      class="cat-dot"
      style="background:${colour(c.color)}"
      title="${categoryName(c)}"
    ></span>`;
  }
  return html`<span class="cat" style="${style}"
    ><span class="cat-sw" style="background:${colour(c.color)}"></span>${parent
      ? parent.name + " › "
      : ""}${c.name}</span
  >`;
}

export function categoryPath(c: BootCategory): string {
  const parent = c.parent_category_id ? category(c.parent_category_id) : null;
  return "/c/" + (parent ? parent.slug + "/" : "") + c.slug + "/" + c.id;
}

export function topicPath(
  id: number | string,
  slug?: string | null,
  postNumber?: number | string | null
): string {
  let p = "/t/" + (slug ? slug + "/" : "") + id;
  if (
    postNumber &&
    /^\d+$/.test(String(postNumber)) &&
    String(postNumber) !== "1"
  )
    p += "/" + postNumber;
  return p;
}

export function topicHref(
  id: number | string,
  slug?: string | null,
  postNumber?: number | string | null
): string {
  return href(topicPath(id, slug, postNumber));
}

export function userPath(username: string): string {
  return "/u/" + encodeURIComponent(username);
}

export function userHref(username: string): string {
  return href(userPath(username));
}

export function notificationTypeName(id: number): string {
  const types = settings.notificationTypes;
  for (const name in types)
    if (types.hasOwnProperty(name) && types[name] === id) return name;
  return "";
}

export function avatarUrl(
  template: string | null | undefined,
  size: number
): string {
  if (!template) return "";
  const px = Math.round(size * Math.min(2, window.devicePixelRatio || 1));
  // Discourse serves avatars in a fixed set of sizes.
  const sizes = [24, 48, 72, 96, 120, 144, 240];
  let pick = sizes[sizes.length - 1];
  for (let i = 0; i < sizes.length; i++) {
    if (sizes[i] >= px) {
      pick = sizes[i];
      break;
    }
  }
  const t = template.replace("{size}", String(pick));
  if (/^https?:\/\//.test(t) || t.indexOf("//") === 0) return t;
  return settings.subfolder && t.indexOf(settings.subfolder + "/") !== 0
    ? settings.subfolder + t
    : t;
}

export function avatar(
  template: string | null | undefined,
  size: number,
  cls = "avatar",
  online = false
): SafeHtml {
  const src = avatarUrl(template, size);
  if (!src)
    return html`<span
      class="${cls} avatar-blank"
      style="width:${size}px;height:${size}px"
    ></span>`;
  return html`<img
    class="${cls}${online ? " online" : ""}"
    src="${src}"
    width="${size}"
    height="${size}"
    alt=""
    loading="lazy"
  />`;
}
