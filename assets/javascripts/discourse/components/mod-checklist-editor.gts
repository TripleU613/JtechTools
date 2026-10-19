import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { concat, fn, hash } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import type { ComponentLike } from "@glint/template";
import UntypedComboBox from "select-kit/components/combo-box";
import { eq } from "truth-helpers";
import DButton from "discourse/components/d-button";
import type ToastsService from "discourse/float-kit/services/toasts";
import ageWithTooltip from "discourse/helpers/age-with-tooltip";
import icon from "discourse/helpers/d-icon";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { getURLWithCDN } from "discourse/lib/get-url";
import UntypedEmailGroupUserChooser from "discourse/select-kit/components/email-group-user-chooser";
import type SiteSettings from "discourse/services/site-settings";
import { i18n } from "discourse-i18n";
import type { ChecklistItem } from "../lib/first-post-checklist.ts";
import { trustLevelOptions } from "../lib/trust-level-options.ts";

// Select-kit components are classic components with no Glint signature;
// these give them one so `class` and the args used here type-check.
interface ComboBoxSignature {
  Element: HTMLElement;
  Args: {
    value: string;
    content: { id: string; name: string }[];
    onChange: (value: string) => void;
  };
}
const ComboBox = UntypedComboBox as unknown as ComponentLike<ComboBoxSignature>;

interface EmailGroupUserChooserSignature {
  Element: HTMLElement;
  Args: {
    value: string[];
    onChange: (usernames: string[]) => void;
    options?: { includeGroups?: boolean };
  };
}
const EmailGroupUserChooser =
  UntypedEmailGroupUserChooser as unknown as ComponentLike<EmailGroupUserChooserSignature>;

export interface ChecklistLogEntry {
  username: string | null;
  name: string | null;
  avatar_template: string | null;
  version: number;
  accepted_at: string | null;
  kind: string;
  checklist_id: string | null;
  checklist_name: string | null;
}

interface ChecklistLogRow extends ChecklistLogEntry {
  at: Date | null;
}

interface TargetedChecklistUser {
  id: number;
  username: string;
  name: string | null;
  avatar_template: string;
}

export interface TargetedChecklistData {
  id: string;
  name: string;
  version: number;
  button_label: string;
  updated_at: string | null;
  items: ChecklistItem[];
  user_ids: number[];
  users: TargetedChecklistUser[];
}

// GET /discourse-mod-categories/checklist (and, without `log`/`targeted`,
// the PUT response).
export interface ChecklistConfig {
  version: number;
  items: ChecklistItem[];
  max_tl: number;
  button_label: string;
  updated_at: string | null;
  log?: ChecklistLogEntry[];
  targeted?: TargetedChecklistData[];
}

interface TargetedListResponse {
  targeted?: TargetedChecklistData[];
}

interface ReacceptResponse {
  log?: ChecklistLogEntry[];
}

interface ChecklistEditorSiteSettings {
  mod_targeted_checklists_enabled: boolean;
}

interface ModChecklistEditorSignature {
  Args: { data: ChecklistConfig };
}

// One editable checklist row. Tracked so editing the label/url in place
// re-renders without rebuilding the whole list.
class ChecklistRow {
  @tracked label: string;
  @tracked url: string;

  constructor(label = "", url = "") {
    this.label = label;
    this.url = url;
  }
}

// One editable targeted checklist: its own name, target users, item rows,
// accept-button text and (server-owned) version. Tracked so in-place edits
// re-render without rebuilding the section.
class TargetedChecklist {
  @tracked name: string;
  @tracked usernames: string[];
  @tracked rows: ChecklistRow[];
  @tracked buttonLabel: string;
  @tracked version: number;
  declare id: string | null;

  constructor(data: Partial<TargetedChecklistData> = {}) {
    this.id = data.id || null;
    this.name = data.name || "";
    this.usernames = (data.users || []).map((u) => u.username);
    this.rows = (data.items || []).map(
      (item) => new ChecklistRow(item.label, item.url)
    );
    this.buttonLabel = data.button_label || "";
    this.version = data.version || 0;
  }
}

