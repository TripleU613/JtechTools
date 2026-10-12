// A small MessageBus client (Discourse's live-update channel) over
// long-polling XHR. It pauses while the page is hidden and backs off when
// the connection is bad, to spare the battery and the data plan.

import { getCsrf, url } from "./api.ts";

type Callback = (data: unknown, messageId: number) => void;

const callbacks: Record<string, Callback[]> = {};
const positions: Record<string, number> = {};
const clientId =
  "dc" + Math.random().toString(36).slice(2, 10) + Date.now().toString(36);

let enabled = false;
let polling = false;
let current: XMLHttpRequest | null = null;
let timer: ReturnType<typeof setTimeout> | null = null;
let failures = 0;

export function subscribe(
  channel: string,
  cb: Callback,
  lastId = -1
): () => void {
  if (!callbacks[channel]) callbacks[channel] = [];
  callbacks[channel].push(cb);
  if (positions[channel] === undefined) positions[channel] = lastId;
  restart();
  return () => unsubscribe(channel, cb);
}

export function unsubscribe(channel: string, cb?: Callback): void {
  const list = callbacks[channel];
  if (!list) return;
  if (cb) callbacks[channel] = list.filter((x) => x !== cb);
  if (!cb || !callbacks[channel].length) {
    delete callbacks[channel];
    delete positions[channel];
  }
}

function channels(): string[] {
  const out: string[] = [];
  for (const k in callbacks)
    if (callbacks.hasOwnProperty(k) && callbacks[k].length) out.push(k);
  return out;
}

function schedule(ms: number): void {
  if (timer) clearTimeout(timer);
  timer = setTimeout(poll, ms);
}

function restart(): void {
  if (!enabled) return;
  if (current) {
    // Re-issue the poll so the new channel is included.
    const x = current;
    current = null;
    polling = false;
    try {
      x.abort();
    } catch {
      // ignore
    }
  }
  schedule(50);
}

function poll(): void {
  timer = null;
  if (!enabled || polling) return;
  const list = channels();
  if (!list.length) return;
  if (document.hidden) {
    schedule(15000);
    return;
  }
  polling = true;
  const xhr = new XMLHttpRequest();
  current = xhr;
  xhr.open("POST", url(`/message-bus/${clientId}/poll`), true);
  xhr.setRequestHeader("Content-Type", "application/x-www-form-urlencoded");
  xhr.setRequestHeader("X-SILENCE-LOGGER", "true");
  const csrf = getCsrf();
  if (csrf) xhr.setRequestHeader("X-CSRF-Token", csrf);
  xhr.timeout = 60000;
  const done = (ok: boolean) => {
    if (current !== xhr) return;
    current = null;
    polling = false;
    if (ok) {
      failures = 0;
      schedule(200);
    } else {
      failures++;
      schedule(Math.min(60000, 2000 * Math.pow(2, Math.min(failures, 5))));
    }
  };
  xhr.onload = () => {
    if (xhr.status >= 200 && xhr.status < 300) {
      let messages: Array<{
        channel: string;
        message_id: number;
        data: unknown;
      }> = [];
      try {
        messages = JSON.parse(xhr.responseText) || [];
      } catch {
        messages = [];
      }
      for (let i = 0; i < messages.length; i++) {
        const m = messages[i];
        if (m.channel === "/__status") {
          const status = m.data as Record<string, number>;
          for (const ch in status)
            if (status.hasOwnProperty(ch) && positions[ch] !== undefined)
              positions[ch] = status[ch];
          continue;
        }
        if (positions[m.channel] === undefined) continue;
        positions[m.channel] = m.message_id;
        const cbs = (callbacks[m.channel] || []).slice();
        for (let k = 0; k < cbs.length; k++) {
          try {
            cbs[k](m.data, m.message_id);
          } catch {
            // One broken handler must not stop the others.
          }
        }
      }
      done(true);
    } else {
      done(false);
    }
  };
  xhr.onerror = () => done(false);
  xhr.ontimeout = () => done(true);
  const body: string[] = [];
  for (let i = 0; i < list.length; i++)
    body.push(
      encodeURIComponent(list[i]) +
        "=" +
        encodeURIComponent(String(positions[list[i]]))
    );
  body.push("__seq=" + Date.now());
  xhr.send(body.join("&"));
}

let watchingVisibility = false;

export function startBus(): void {
  if (enabled) return;
  enabled = true;
  schedule(100);
  if (watchingVisibility) return;
  watchingVisibility = true;
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden && enabled && !polling) schedule(100);
  });
}

export function busClientId(): string {
  return clientId;
}
