// REQ-PM contact kinds as the client shows them. Mirrors
// lib/discourse_reqpm/kinds.rb, which is where values are validated — this
// file only decides icons, input types and which links to offer.

export const CUSTOM = "custom";

export type ReqpmKindId =
  | "phone"
  | "sms"
  | "whatsapp"
  | "email"
  | "website"
  | "telegram"
  | "signal"
  | "discord"
  | typeof CUSTOM;

export interface ReqpmKindInfo {
  id: ReqpmKindId;
  icon: string;
  input: "tel" | "email" | "url" | "text";
  inputmode: "tel" | "email" | "url" | "text";
}

// What actionFor needs from a contact method.
export interface ReqpmActionable {
  kind: string;
  value?: string | null;
}

export type ReqpmActionLabel =
  | "call"
  | "text"
  | "chat"
  | "email"
  | "visit"
  | "open";

export interface ReqpmAction {
  href: string;
  label: ReqpmActionLabel;
}

// Order is the order of the "add a way to reach you" picker.
export const KINDS: ReqpmKindInfo[] = [
  { id: "phone", icon: "phone", input: "tel", inputmode: "tel" },
  { id: "sms", icon: "comment-sms", input: "tel", inputmode: "tel" },
  {
    id: "whatsapp",
    icon: "fab-whatsapp",
    input: "text",
    inputmode: "text",
  },
  { id: "email", icon: "envelope", input: "email", inputmode: "email" },
  { id: "website", icon: "globe", input: "url", inputmode: "url" },
  { id: "telegram", icon: "fab-telegram", input: "text", inputmode: "text" },
  {
    id: "signal",
    icon: "fab-signal-messenger",
    input: "text",
    inputmode: "text",
  },
  { id: "discord", icon: "fab-discord", input: "text", inputmode: "text" },
  { id: CUSTOM, icon: "far-face-smile", input: "text", inputmode: "text" },
];

const BY_ID: Record<string, ReqpmKindInfo> = Object.fromEntries(
  KINDS.map((k) => [k.id, k])
);

export function kindInfo(id: string | null | undefined): ReqpmKindInfo {
  return BY_ID[id] || BY_ID[CUSTOM];
}

function digits(value: string | null | undefined): string {
  return (value || "").replace(/[^\d]/g, "");
}

// The full international number (country code + digits, no "+"), or null
// when it can't be placed. Mirrors Kinds.with_country_code on the server,
// for numbers saved before that existed: "646-820-1413" with the default
// code 1 → "16468201413". Without this WhatsApp read the leading "64" as
// New Zealand.
export function internationalDigits(
  value: string | null | undefined,
  defaultCode: string | number | null | undefined
): string | null {
  const raw = (value || "").trim();
  const d = digits(raw);
  if (raw.startsWith("+")) {
    return d;
  }
  if (raw.startsWith("00")) {
    return d.slice(2);
  }
  const code = String(defaultCode ?? "").replace(/\D/g, "");
  if (!code || d.startsWith("0")) {
    return null;
  }
  if (d.length === 10) {
    return code + d;
  }
  if (d.startsWith(code) && d.length === 10 + code.length) {
    return d;
  }
  return null;
}

// tel:/sms: target — international when known, otherwise the number as
// typed so a local dial still works.
function dialable(
  value: string,
  defaultCode: string | number | null | undefined
): string {
  const intl = internationalDigits(value, defaultCode);
  return intl ? `+${intl}` : digits(value);
}

function looksLikePhone(value: string): boolean {
  return /^\+?[\d ().-]+$/.test(value || "") && digits(value).length >= 5;
}

export function httpUrl(value: string): string | null {
  try {
    const url = new URL(value);
    return ["http:", "https:"].includes(url.protocol) ? url.href : null;
  } catch {
    return null;
  }
}

// The one-tap action for a contact method, or null when copying is the only
// sensible thing (e.g. a Discord username). Every href is built from a
// fixed scheme plus a value the server has already validated for its kind.
export function actionFor(
  method: ReqpmActionable | null | undefined,
  defaultCode: string | number | null | undefined = "1"
): ReqpmAction | null {
  const value = (method?.value || "").trim();
  if (!value) {
    return null;
  }
  switch (method.kind) {
    case "phone":
      return { href: `tel:${dialable(value, defaultCode)}`, label: "call" };
    case "sms":
      return { href: `sms:${dialable(value, defaultCode)}`, label: "text" };
    case "whatsapp": {
      // wa.me needs the full international number; no guessing. A username
      // has no link to build, so it is copy only — and its digits must not
      // be read as a number.
      const intl = looksLikePhone(value)
        ? internationalDigits(value, defaultCode)
        : null;
      return intl && intl.length >= 8
        ? { href: `https://wa.me/${intl}`, label: "chat" }
        : null;
    }
    case "email":
      // No ?, & or # — they would add headers (cc, body…) to the mailto:.
      return /^[^\s@<>"?&#%]+@[^\s@<>"?&#%]+$/.test(value)
        ? { href: `mailto:${value}`, label: "email" }
        : null;
    case "website": {
      const href = httpUrl(value);
      return href ? { href, label: "visit" } : null;
    }
    case "telegram": {
      if (looksLikePhone(value)) {
        return null;
      }
      const handle = value.replace(/^@/, "");
      return /^[A-Za-z0-9_]{4,32}$/.test(handle)
        ? { href: `https://t.me/${handle}`, label: "chat" }
        : null;
    }
    case "signal": {
      const intl = looksLikePhone(value)
        ? internationalDigits(value, defaultCode)
        : null;
      return intl
        ? { href: `https://signal.me/#p/+${intl}`, label: "chat" }
        : null;
    }
    case CUSTOM: {
      const href = httpUrl(value);
      return href ? { href, label: "open" } : null;
    }
    default:
      return null;
  }
}

export function isExternal(href: string | null | undefined): boolean {
  return /^https?:/.test(href || "");
}
