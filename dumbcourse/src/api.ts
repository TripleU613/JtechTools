// Talks to Discourse's JSON API over XMLHttpRequest (every engine has it;
// fetch() arrived later than some of our phones). Sends the CSRF token on
// every write, learns a fresh one when the server rotates it, and turns
// failures into ApiError with a message fit to show a person.

import { settings } from "./config.ts";

// Not a subclass of Error: lowered to ES5, `extends Error` loses the
// prototype on old engines and `instanceof` stops working.
export class ApiError {
  name = "ApiError";
  message: string;
  status: number;
  errors: string[];
  body: Record<string, unknown> | null;
  constructor(
    message: string,
    status: number,
    errors: string[] = [],
    body: Record<string, unknown> | null = null
  ) {
    this.message = message;
    this.status = status;
    this.errors = errors;
    this.body = body;
  }
  toString(): string {
    return this.message;
  }
}

export const OFFLINE_MESSAGE =
  "Can't reach the forum right now. Check your connection and try again.";

let csrf = settings.csrf || "";
let rateLimitedUntil = 0;
let onUnauthorized: (() => void) | null = null;
let inflight = 0;
let onActivity: ((busy: boolean) => void) | null = null;

export function getCsrf(): string {
  return csrf;
}

export function onSessionLost(fn: () => void): void {
  onUnauthorized = fn;
}

export function onNetworkActivity(fn: (busy: boolean) => void): void {
  onActivity = fn;
}

export interface RequestOptions {
  method?: "GET" | "POST" | "PUT" | "DELETE";
  body?: unknown;
  form?: FormData;
  // Encode `body` as application/x-www-form-urlencoded instead of JSON.
  urlencoded?: boolean;
  timeout?: number;
  // Keep a 401 from signing the person out (login endpoints use this).
  allowUnauthorized?: boolean;
  onProgress?: (fraction: number) => void;
  // Called with the XHR so callers can abort it.
  xhr?: (xhr: XMLHttpRequest) => void;
}

