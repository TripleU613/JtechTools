// Categories, with their subcategories one step down.

import { errorMessage } from "../api.ts";
import { swr } from "../cache.ts";
import { html, type SafeHtml } from "../html.ts";
import { focusContent } from "../nav.ts";
import { href, type RouteContext } from "../router.ts";
import {
  addCategories,
  category,
  categoryName,
  categoryPath,
  colour,
} from "../site.ts";
import { count } from "../format.ts";
import { icon } from "../ui/icons.ts";
import { useScreen } from "./common.ts";
import type { BootCategory } from "../config.ts";

interface CategoryJson extends BootCategory {
  topics_week?: number;
  topics_month?: number;
  subcategory_list?: CategoryJson[];
}

function row(c: CategoryJson): SafeHtml {
  const subs = (c.subcategory_ids || [])
    .map((id) => category(id))
    .filter((x): x is BootCategory => !!x);
  const recent = c.topics_week
    ? `${c.topics_week} this week`
    : c.topics_month
      ? `${c.topics_month} this month`
      : "";
  const target = subs.length
    ? categoryPath(c) + "/subcategories"
    : categoryPath(c);
  return html`<li>
    <a class="row category" href="${href(target)}" data-key="c${c.id}">
      <span class="edge" style="background:${colour(c.color)}"></span>
      <div class="row-main">
        <div class="row-title">
          ${c.read_restricted ? icon("lock", "st") : ""}${c.name}
        </div>
        ${c.description_text
          ? html`<div class="row-excerpt">${c.description_text}</div>`
          : ""}
        <div class="row-meta">
          <span>${count(c.topic_count)} topics</span>${recent
            ? html`<span>${recent}</span>`
            : ""}${subs.length
            ? html`<span>${subs.length} subcategories</span>`
            : ""}
        </div>
      </div>
      <span class="chev">${icon("back", "flip")}</span>
    </a>
  </li>`;
}

export function renderCategories(
  ctx: RouteContext,
  parentId: number | null
): Promise<void> {
  const s = useScreen();
  const parent = parentId ? category(parentId) : null;
  s.title(parent ? categoryName(parent) : "Categories", {
    back: true,
    sub: parent ? "Subcategories" : "",
  });
  s.loading();
  const path = parent
    ? `/categories.json?parent_category_id=${parent.id}`
    : "/categories.json";
  let first = true;
  return swr<{ category_list?: { categories: CategoryJson[] } }>(path, (d) => {
    const cats = (d.category_list && d.category_list.categories) || [];
    addCategories(cats);
    for (let i = 0; i < cats.length; i++)
      if (cats[i].subcategory_list) addCategories(cats[i].subcategory_list);
    const rows: SafeHtml[] = [];
    if (parent) {
      rows.push(
        html`<li>
          <a
            class="row category all"
            href="${href(categoryPath(parent))}"
            data-key="c-all"
          >
            <span
              class="edge"
              style="background:${colour(parent.color)}"
            ></span>
            <div class="row-main">
              <div class="row-title">All of ${parent.name}</div>
            </div>
            <span class="chev">${icon("back", "flip")}</span></a
          >
        </li>`
      );
    }
    for (let i = 0; i < cats.length; i++) {
      if (parent && cats[i].id === parent.id) continue;
      rows.push(row(cats[i]));
    }
    s.render(
      html`<ul class="rows categories">
        ${rows}
      </ul>`
    );
    if (first && !ctx.restore) focusContent(".row");
    first = false;
  }).catch((e: unknown) => s.error(errorMessage(e)));
}

export function categoriesRoute(ctx: RouteContext): Promise<void> {
  return renderCategories(ctx, null);
}