// The first-post checklist editor (shown in the /mod-checklist modal).
// Staff add, edit, remove, and save the list of items; saving bumps the
// version so every user who already accepted is prompted again. The
// editor also manages targeted checklists and per-user re-accept resets.
export default class ModChecklistEditor extends Component<ModChecklistEditorSignature> {
  @service declare siteSettings: SiteSettings & ChecklistEditorSiteSettings;
  @service declare toasts: ToastsService;

  @tracked rows = (this.args.data.items || []).map(
    (item) => new ChecklistRow(item.label, item.url)
  );

  @tracked version = this.args.data.version || 0;
  @tracked maxTl = String(this.args.data.max_tl ?? 2);
  @tracked buttonLabel = this.args.data.button_label || "";
  @tracked saving = false;
  @tracked saved = false;
  @tracked onlyCurrentVersion = false;
  @tracked logSearch = "";
  @tracked logKind = "all";
  @tracked logEntries: ChecklistLogEntry[] = this.args.data.log || [];
  @tracked targeted = (this.args.data.targeted || []).map(
    (t) => new TargetedChecklist(t)
  );
  audienceOptions = trustLevelOptions(false);

  // Arrow property: the template calls this as a bare function helper,
  // which strips the receiver.
  logAvatar = (entry: ChecklistLogEntry): string =>
    getURLWithCDN(entry.avatar_template.replace("{size}", "48"));

  // Index of the last checklist row, used to disable the down button.
  get lastRowIndex(): number {
    return this.rows.length - 1;
  }

  // The acceptance audit log, newest first, with the ISO timestamp parsed
  // to a Date for relative-time display. Refreshed in place after a
  // require-re-accept reset.
  get log(): ChecklistLogRow[] {
    return this.logEntries.map((entry) => ({
      ...entry,
      at: entry.accepted_at ? new Date(entry.accepted_at) : null,
    }));
  }

  // The log narrowed by the version checkbox, the checklist selector and
  // the name search, in that order.
  get filteredLog(): ChecklistLogRow[] {
    let entries = this.log;
    if (this.onlyCurrentVersion) {
      entries = entries.filter((entry) => entry.version === this.version);
    }
    if (this.logKind !== "all") {
      entries = entries.filter(
        (entry) => this.logKindOf(entry) === this.logKind
      );
    }
    const search = this.logSearch.trim().toLowerCase();
    if (search) {
      entries = entries.filter((entry) =>
        [entry.username, entry.name].some((field) =>
          (field || "").toLowerCase().includes(search)
        )
      );
    }
    return entries;
  }

  // One selector entry per distinct checklist seen in the log; hidden when
  // everything is global.
  get logKindOptions(): { id: string; name: string }[] {
    const seen = new Map<string, string>();
    this.log.forEach((entry) => {
      seen.set(this.logKindOf(entry), this.logKindLabel(entry));
    });
    const options = [
      {
        id: "all",
        name: i18n(
          "discourse_mod_categories.first_post_checklist.log_kind_all"
        ),
      },
    ];
    seen.forEach((name, id) => options.push({ id, name }));
    return options;
  }

  get showLogKindFilter(): boolean {
    return this.logKindOptions.length > 2;
  }

  logKindOf(entry: ChecklistLogEntry): string {
    return entry.checklist_id ? `targeted:${entry.checklist_id}` : entry.kind;
  }

  logKindLabel(entry: ChecklistLogEntry): string {
    if (entry.checklist_name) {
      return entry.checklist_name;
    }
    if (entry.kind === "topic") {
      return i18n(
        "discourse_mod_categories.first_post_checklist.log_kind_topic"
      );
    }
    return i18n(
      "discourse_mod_categories.first_post_checklist.log_kind_global"
    );
  }

  @action
  updateLogSearch(event: Event) {
    this.logSearch = (event.target as HTMLInputElement).value;
  }

  @action
  updateLogKind(value: string) {
    this.logKind = value;
  }

  @action
  toggleLogFilter(event: Event) {
    this.onlyCurrentVersion = (event.target as HTMLInputElement).checked;
  }

  @action
  addRow() {
    this.rows = [...this.rows, new ChecklistRow()];
    this.saved = false;
  }

