import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { cancel, type Timer } from "@ember/runloop";
import { service } from "@ember/service";
import { modifier } from "ember-modifier";
import KeyboardShortcutsHelp from "discourse/components/modal/keyboard-shortcuts-help";
import { ajax } from "discourse/lib/ajax";
import discourseDebounce from "discourse/lib/debounce";
import DiscourseURL from "discourse/lib/url";
import Category from "discourse/models/category";
import type Site from "discourse/models/site";
import type User from "discourse/models/user";
import type { CapabilitiesService } from "discourse/services/capabilities";
import type ComposerService from "discourse/services/composer";
import type InterfaceColor from "discourse/services/interface-color";
import type ModalService from "discourse/services/modal";
import type SiteSettingsService from "discourse/services/site-settings";
import DModal from "discourse/ui-kit/d-modal";
import dAvatar from "discourse/ui-kit/helpers/d-avatar";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";
import { colorToggleAvailable, toggleColorMode } from "../lib/jt-color-mode.ts";
import { jtLabel } from "../lib/jt-labels.ts";
import { CORE_SHORTCUTS, JT_SHORTCUTS } from "../lib/jt-shortcuts.ts";

const t = (key: string, opts?: Record<string, unknown>): string =>
  jtLabel(`cmdk.${key}`, opts);

const LIMITS = { commands: 5, categories: 4, topics: 6, users: 3 };

type CommandMenuUser = User & { can_create_topic?: boolean };

interface CommandMenuSiteSettings {
  tagging_enabled: boolean;
  min_search_term_length: number;
}

// A loaded Category or a category from a /search/query response
interface MenuCategory {
  id: number;
  name: string;
  slug: string;
  url?: string;
  parent_category_id?: number | null;
  parentCategory?: { id: number; name: string } | null;
}

interface SearchTopic {
  id: number;
  slug: string;
  title: string;
  category_id: number;
}

interface SearchUser {
  username: string;
  name?: string | null;
  avatar_template: string;
}

// The parts of a /search/query response read here
interface SearchResults {
  categories?: MenuCategory[];
  topics?: SearchTopic[];
  users?: SearchUser[];
  grouped_search_result?: { extra?: { categories?: MenuCategory[] } };
}

interface Command {
  icon: string;
  label: string;
  keywords?: string;
  // keyboard shortcut, as bound: "g l", "shift+b" (lib/jt-shortcuts)
  keys?: string;
  url?: string;
  run?: () => unknown;
}

interface MenuEntry {
  group: string;
  label: string;
  icon?: string;
  keywords?: string;
  keys?: string;
  hint?: string | null;
  url?: string;
  user?: SearchUser;
  run?: () => unknown;
}

type MenuItem = MenuEntry & { index: number };

interface MenuGroup {
  key: string;
  label: string | null;
  items: MenuItem[];
}

interface JtCommandMenuSignature {
  Args: {
    closeModal: () => void;
  };
}

// ⌘K / Ctrl+K: jump to pages, categories, topics and people, or run an
// action, from anywhere. Opened by api-initializers/jt-command-menu.
export default class JtCommandMenu extends Component<JtCommandMenuSignature> {
  @service declare capabilities: CapabilitiesService;
  @service declare currentUser: CommandMenuUser | null;
  @service declare site: Site & { can_search: boolean };
  @service declare siteSettings: SiteSettingsService & CommandMenuSiteSettings;
  @service declare composer: ComposerService;
  @service declare interfaceColor: InterfaceColor;
  @service declare modal: ModalService;

  @tracked query = "";
  @tracked selected = 0;
  @tracked results: SearchResults | null = null; // /search/query response for `resultsFor`
  @tracked resultsFor = "";
  @tracked loading = false;

  focusInput = modifier((el: HTMLElement) => {
    el.focus();
  });

  keepInView = modifier((el: HTMLElement, [isSelected]: [boolean]) => {
    if (isSelected) {
      el.scrollIntoView({ block: "nearest" });
    }
  });

  isSelected = (index: number): boolean => index === this.selected;

  // Shortcut keys beside a command, as keycaps: "g l" → g l, "shift+b" → ⇧ B,
  // "mod+shift+k" → ⌘ ⇧ K (Ctrl Shift K off a Mac)
  keysFor = (item: MenuEntry): string[] | null => {
    if (!item.keys || !this.capabilities.hasKeyboard) {
      return null;
    }
    const apple = this.capabilities.isApple;
    const names: Record<string, string> = {
      mod: apple ? "⌘" : "Ctrl",
      shift: apple ? "⇧" : "Shift",
    };
    return item.keys.split(" ").flatMap((combo) => {
      const keys = combo.split("+");
      return keys.length > 1
        ? keys.map((key) => names[key] ?? key.toUpperCase())
        : keys;
    });
  };

  #searchTimer: Timer | null = null;

