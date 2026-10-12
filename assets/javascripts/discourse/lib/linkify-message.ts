import { htmlSafe, type SafeString } from "@ember/template";
import { escapeExpression } from "discourse/lib/utilities";

// Escapes a moderator-set message, turns http(s) URLs into links, keeps
// line breaks, and returns a trusted HTML string. Shared by the precheck
// confirmation dialog and the category prompt preview so both render a
// message the same way.
export function messageToHtml(text: string | null | undefined): SafeString {
  const linked = escapeExpression(text || "").replace(
    /(https?:\/\/[^\s<]+)/g,
    (url) =>
      `<a href="${url}" target="_blank" rel="noopener noreferrer">${url}</a>`
  );
  return htmlSafe(linked.replace(/\r?\n/g, "<br>"));
}
