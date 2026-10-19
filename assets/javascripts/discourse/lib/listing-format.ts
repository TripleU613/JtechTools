import { get } from "@ember/object";
import type Composer from "discourse/models/composer";
import type { ListingCardFormat } from "./listing-card.ts";

export interface ListingChoice {
  multiple: boolean;
  options: string[];
  // Options that need the details box filled in when picked (Pickup: where).
  details?: string[];
}

export interface ListingTopicFields {
  listing_format_topic?: boolean;
  listing_format_card?: ListingCardFormat;
  listing_format_fields?: string[];
  listing_format_choices?: Record<string, ListingChoice>;
  listing_format_editor_field?: string;
  listing_format_optional_fields?: string[];
}

// What the reply form needs from the topic, copied onto the composer when
// it opens.
export interface ListingSetup {
  fields: string[];
  choices: Record<string, ListingChoice>;
  // The section the editor fills (pictures); null when the editor's text
  // goes after the sections instead.
  editorField: string | null;
  // Sections that may be left empty; left out of the post when they are.
  optional: string[];
}

// The composer model as the listing form uses it. The listing* properties
// are set with Ember's `set`, so they're read with `get` to stay reactive.
export type ListingComposer = Composer & {
  action?: string;
  reply?: string;
  topic?: ListingTopicFields | null;
  listing?: ListingSetup | null;
  listingValues?: Record<string, string> | null;
  listingPicked?: Record<string, string[]> | null;
  // The editor's own text while a save is under way, put back if it fails.
  listingBody?: string | null;
};

export function listingSetup(model: ListingComposer): ListingSetup | null {
  return (get(model, "listing") as ListingSetup | null | undefined) ?? null;
}

function sectionValue(
  model: ListingComposer,
  setup: ListingSetup,
  field: string
): string {
  if (field === setup.editorField) {
    return (model.reply ?? "").trim();
  }
  const picked = model.listingPicked?.[field] ?? [];
  const options = setup.choices[field]?.options ?? [];
  // In the options' own order, whatever order they were ticked in.
  const chosen = options.filter((option) => picked.includes(option));
  const text = (model.listingValues?.[field] ?? "").trim();
  return [chosen.join(", "), text].filter(Boolean).join("\n");
}

// Picked options that need details, while the section's box is empty.
export function missingDetails(
  model: ListingComposer,
  field: string
): string[] {
  const setup = listingSetup(model);
  const needs = setup?.choices[field]?.details ?? [];
  if (!needs.length || (model.listingValues?.[field] ?? "").trim()) {
    return [];
  }
  const picked = model.listingPicked?.[field] ?? [];
  return needs.filter((option) => picked.includes(option));
}

export function missingValues(model: ListingComposer): string[] {
  const setup = listingSetup(model);
  if (!setup) {
    return [];
  }
  return setup.fields.filter(
    (field) =>
      !setup.optional.includes(field) && !sectionValue(model, setup, field)
  );
}

// The post as the thread writes it: a heading per section with its
// details under it. Without an editor section, the editor's text follows.
export function assemble(model: ListingComposer): string {
  const setup = listingSetup(model);
  if (!setup) {
    return model.reply ?? "";
  }
  const sections = setup.fields.flatMap((field) => {
    const value = sectionValue(model, setup, field);
    return value || !setup.optional.includes(field)
      ? [`### ${field}\n${value}`]
      : [];
  });
  const body = (model.reply ?? "").trim();
  if (!setup.editorField && body) {
    sections.push(body);
  }
  return sections.join("\n\n");
}
