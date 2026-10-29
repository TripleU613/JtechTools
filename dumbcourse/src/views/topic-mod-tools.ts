// This plugin's own topic tools for staff (the full site's shield button in
// the topic admin menu, and its prompt checklist button): the footer
// message, reply approval, the private staff note and its replies, and the
// prompt checklist. Each shows only while its feature is on, which the
// topic's JSON says by carrying the field at all.

import { del, post as apiPost, put } from "../api.ts";
import { timeAgo, truncate } from "../format.ts";
import type { Topic } from "../types.ts";
import {
  actionSheet,
  alertDialog,
  confirmDialog,
  type SheetItem,
} from "../ui/layers.ts";
import type { TopicStaffHooks } from "./topic-staff.ts";
import {
  askText,
  type Choice,
  choose,
  fail,
  isStaffUser,
} from "./staff-common.ts";

interface NoteUser {
  username: string;
  name?: string | null;
}

interface NoteReply {
  id: string;
  raw: string;
  created_at?: string | null;
  author?: NoteUser | null;
}

interface ChecklistItem {
  label: string;
  url?: string;
}

interface PromptChecklist {
  mode: "statement" | "checklist";
  statement: string;
  items: ChecklistItem[];
  frequency: "once" | "every_reply";
  max_tl: number;
  button_label: string;
}

export interface ModTopicFields {
  mod_topic_footer_message?: string | null;
  mod_topic_require_reply_approval?: boolean;
  mod_topic_private_note?: string | null;
  mod_topic_private_note_author?: NoteUser | null;
  mod_topic_private_note_created_at?: string | null;
  mod_topic_private_note_replies?: NoteReply[];
  mod_topic_prompt_checklist?: PromptChecklist | null;
  mod_topic_pinned_post_id?: number | null;
}

function has(t: Topic, field: keyof ModTopicFields): boolean {
  return field in (t as object);
}

function base(t: Topic): string {
  return `/discourse-mod-categories/topic/${t.id}`;
}

const AUDIENCE: Choice[] = [
  { label: "Everyone", value: "4" },
  { label: "Trust level 3 and below", value: "3" },
  { label: "Trust level 2 and below", value: "2" },
  { label: "Trust level 1 and below", value: "1" },
  { label: "Trust level 0 only", value: "0" },
];

export function topicModToolItems(
  t: Topic,
  hooks: TopicStaffHooks
): SheetItem[] {
  if (!isStaffUser()) return [];
  const m = t as Topic & ModTopicFields;
  const items: SheetItem[] = [];

  if (has(t, "mod_topic_footer_message"))
    items.push({
      label: m.mod_topic_footer_message
        ? "Footer message…"
        : "Add footer message…",
      icon: "info",
      hint: m.mod_topic_footer_message
        ? truncate(m.mod_topic_footer_message, 30)
        : undefined,
      run: () => footerMessage(m, hooks),
    });

  if (has(t, "mod_topic_require_reply_approval"))
    items.push({
      label: m.mod_topic_require_reply_approval
        ? "Stop approving replies"
        : "Approve replies first",
      icon: "review",
      run: () =>
        put(base(t), {
          require_reply_approval: !m.mod_topic_require_reply_approval,
        }).then(
          () =>
            hooks.reload(
              m.mod_topic_require_reply_approval
                ? "Replies no longer need approval."
                : "Replies now need approval."
            ),
          fail
        ),
    });

  if (has(t, "mod_topic_private_note"))
    items.push({
      label: m.mod_topic_private_note ? "Staff note…" : "Add staff note…",
      icon: "lock",
      hint: m.mod_topic_private_note
        ? plural(
            (m.mod_topic_private_note_replies || []).length,
            "reply",
            "replies"
          )
        : undefined,
      run: () => noteMenu(m, hooks),
    });

  if (has(t, "mod_topic_prompt_checklist"))
    items.push({
      label: m.mod_topic_prompt_checklist
        ? "Reply checklist…"
        : "Add reply checklist…",
      icon: "check",
      run: () => checklistMenu(m, hooks),
    });

  return items;
}