  @action
  removeRow(row: ChecklistRow) {
    this.rows = this.rows.filter((r) => r !== row);
    this.saved = false;
  }

  // Swap a row with the one before/after it. Reassigning this.rows
  // re-renders the list; like addRow/removeRow it marks the editor unsaved.
  moveRow(row: ChecklistRow, delta: number) {
    const index = this.rows.indexOf(row);
    const target = index + delta;
    if (index === -1 || target < 0 || target >= this.rows.length) {
      return;
    }
    const next = [...this.rows];
    next[index] = next[target];
    next[target] = row;
    this.rows = next;
    this.saved = false;
  }

  @action
  moveRowUp(row: ChecklistRow) {
    this.moveRow(row, -1);
  }

  @action
  moveRowDown(row: ChecklistRow) {
    this.moveRow(row, 1);
  }

  @action
  updateLabel(row: ChecklistRow, event: Event) {
    row.label = (event.target as HTMLInputElement).value;
    this.saved = false;
  }

  @action
  updateUrl(row: ChecklistRow, event: Event) {
    row.url = (event.target as HTMLInputElement).value;
    this.saved = false;
  }

  @action
  updateMaxTl(value: string) {
    this.maxTl = value;
    this.saved = false;
  }

  @action
  updateButtonLabel(event: Event) {
    this.buttonLabel = (event.target as HTMLInputElement).value;
    this.saved = false;
  }

  // --- Require re-accept ----------------------------------------------

  // Reset one logged user so the forum-wide checklist is shown again on
  // their next post, then refresh the log from the server response.
  @action
  async requireReaccept(entry: ChecklistLogEntry) {
    try {
      const result: ReacceptResponse = await ajax(
        "/discourse-mod-categories/checklist/require-reaccept",
        { type: "POST", data: { username: entry.username } }
      );
      if (result.log) {
        this.logEntries = result.log;
      }
      this.toasts.success({
        duration: 3000,
        data: {
          message: i18n(
            "discourse_mod_categories.first_post_checklist.reaccept_done",
            { username: entry.username }
          ),
        },
      });
    } catch (error) {
      popupAjaxError(error);
    }
  }

  // --- Targeted checklists --------------------------------------------

  @action
  addTargeted() {
    this.targeted = [...this.targeted, new TargetedChecklist()];
  }

  @action
  updateTargetedName(checklist: TargetedChecklist, event: Event) {
    checklist.name = (event.target as HTMLInputElement).value;
  }

  @action
  updateTargetedUsers(checklist: TargetedChecklist, usernames: string[]) {
    checklist.usernames = usernames;
  }

  @action
  updateTargetedButtonLabel(checklist: TargetedChecklist, event: Event) {
    checklist.buttonLabel = (event.target as HTMLInputElement).value;
  }

  @action
  addTargetedRow(checklist: TargetedChecklist) {
    checklist.rows = [...checklist.rows, new ChecklistRow()];
  }

  @action
  removeTargetedRow(checklist: TargetedChecklist, row: ChecklistRow) {
    checklist.rows = checklist.rows.filter((r) => r !== row);
  }

  @action
  updateTargetedLabel(row: ChecklistRow, event: Event) {
    row.label = (event.target as HTMLInputElement).value;
  }

  @action
  updateTargetedUrl(row: ChecklistRow, event: Event) {
    row.url = (event.target as HTMLInputElement).value;
  }

  // Create or update a targeted checklist, then replace the section's
  // state with the server's canonical list (ids, bumped versions).
  @action
  async saveTargeted(checklist: TargetedChecklist) {
    this.saving = true;
    const data = {
      name: checklist.name,
      user_ids: checklist.usernames,
      button_label: checklist.buttonLabel,
      items: checklist.rows.map((r) => ({ label: r.label, url: r.url })),
    };
    try {
      const result: TargetedListResponse = checklist.id
        ? await ajax(
            `/discourse-mod-categories/checklist/targeted/${checklist.id}`,
            { type: "PUT", data }
          )
        : await ajax("/discourse-mod-categories/checklist/targeted", {
            type: "POST",
            data,
          });
      this.targeted = (result.targeted || []).map(
        (t) => new TargetedChecklist(t)
      );
      this.toasts.success({
        duration: 3000,
        data: {
          message: i18n(
            "discourse_mod_categories.first_post_checklist.targeted_saved"
          ),
        },
      });
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.saving = false;
    }
  }