export function url(path: string): string {
  if (/^https?:\/\//.test(path)) return path;
  return settings.subfolder + path;
}

function encodeForm(value: unknown, prefix: string, out: string[]): void {
  if (value === undefined || value === null) return;
  if (Object.prototype.toString.call(value) === "[object Array]") {
    const list = value as unknown[];
    for (let i = 0; i < list.length; i++)
      encodeForm(list[i], prefix + "[]", out);
    return;
  }
  if (typeof value === "object") {
    const obj = value as Record<string, unknown>;
    for (const key in obj) {
      if (obj.hasOwnProperty(key))
        encodeForm(obj[key], prefix ? `${prefix}[${key}]` : key, out);
    }
    return;
  }
  out.push(
    encodeURIComponent(prefix) + "=" + encodeURIComponent(String(value))
  );
}

export function formEncode(value: Record<string, unknown>): string {
  const out: string[] = [];
  encodeForm(value, "", out);
  return out.join("&");
}

function messageFrom(
  status: number,
  body: Record<string, unknown> | null,
  text: string
): { message: string; errors: string[] } {
  let errors: string[] = [];
  if (body) {
    if (Object.prototype.toString.call(body.errors) === "[object Array]")
      errors = (body.errors as unknown[]).map(String);
    else if (typeof body.error === "string") errors = [body.error as string];
    else if (typeof body.message === "string" && status >= 400)
      errors = [body.message as string];
  }
  if (errors.length) return { message: errors.join(" "), errors };
  if (status === 0) return { message: OFFLINE_MESSAGE, errors };
  if (status === 403)
    return { message: "You're not allowed to do that.", errors };
  if (status === 404)
    return { message: "That page doesn't exist or was removed.", errors };
  if (status === 413) return { message: "That's too large to send.", errors };
  if (status === 422)
    return { message: "The forum couldn't accept that.", errors };
  if (status === 429)
    return {
      message: "Slow down a little — too many requests. Try again in a moment.",
      errors,
    };
  if (status >= 500 || /<html/i.test(text))
    return {
      message: "The forum is having trouble right now. Try again soon.",
      errors,
    };
  return { message: `Something went wrong (${status}).`, errors };
}

export function request<T = unknown>(
  path: string,
  opts: RequestOptions = {}
): Promise<T> {
  const method = opts.method || "GET";
  if (rateLimitedUntil > Date.now()) {
    return Promise.reject(
      new ApiError(messageFrom(429, null, "").message, 429)
    );
  }
  return new Promise<T>((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open(method, url(path), true);
    xhr.setRequestHeader("Accept", "application/json");
    xhr.setRequestHeader("X-Requested-With", "XMLHttpRequest");
    // Discourse uses this to answer with JSON errors rather than HTML.
    xhr.setRequestHeader("Discourse-Logged-In", "true");
    if (method !== "GET" && csrf) xhr.setRequestHeader("X-CSRF-Token", csrf);
    xhr.timeout = opts.timeout || 30000;
    if (opts.xhr) opts.xhr(xhr);

    let payload: string | FormData | null = null;
    if (opts.form) {
      payload = opts.form;
      if (opts.onProgress && xhr.upload) {
        xhr.upload.onprogress = (e) => {
          if (e.lengthComputable && opts.onProgress)
            opts.onProgress(e.loaded / e.total);
        };
      }
    } else if (opts.body !== undefined) {
      if (opts.urlencoded) {
        xhr.setRequestHeader(
          "Content-Type",
          "application/x-www-form-urlencoded; charset=UTF-8"
        );
        payload = formEncode(opts.body as Record<string, unknown>);
      } else {
        xhr.setRequestHeader("Content-Type", "application/json; charset=UTF-8");
        payload = JSON.stringify(opts.body);
      }
    }

    inflight++;
    if (inflight === 1 && onActivity) onActivity(true);
    const finish = () => {
      inflight = Math.max(0, inflight - 1);
      if (inflight === 0 && onActivity) onActivity(false);
    };

    xhr.onload = () => {
      finish();
      const token = xhr.getResponseHeader("X-CSRF-Token");
      if (token && token !== "undefined") csrf = token;
      const text = xhr.responseText || "";
      let body: Record<string, unknown> | null = null;
      const type = xhr.getResponseHeader("Content-Type") || "";
      if (type.indexOf("json") >= 0 && text) {
        try {
          body = JSON.parse(text);
        } catch {
          body = null;
        }
      }
      if (xhr.status >= 200 && xhr.status < 300) {
        resolve((body !== null ? body : text) as T);
        return;
      }
      if (xhr.status === 429) {
        const retry = parseInt(xhr.getResponseHeader("Retry-After") || "0", 10);
        rateLimitedUntil =
          Date.now() + (retry > 0 ? Math.min(retry, 120) * 1000 : 10000);
      }
      if (xhr.status === 403 && text.indexOf("BAD CSRF") >= 0) csrf = "";
      if (xhr.status === 401 && !opts.allowUnauthorized && onUnauthorized)
        onUnauthorized();
      const m = messageFrom(xhr.status, body, text);
      reject(new ApiError(m.message, xhr.status, m.errors, body));
    };
    xhr.onerror = () => {
      finish();
      reject(new ApiError(OFFLINE_MESSAGE, 0));
    };
    xhr.ontimeout = () => {
      finish();
      reject(new ApiError("The forum took too long to answer. Try again.", 0));
    };
    xhr.onabort = () => {
      finish();
      reject(new ApiError("Cancelled.", -1));
    };
    xhr.send(payload);
  });
}

export function get<T = unknown>(
  path: string,
  opts: RequestOptions = {}
): Promise<T> {
  opts.method = "GET";
  return request<T>(path, opts);
}

export function post<T = unknown>(
  path: string,
  body?: unknown,
  opts: RequestOptions = {}
): Promise<T> {
  opts.method = "POST";
  opts.body = body;
  return withCsrf(() => request<T>(path, opts));
}

export function put<T = unknown>(
  path: string,
  body?: unknown,
  opts: RequestOptions = {}
): Promise<T> {
  opts.method = "PUT";
  opts.body = body;
  return withCsrf(() => request<T>(path, opts));
}

export function del<T = unknown>(
  path: string,
  body?: unknown,
  opts: RequestOptions = {}
): Promise<T> {
  opts.method = "DELETE";
  opts.body = body;
  return withCsrf(() => request<T>(path, opts));
}

export function refreshCsrf(): Promise<string> {
  return get<{ csrf: string }>("/session/csrf.json").then((d) => {
    csrf = (d && d.csrf) || csrf;
    return csrf;
  });
}

// Writes need a token; if the page has none (or it went stale and the
// server said so), fetch one and retry once.
function withCsrf<T>(run: () => Promise<T>): Promise<T> {
  const start = csrf ? Promise.resolve(csrf) : refreshCsrf();
  return start.then(() =>
    run().catch((error: unknown) => {
      if (error instanceof ApiError && error.status === 403 && !csrf) {
        return refreshCsrf().then(run);
      }
      throw error;
    })
  );
}

export function errorMessage(error: unknown): string {
  if (error instanceof ApiError) return error.message;
  if (error && typeof (error as { message?: unknown }).message === "string") {
    return (error as { message: string }).message || "Something went wrong.";
  }
  return String(error || "Something went wrong.");
}