function plural(n: number, one: string, many: string): string {
  return n + " " + (n === 1 ? one : many);
}

function footerMessage(t: Topic & ModTopicFields, hooks: TopicStaffHooks) {
  askText(
    "Footer message",
    "Shown under the topic to everyone. Leave it empty to remove it.",
    (text) =>
      put(base(t), { footer_message: text }).then(
        () =>
          hooks.reload(
            text ? "Footer message saved." : "Footer message removed."
          ),
        fail
      ),
    { optional: true, value: t.mod_topic_footer_message || "", ok: "Save" }
  );
}

// ── The staff note ─────────────────────────────────────────────────────

function noteText(t: Topic & ModTopicFields): string {
  const lines: string[] = [];
  const author = t.mod_topic_private_note_author;
  lines.push(
    (author ? "@" + author.username : "Staff") +
      (t.mod_topic_private_note_created_at
        ? ", " + timeAgo(t.mod_topic_private_note_created_at) + " ago"
        : "") +
      ":\n" +
      (t.mod_topic_private_note || "")
  );
  (t.mod_topic_private_note_replies || []).forEach((r) =>
    lines.push(
      (r.author ? "@" + r.author.username : "Staff") +
        (r.created_at ? ", " + timeAgo(r.created_at) + " ago" : "") +
        ":\n" +
        r.raw
    )
  );
  return lines.join("\n\n");
}

function noteMenu(t: Topic & ModTopicFields, hooks: TopicStaffHooks): void {
  const write = (label: string, value: string) =>
    askText(
      "Staff note",
      label,
      (text) =>
        put(base(t), { private_note: text }).then(
          () => hooks.reload("Staff note saved."),
          fail
        ),
      { value, ok: "Save" }
    );
  if (!t.mod_topic_private_note) {
    write("Only staff will see it.", "");
    return;
  }
  const replies = t.mod_topic_private_note_replies || [];
  const items: SheetItem[] = [
    {
      label: "Read the note",
      icon: "eye",
      run: () => void alertDialog(noteText(t), "Staff note"),
    },
    {
      label: "Reply to the note",
      icon: "reply",
      run: () =>
        askText("Reply to the note", "Your reply", (text) =>
          apiPost(`${base(t)}/note-reply`, { raw: text }).then(
            () => hooks.reload("Reply added."),
            fail
          )
        ),
    },
    {
      label: "Edit the note",
      icon: "edit",
      run: () =>
        write("Only staff will see it.", t.mod_topic_private_note || ""),
    },
  ];
  replies.forEach((r) =>
    items.push({
      label: "Reply by @" + (r.author ? r.author.username : "staff"),
      hint: truncate(r.raw, 30),
      run: () =>
        actionSheet("Reply by @" + (r.author ? r.author.username : "staff"), [
          {
            label: "Edit",
            icon: "edit",
            run: () =>
              askText(
                "Edit reply",
                "Reply",
                (text) =>
                  put(`${base(t)}/note-reply`, {
                    reply_id: r.id,
                    raw: text,
                  }).then(() => hooks.reload("Reply saved."), fail),
                { value: r.raw, ok: "Save" }
              ),
          },
          {
            label: "Delete",
            icon: "trash",
            danger: true,
            run: () =>
              confirmDialog("Delete this reply?", {
                ok: "Delete",
                danger: true,
              }).then((ok) => {
                if (ok)
                  del(`${base(t)}/note-reply`, { reply_id: r.id }).then(
                    () => hooks.reload("Reply deleted."),
                    fail
                  );
              }),
          },
        ]),
    })
  );
  items.push({
    label: "Delete the note",
    icon: "trash",
    danger: true,
    run: () =>
      confirmDialog("Delete the staff note and its replies?", {
        ok: "Delete",
        danger: true,
      }).then((ok) => {
        if (ok)
          del(`${base(t)}/note`).then(
            () => hooks.reload("Staff note deleted."),
            fail
          );
      }),
  });
  actionSheet("Staff note", items, {
    subtitle: truncate(t.mod_topic_private_note, 80),
  });
}