  @action
  async deleteTargeted(checklist: TargetedChecklist) {
    // An unsaved (id-less) checklist is just dropped client-side.
    if (!checklist.id) {
      this.targeted = this.targeted.filter((c) => c !== checklist);
      return;
    }
    try {
      const result: TargetedListResponse = await ajax(
        `/discourse-mod-categories/checklist/targeted/${checklist.id}`,
        { type: "DELETE" }
      );
      this.targeted = (result.targeted || []).map(
        (t) => new TargetedChecklist(t)
      );
    } catch (error) {
      popupAjaxError(error);
    }
  }

  @action
  async save() {
    this.saving = true;

    try {
      const result: ChecklistConfig = await ajax(
        "/discourse-mod-categories/checklist",
        {
          type: "PUT",
          data: {
            items: this.rows.map((r) => ({ label: r.label, url: r.url })),
            max_tl: this.maxTl,
            button_label: this.buttonLabel,
          },
        }
      );
      this.version = result.version;
      this.maxTl = String(result.max_tl ?? 2);
      this.buttonLabel = result.button_label || "";
      this.rows = (result.items || []).map(
        (item) => new ChecklistRow(item.label, item.url)
      );
      this.saved = true;
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.saving = false;
    }
  }

  <template>
    <div class="mod-checklist-page">
      {{#if this.version}}
        <p class="mod-checklist-version">
          {{i18n
            "discourse_mod_categories.first_post_checklist.current_version"
            count=this.version
          }}
        </p>
      {{/if}}
      {{#if this.rows.length}}
        <div class="mod-checklist-rows">
          {{#each this.rows as |row index|}}
            <div class="mod-checklist-row">
              <input
                class="mod-checklist-row-label"
                placeholder={{i18n
                  "discourse_mod_categories.first_post_checklist.item_label"
                }}
                type="text"
                value={{row.label}}
                {{on "input" (fn this.updateLabel row)}}
              />
              <input
                class="mod-checklist-row-url"
                placeholder={{i18n
                  "discourse_mod_categories.first_post_checklist.item_url"
                }}
                type="text"
                value={{row.url}}
                {{on "input" (fn this.updateUrl row)}}
              />
              <div class="mod-checklist-row-controls">
                <DButton
                  class="btn-flat mod-checklist-move-up"
                  @action={{fn this.moveRowUp row}}
                  @disabled={{eq index 0}}
                  @icon="arrow-up"
                  @title="discourse_mod_categories.first_post_checklist.move_up_item"
                />
                <DButton
                  class="btn-flat mod-checklist-move-down"
                  @action={{fn this.moveRowDown row}}
                  @disabled={{eq index this.lastRowIndex}}
                  @icon="arrow-down"
                  @title="discourse_mod_categories.first_post_checklist.move_down_item"
                />
                <DButton
                  class="btn-flat mod-checklist-remove"
                  @action={{fn this.removeRow row}}
                  @icon="trash-can"
                  @title="discourse_mod_categories.first_post_checklist.remove_item"
                />
              </div>
            </div>
          {{/each}}
        </div>
      {{/if}}

      <button
        class="mod-checklist-add-inline"
        type="button"
        {{on "click" this.addRow}}
      >
        {{icon "plus"}}
        {{i18n "discourse_mod_categories.first_post_checklist.add_item"}}
      </button>

      <div class="mod-checklist-field-grid">
        <div class="mod-checklist-field">
          <label class="mod-checklist-field-label">
            {{i18n
              "discourse_mod_categories.first_post_checklist.audience_label"
            }}
          </label>
          <ComboBox
            class="mod-checklist-audience"
            @content={{this.audienceOptions}}
            @onChange={{this.updateMaxTl}}
            @value={{this.maxTl}}
          />
        </div>

        <div class="mod-checklist-field">
          <label class="mod-checklist-field-label">
            {{i18n
              "discourse_mod_categories.first_post_checklist.button_label_label"
            }}
          </label>
          <input
            class="mod-checklist-button-label"
            placeholder={{i18n
              "discourse_mod_categories.first_post_checklist.button_label_placeholder"
            }}
            type="text"
            value={{this.buttonLabel}}
            {{on "input" this.updateButtonLabel}}
          />
        </div>
      </div>

      <div class="mod-checklist-editor-actions">
        <DButton
          class="btn-primary mod-checklist-save"
          @action={{this.save}}
          @disabled={{this.saving}}
          @label="discourse_mod_categories.first_post_checklist.save"
        />
        {{#if this.saved}}
          <span class="mod-checklist-saved">
            {{icon "check"}}
            {{i18n "discourse_mod_categories.first_post_checklist.saved"}}
          </span>
        {{/if}}
      </div>

      <section class="mod-checklist-log">
        <div class="mod-checklist-log-header">
          <h3 class="mod-checklist-log-title">
            {{i18n "discourse_mod_categories.first_post_checklist.log_title"}}
            <span class="mod-checklist-log-count">
              {{this.filteredLog.length}}
            </span>
          </h3>
          {{#if this.version}}
            <label class="mod-checklist-log-filter">
              <input
                checked={{this.onlyCurrentVersion}}
                type="checkbox"
                {{on "change" this.toggleLogFilter}}
              />
              {{i18n
                "discourse_mod_categories.first_post_checklist.log_filter_current"
                count=this.version
              }}
            </label>
          {{/if}}
        </div>
        <div class="mod-checklist-log-controls">
          <input
            class="mod-checklist-log-search"
            placeholder={{i18n
              "discourse_mod_categories.first_post_checklist.log_search_placeholder"
            }}
            type="search"
            value={{this.logSearch}}
            {{on "input" this.updateLogSearch}}
          />
          {{#if this.showLogKindFilter}}
            <ComboBox
              class="mod-checklist-log-kind"
              @content={{this.logKindOptions}}
              @onChange={{this.updateLogKind}}
              @value={{this.logKind}}
            />
          {{/if}}
        </div>
        {{#if this.filteredLog.length}}
          {{! the table scrolls on its own when it's wider than the modal }}
          <div class="mod-checklist-log-scroll">
            <table class="mod-checklist-log-table">
              <thead>
                <tr>
                  <th>
                    {{i18n
                      "discourse_mod_categories.first_post_checklist.log_user"
                    }}
                  </th>
                  <th>
                    {{i18n
                      "discourse_mod_categories.first_post_checklist.log_checklist"
                    }}
                  </th>
                  <th>
                    {{i18n
                      "discourse_mod_categories.first_post_checklist.log_version"
                    }}
                  </th>
                  <th>
                    {{i18n
                      "discourse_mod_categories.first_post_checklist.log_when"
                    }}
                  </th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                {{#each this.filteredLog as |entry|}}
                  <tr>
                    <td>
                      <a
                        class="mod-checklist-log-user"
                        data-user-card={{entry.username}}
                        href={{concat "/u/" entry.username}}
                      >
                        {{#if entry.avatar_template}}
                          <img
                            alt=""
                            class="mod-checklist-log-avatar"
                            src={{this.logAvatar entry}}
                          />
                        {{/if}}
                        {{entry.username}}
                      </a>
                    </td>
                    <td>
                      <span class="mod-checklist-log-kind-chip">
                        {{this.logKindLabel entry}}
                      </span>
                    </td>
                    <td>{{entry.version}}</td>
                    <td>{{ageWithTooltip entry.at}}</td>
                    <td>
                      <DButton
                        class="btn-flat mod-checklist-require-reaccept"
                        @action={{fn this.requireReaccept entry}}
                        @label="discourse_mod_categories.first_post_checklist.require_reaccept"
                      />
                    </td>
                  </tr>
                {{/each}}
              </tbody>
            </table>
          </div>
        {{else}}
          <p class="mod-checklist-log-empty">
            {{i18n "discourse_mod_categories.first_post_checklist.log_empty"}}
          </p>
        {{/if}}
      </section>

      {{#if this.siteSettings.mod_targeted_checklists_enabled}}
        <section class="mod-checklist-targeted">
          <h3 class="mod-checklist-targeted-title">
            {{i18n
              "discourse_mod_categories.first_post_checklist.targeted_title"
            }}
          </h3>
          {{#each this.targeted as |checklist|}}
            <div class="mod-checklist-targeted-item">
              {{#if checklist.version}}
                <p class="mod-checklist-version">
                  {{i18n
                    "discourse_mod_categories.first_post_checklist.current_version"
                    count=checklist.version
                  }}
                </p>
              {{/if}}

              <div class="mod-checklist-field">
                <label class="mod-checklist-field-label">
                  {{i18n
                    "discourse_mod_categories.first_post_checklist.targeted_name_label"
                  }}
                </label>
                <input
                  class="mod-checklist-targeted-name"
                  type="text"
                  value={{checklist.name}}
                  {{on "input" (fn this.updateTargetedName checklist)}}
                />
              </div>

              <div class="mod-checklist-field">
                <label class="mod-checklist-field-label">
                  {{i18n
                    "discourse_mod_categories.first_post_checklist.targeted_users_label"
                  }}
                </label>
                <EmailGroupUserChooser
                  class="mod-checklist-targeted-users"
                  @onChange={{fn this.updateTargetedUsers checklist}}
                  @options={{hash includeGroups=false}}
                  @value={{checklist.usernames}}
                />
              </div>

              {{#if checklist.rows.length}}
                <div class="mod-checklist-rows">
                  {{#each checklist.rows as |row|}}
                    <div class="mod-checklist-row">
                      <input
                        class="mod-checklist-row-label"
                        placeholder={{i18n
                          "discourse_mod_categories.first_post_checklist.item_label"
                        }}
                        type="text"
                        value={{row.label}}
                        {{on "input" (fn this.updateTargetedLabel row)}}
                      />
                      <input
                        class="mod-checklist-row-url"
                        placeholder={{i18n
                          "discourse_mod_categories.first_post_checklist.item_url"
                        }}
                        type="text"
                        value={{row.url}}
                        {{on "input" (fn this.updateTargetedUrl row)}}
                      />
                      <DButton
                        class="btn-flat mod-checklist-remove"
                        @action={{fn this.removeTargetedRow checklist row}}
                        @icon="trash-can"
                        @title="discourse_mod_categories.first_post_checklist.remove_item"
                      />
                    </div>
                  {{/each}}
                </div>
              {{/if}}

              <div class="mod-checklist-field">
                <label class="mod-checklist-field-label">
                  {{i18n
                    "discourse_mod_categories.first_post_checklist.button_label_label"
                  }}
                </label>
                <input
                  class="mod-checklist-button-label"
                  placeholder={{i18n
                    "discourse_mod_categories.first_post_checklist.button_label_placeholder"
                  }}
                  type="text"
                  value={{checklist.buttonLabel}}
                  {{on "input" (fn this.updateTargetedButtonLabel checklist)}}
                />
              </div>

              <div class="mod-checklist-editor-actions">
                <DButton
                  class="mod-checklist-targeted-add-item"
                  @action={{fn this.addTargetedRow checklist}}
                  @icon="plus"
                  @label="discourse_mod_categories.first_post_checklist.add_item"
                />
                <DButton
                  class="btn-primary mod-checklist-targeted-save"
                  @action={{fn this.saveTargeted checklist}}
                  @disabled={{this.saving}}
                  @label="discourse_mod_categories.first_post_checklist.targeted_save"
                />
                <DButton
                  class="btn-danger mod-checklist-targeted-delete"
                  @action={{fn this.deleteTargeted checklist}}
                  @icon="trash-can"
                  @label="discourse_mod_categories.first_post_checklist.targeted_delete"
                />
              </div>
            </div>
          {{/each}}

          <DButton
            class="mod-checklist-targeted-add"
            @action={{this.addTargeted}}
            @icon="plus"
            @label="discourse_mod_categories.first_post_checklist.targeted_add"
          />
        </section>
      {{/if}}
    </div>
  </template>
}