  willDestroy() {
    super.willDestroy();
    cancel(this.#searchTimer);
  }

  // The full hint ("…or type a command") is cut off on a phone's width; touch
  // screens get the sidebar's short label instead
  get placeholder(): string {
    return t(this.capabilities.hasKeyboard ? "placeholder" : "sidebar_label");
  }

  get commands(): MenuEntry[] {
    const user = this.currentUser;
    const list: (Command | false | null | undefined)[] = [
      user?.can_create_topic &&
        !this.site.isReadOnly && {
          icon: "plus",
          label: t("new_topic"),
          keywords: "create post write",
          keys: CORE_SHORTCUTS.new_topic,
          run: () => this.composer.openNewTopic({}),
        },
      {
        icon: "list",
        label: t("latest"),
        keys: CORE_SHORTCUTS.latest,
        url: "/latest",
      },
      user && {
        icon: "bolt",
        label: t("new"),
        keys: CORE_SHORTCUTS.new,
        url: "/new",
      },
      user && {
        icon: "circle-dot",
        label: t("unread"),
        keys: CORE_SHORTCUTS.unread,
        url: "/unread",
      },
      {
        icon: "arrow-trend-up",
        label: t("top"),
        keys: CORE_SHORTCUTS.top,
        url: "/top",
      },
      {
        icon: "layer-group",
        label: t("categories"),
        keys: CORE_SHORTCUTS.categories,
        url: "/categories",
      },
      this.siteSettings.tagging_enabled && {
        icon: "tag",
        label: t("tags"),
        keys: JT_SHORTCUTS.tags,
        url: "/tags",
      },
      // the search page with its filters open, where core's own search
      // menu only gets to after a search
      this.site.can_search && {
        icon: "sliders",
        label: t("advanced_search"),
        keywords: "filters find",
        keys: JT_SHORTCUTS.advanced_search,
        url: "/search?expanded=true",
      },
      user && {
        icon: "bookmark",
        label: t("bookmarks"),
        keys: CORE_SHORTCUTS.bookmarks,
        url: "/my/activity/bookmarks",
      },
      user && {
        icon: "envelope",
        label: t("messages"),
        keys: CORE_SHORTCUTS.messages,
        url: "/my/messages",
      },
      user && {
        icon: "bell",
        label: t("notifications"),
        keys: JT_SHORTCUTS.notifications,
        url: "/my/notifications",
      },
      // the profile's activity, where core's g p goes too
      user && {
        icon: "user",
        label: t("profile"),
        keys: CORE_SHORTCUTS.profile,
        url: "/my/activity",
      },
      user && {
        icon: "gear",
        label: t("preferences"),
        keywords: "settings account",
        keys: JT_SHORTCUTS.preferences,
        url: "/my/preferences",
      },
      colorToggleAvailable(this.interfaceColor) && {
        icon: "circle-half-stroke",
        label: t("toggle_theme"),
        keywords: "dark light mode appearance color",
        keys: JT_SHORTCUTS.toggle_theme,
        run: () => toggleColorMode(this.interfaceColor),
      },
      this.capabilities.hasKeyboard && {
        icon: "keyboard",
        label: t("shortcuts"),
        keywords: "keys hotkeys help",
        keys: CORE_SHORTCUTS.shortcuts,
        run: () => this.modal.show(KeyboardShortcutsHelp, undefined),
      },
      // Only on lists that offer it (core's header button, hidden on cards)
      document.querySelector("button.bulk-select") && {
        icon: "list-check",
        label: t("bulk_select"),
        keywords: "select multiple topics bulk",
        keys: CORE_SHORTCUTS.bulk_select,
        run: () =>
          document
            .querySelector<HTMLButtonElement>("button.bulk-select")
            ?.click(),
      },
      user?.staff && {
        icon: "wrench",
        label: t("admin"),
        keys: JT_SHORTCUTS.admin,
        url: "/admin",
      },
    ];
    return list
      .filter((c): c is Command => Boolean(c))
      .map((c) => ({ ...c, group: "commands" }));
  }

  get term(): string {
    return this.query.trim().toLowerCase();
  }

  // Categories load lazily on this forum, so the client only knows some of
  // them: match the loaded ones instantly, then add the server's matches.
  get categoryItems(): MenuEntry[] {
    if (!this.term) {
      return [];
    }
    const seen = new Set<number>();
    const loaded = this.filtered<MenuCategory>(
      this.site.categories || [],
      (c) => c.name,
      (c) => c.parentCategory?.name || ""
    );
    const remote =
      this.resultsFor === this.term ? this.results?.categories || [] : [];
    const items: MenuEntry[] = [];
    for (const c of [...loaded, ...remote]) {
      if (seen.has(c.id) || items.length >= LIMITS.categories) {
        continue;
      }
      seen.add(c.id);
      const parentId = c.parentCategory?.id ?? c.parent_category_id;
      const parent = parentId ? Category.findById(parentId) : null;
      items.push({
        group: "categories",
        icon: "folder",
        label: parent ? `${parent.name} / ${c.name}` : c.name,
        url: c.url || `/c/${c.slug}/${c.id}`,
      });
    }
    return items;
  }

  get searchItems(): MenuEntry[] {
    if (!this.results || this.resultsFor !== this.term) {
      return [];
    }
    const topics = (this.results.topics || [])
      .slice(0, LIMITS.topics)
      .map((topic) => ({
        group: "topics",
        icon: "far-comment",
        label: topic.title,
        hint: Category.findById(topic.category_id)?.name,
        url: `/t/${topic.slug}/${topic.id}`,
      }));
    const users = (this.results.users || [])
      .slice(0, LIMITS.users)
      .map((user) => ({
        group: "users",
        user,
        label: user.username,
        hint: user.name !== user.username ? user.name : null,
        url: `/u/${user.username}`,
      }));
    return [...topics, ...users];
  }

  get fullSearchItem(): MenuEntry[] {
    if (!this.term) {
      return [];
    }
    return [
      {
        group: "search",
        icon: "magnifying-glass",
        label: t("search_for", { term: this.query.trim() }),
        url: `/search?q=${encodeURIComponent(this.query.trim())}`,
      },
    ];
  }

  get items(): MenuItem[] {
    const commands = this.filtered(
      this.commands,
      (c) => c.label,
      (c) => c.keywords || ""
    ).slice(0, this.term ? LIMITS.commands : undefined);
    const all = [
      ...commands,
      ...this.categoryItems,
      ...this.searchItems,
      ...this.fullSearchItem,
    ];
    return all.map((item, index) => ({ ...item, index }));
  }

  get groups(): MenuGroup[] {
    const groups: MenuGroup[] = [];
    for (const item of this.items) {
      let group = groups.at(-1);
      if (group?.key !== item.group) {
        group = {
          key: item.group,
          label: item.group === "search" ? null : t(`group_${item.group}`),
          items: [],
        };
        groups.push(group);
      }
      group.items.push(item);
    }
    return groups;
  }

  get showLoading(): boolean {
    return this.loading && !this.searchItems.length;
  }

  get activeId(): string {
    return `jt-cmdk-item-${this.selected}`;
  }

  // Prefix matches first, then word starts, then anywhere.
  rank(text: string, extra = ""): number | null {
    const hay = text.toLowerCase();
    const term = this.term;
    if (hay.startsWith(term)) {
      return 0;
    }
    if (hay.includes(` ${term}`)) {
      return 1;
    }
    if (hay.includes(term) || extra.toLowerCase().includes(term)) {
      return 2;
    }
    return null;
  }

  filtered<T>(
    items: T[],
    textOf: (item: T) => string,
    extraOf: (item: T) => string = () => ""
  ): T[] {
    if (!this.term) {
      return items;
    }
    return items
      .map((item) => ({ item, r: this.rank(textOf(item), extraOf(item)) }))
      .filter(({ r }) => r !== null)
      .sort((a, b) => a.r - b.r)
      .map(({ item }) => item);
  }

  @action
  onInput(event: Event) {
    this.query = (event.target as HTMLInputElement).value;
    this.selected = 0;
    const min = this.siteSettings.min_search_term_length || 3;
    if (this.site.can_search && this.term.length >= min) {
      this.loading = true;
      // Core's search menu waits as long; anonymous search is rate limited.
      this.#searchTimer = discourseDebounce(this, this.search, this.term, 400);
    } else {
      cancel(this.#searchTimer);
      this.loading = false;
    }
  }

  async search(term: string): Promise<void> {
    if (term !== this.term || this.isDestroying) {
      return;
    }
    try {
      const results: SearchResults = await ajax("/search/query", {
        data: { term },
      });
      // With lazily loaded categories the response carries the ones its
      // topics need, as core's search menu uses them.
      results.grouped_search_result?.extra?.categories?.forEach((category) =>
        this.site.updateCategory(category)
      );
      if (term === this.term && !this.isDestroying) {
        this.results = results;
        this.resultsFor = term;
      }
    } catch {
      // network/search errors: commands and categories still work
    } finally {
      if (term === this.term && !this.isDestroying) {
        this.loading = false;
      }
    }
  }

  @action
  onKeydown(event: KeyboardEvent) {
    const count = this.items.length;
    if (event.key === "ArrowDown" || (event.key === "n" && event.ctrlKey)) {
      event.preventDefault();
      this.selected = count ? (this.selected + 1) % count : 0;
    } else if (
      event.key === "ArrowUp" ||
      (event.key === "p" && event.ctrlKey)
    ) {
      event.preventDefault();
      this.selected = count ? (this.selected - 1 + count) % count : 0;
    } else if (event.key === "Enter" && !event.isComposing) {
      event.preventDefault();
      const item = this.items[this.selected];
      if (item) {
        this.run(item, event);
      }
    }
  }

  @action
  hover(index: number) {
    this.selected = index;
  }

  @action
  run(item: MenuEntry, event?: MouseEvent | KeyboardEvent) {
    const newTab = event?.metaKey || event?.ctrlKey;
    if (item.url && newTab) {
      window.open(item.url, "_blank", "noopener");
      return;
    }
    // The Enter that ran it is let go of on the page it opened: not in that
    // page's field. Core's fields act on Enter's release, and the search
    // page's ran an empty search and shut the filters advanced search opens.
    if (event instanceof KeyboardEvent) {
      document.addEventListener(
        "keyup",
        (up) => {
          if (up.key === "Enter") {
            up.preventDefault();
            up.stopPropagation();
          }
        },
        { capture: true, once: true }
      );
    }
    this.args.closeModal();
    if (item.run) {
      item.run();
    } else if (item.url) {
      DiscourseURL.routeTo(item.url, undefined);
    }
  }

  <template>
    <DModal
      aria-label={{t "sidebar_label"}}
      class="jt-cmdk"
      @bodyClass="jt-cmdk__body"
      @closeModal={{@closeModal}}
      @hideHeader={{true}}
    >
      <div class="jt-cmdk__search">
        {{dIcon "magnifying-glass"}}
        <input
          aria-activedescendant={{this.activeId}}
          aria-controls="jt-cmdk-list"
          aria-expanded="true"
          aria-label={{this.placeholder}}
          autocomplete="off"
          class="jt-cmdk__input"
          dir="auto"
          placeholder={{this.placeholder}}
          role="combobox"
          spellcheck="false"
          type="text"
          value={{this.query}}
          {{on "input" this.onInput}}
          {{on "keydown" this.onKeydown}}
          {{this.focusInput}}
        />
        <button
          aria-label={{i18n "close"}}
          class="jt-cmdk__esc"
          type="button"
          {{on "click" @closeModal}}
        >
          <kbd>esc</kbd>
          {{dIcon "xmark"}}
        </button>
      </div>

      <div class="jt-cmdk__list" id="jt-cmdk-list" role="listbox">
        {{#each this.groups as |group|}}
          <div aria-label={{group.label}} class="jt-cmdk__group" role="group">
            {{#if group.label}}
              <div class="jt-cmdk__group-label">{{group.label}}</div>
            {{/if}}
            {{#each group.items as |item|}}
              {{! listbox > group > option is valid ARIA; the rule only knows listbox }}
              {{! eslint-disable ember/template-require-context-role }}
              <button
                aria-selected={{if (this.isSelected item.index) "true" "false"}}
                class="jt-cmdk__item
                  {{if (this.isSelected item.index) '--active'}}"
                id="jt-cmdk-item-{{item.index}}"
                role="option"
                tabindex="-1"
                type="button"
                {{on "click" (fn this.run item)}}
                {{on "mousemove" (fn this.hover item.index)}}
                {{this.keepInView (this.isSelected item.index)}}
              >
                <span class="jt-cmdk__icon">
                  {{#if item.user}}
                    {{dAvatar item.user imageSize="tiny"}}
                  {{else}}
                    {{dIcon item.icon}}
                  {{/if}}
                </span>
                {{! a topic's title, a name or what was typed: its own direction,
                  so Hebrew in an English menu (or the reverse) keeps its
                  punctuation at its end }}
                <span class="jt-cmdk__label" dir="auto">{{item.label}}</span>
                {{#if item.hint}}
                  <span class="jt-cmdk__hint" dir="auto">{{item.hint}}</span>
                {{/if}}
                {{#let (this.keysFor item) as |keys|}}
                  {{#if keys}}
                    <span aria-hidden="true" class="jt-cmdk__keys">
                      {{#each keys as |key|}}<kbd>{{key}}</kbd>{{/each}}
                    </span>
                  {{/if}}
                {{/let}}
                <span aria-hidden="true" class="jt-cmdk__enter">↵</span>
              </button>
              {{! eslint-enable ember/template-require-context-role }}
            {{/each}}
          </div>
        {{/each}}

        {{#if this.showLoading}}
          <div class="jt-cmdk__status" dir="auto">{{t "searching"}}</div>
        {{/if}}
      </div>

      <div aria-hidden="true" class="jt-cmdk__foot">
        <span><kbd>↑</kbd><kbd>↓</kbd> {{t "navigate"}}</span>
        <span><kbd>↵</kbd> {{t "open"}}</span>
        <span><kbd>ctrl</kbd><kbd>↵</kbd> {{t "new_tab"}}</span>
      </div>
    </DModal>
  </template>
}