// ── The reply checklist ────────────────────────────────────────────────

function checklistMenu(
  t: Topic & ModTopicFields,
  hooks: TopicStaffHooks
): void {
  const current = t.mod_topic_prompt_checklist;
  const save = (c: PromptChecklist, message: string) =>
    put(`${base(t)}/prompt-checklist`, {
      mode: c.mode,
      statement: c.statement,
      items: c.items,
      frequency: c.frequency,
      max_tl: c.max_tl,
      button_label: c.button_label,
    }).then(() => hooks.reload(message), fail);

  // Asks the rest (how often, and who), then saves.
  const finish = (c: PromptChecklist) =>
    choose(
      "Ask it",
      [
        {
          label: "Once per person",
          value: "once",
          active: c.frequency === "once",
        },
        {
          label: "Before every reply",
          value: "every_reply",
          active: c.frequency === "every_reply",
        },
      ],
      (frequency) =>
        choose(
          "Ask whom",
          AUDIENCE.map((a) => ({
            label: a.label,
            value: a.value,
            active: a.value === String(c.max_tl),
          })),
          (tl) =>
            save(
              {
                mode: c.mode,
                statement: c.statement,
                items: c.items,
                frequency: frequency === "every_reply" ? "every_reply" : "once",
                max_tl: parseInt(tl, 10),
                button_label: c.button_label,
              },
              "Reply checklist saved."
            )
        )
    );

  const blank: PromptChecklist = current || {
    mode: "checklist",
    statement: "",
    items: [],
    frequency: "once",
    max_tl: 4,
    button_label: "",
  };

  const asStatement = () =>
    askText(
      "Reply checklist",
      "What people agree to before replying",
      (statement) =>
        finish({
          mode: "statement",
          statement,
          items: [],
          frequency: blank.frequency,
          max_tl: blank.max_tl,
          button_label: blank.button_label,
        }),
      { value: blank.mode === "statement" ? blank.statement : "", ok: "Next" }
    );

  const asList = () =>
    askText(
      "Reply checklist",
      "One item per line. People tick each one before replying.",
      (text) => {
        const items = text
          .split(/\n+/)
          .map((line) => line.replace(/^\s*[-*]\s*/, "").replace(/\s+$/, ""))
          .filter((line) => !!line)
          .map((label) => {
            const old = blank.items.filter((i) => i.label === label)[0];
            return { label, url: old && old.url ? old.url : "" };
          });
        finish({
          mode: "checklist",
          statement: "",
          items,
          frequency: blank.frequency,
          max_tl: blank.max_tl,
          button_label: blank.button_label,
        });
      },
      {
        value:
          blank.mode === "checklist"
            ? blank.items.map((i) => i.label).join("\n")
            : "",
        ok: "Next",
      }
    );

  const items: SheetItem[] = [
    {
      label: "A list to tick",
      icon: "check",
      active: !!current && current.mode === "checklist",
      run: asList,
    },
    {
      label: "A statement to agree to",
      icon: "info",
      active: !!current && current.mode === "statement",
      run: asStatement,
    },
  ];
  if (current)
    items.push({
      label: "Remove the checklist",
      icon: "trash",
      danger: true,
      run: () =>
        del(`${base(t)}/prompt-checklist`).then(
          () => hooks.reload("Reply checklist removed."),
          fail
        ),
    });
  actionSheet("Reply checklist", items, {
    subtitle: current
      ? current.mode === "statement"
        ? truncate(current.statement, 80)
        : plural(current.items.length, "item", "items")
      : "Asked before someone replies here.",
  });
}
