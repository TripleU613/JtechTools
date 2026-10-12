// HTML building with escaping by default. Every `${value}` in an html``
// template is escaped unless it is already SafeHtml (another html``
// result, or raw() for HTML the server has sanitised, like cooked posts).
// This replaces the old string concatenation, where each call site had to
// remember esc().

export class SafeHtml {
  readonly value: string;
  constructor(value: string) {
    this.value = value;
  }
  toString(): string {
    return this.value;
  }
}

const ESCAPES: Record<string, string> = {
  "&": "&amp;",
  "<": "&lt;",
  ">": "&gt;",
  '"': "&quot;",
  "'": "&#39;",
  "`": "&#96;",
};

export function escapeHtml(value: unknown): string {
  if (value === null || value === undefined || value === false) return "";
  return String(value).replace(/[&<>"'`]/g, (ch) => ESCAPES[ch]);
}

export type HtmlValue =
  | SafeHtml
  | string
  | number
  | boolean
  | null
  | undefined
  | HtmlValue[];

function render(value: HtmlValue): string {
  if (value instanceof SafeHtml) return value.value;
  if (Object.prototype.toString.call(value) === "[object Array]") {
    return (value as HtmlValue[]).map(render).join("");
  }
  return escapeHtml(value);
}

export function html(
  strings: TemplateStringsArray,
  ...values: HtmlValue[]
): SafeHtml {
  let out = strings[0];
  for (let i = 0; i < values.length; i++)
    out += render(values[i]) + strings[i + 1];
  return new SafeHtml(out);
}

// Marks trusted markup (server-sanitised HTML, our own SVG icons).
export function raw(markup: string | null | undefined): SafeHtml {
  return new SafeHtml(markup || "");
}

export function join(parts: HtmlValue[], separator = ""): SafeHtml {
  return new SafeHtml(parts.map(render).join(render(separator)));
}

// For attribute values that must be a URL: only http(s), mailto, tel, sms
// and relative paths survive; anything else (javascript:, data:, …) becomes
// "#". Escaping still happens in html``.
export function safeUrl(url: string | null | undefined): string {
  const u = String(url || "").trim();
  if (!u) return "#";
  if (/^(https?:|mailto:|tel:|sms:)/i.test(u)) return u;
  if (/^\/\//.test(u)) return u;
  if (/^[a-z][a-z0-9+.-]*:/i.test(u)) return "#";
  return u;
}
