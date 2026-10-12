// localStorage that never throws (private mode, quota, disabled storage)
// and keeps each account's data apart. Keys under `user:` belong to the
// signed-in account and are wiped on logout or when a different account
// signs in on the same phone.

const PREFIX = "dc:";
const OWNER_KEY = PREFIX + "owner";
let available = true;
const memory: Record<string, string> = {};

function backend(): Storage | null {
  if (!available) return null;
  try {
    return window.localStorage;
  } catch {
    available = false;
    return null;
  }
}

export function getRaw(key: string): string | null {
  const store = backend();
  if (!store) return memory.hasOwnProperty(key) ? memory[key] : null;
  try {
    return store.getItem(key);
  } catch {
    return null;
  }
}

export function setRaw(key: string, value: string): void {
  memory[key] = value;
  const store = backend();
  if (!store) return;
  try {
    store.setItem(key, value);
  } catch {
    // Quota: drop the caches (they rebuild) and try once more.
    clearPrefix(PREFIX + "cache:");
    try {
      store.setItem(key, value);
    } catch {
      // Give up quietly; the in-memory copy still works this session.
    }
  }
}

export function removeRaw(key: string): void {
  delete memory[key];
  const store = backend();
  if (!store) return;
  try {
    store.removeItem(key);
  } catch {
    // ignore
  }
}

function keys(): string[] {
  const store = backend();
  const out: string[] = [];
  if (store) {
    try {
      for (let i = 0; i < store.length; i++) {
        const k = store.key(i);
        if (k) out.push(k);
      }
    } catch {
      // ignore
    }
  }
  for (const k in memory)
    if (memory.hasOwnProperty(k) && out.indexOf(k) < 0) out.push(k);
  return out;
}

export function clearPrefix(prefix: string): void {
  const all = keys();
  for (let i = 0; i < all.length; i++)
    if (all[i].indexOf(prefix) === 0) removeRaw(all[i]);
}

export function getJson<T>(key: string, fallback: T): T {
  const rawValue = getRaw(PREFIX + key);
  if (rawValue === null) return fallback;
  try {
    const parsed = JSON.parse(rawValue);
    return parsed === null || parsed === undefined ? fallback : (parsed as T);
  } catch {
    return fallback;
  }
}

export function setJson(key: string, value: unknown): void {
  setRaw(PREFIX + key, JSON.stringify(value));
}

export function remove(key: string): void {
  removeRaw(PREFIX + key);
}

// ── Per-account storage ───────────────────────────────────────────────

let owner = getRaw(OWNER_KEY) || "";

// Called whenever the signed-in account is known. A different account (or
// none) wipes everything the previous one left behind.
export function claimFor(userId: number | null): void {
  const id = userId ? String(userId) : "";
  if (id === owner) return;
  clearPrefix(PREFIX + "user:");
  clearPrefix(PREFIX + "cache:");
  owner = id;
  if (id) setRaw(OWNER_KEY, id);
  else removeRaw(OWNER_KEY);
}

export function userGet<T>(key: string, fallback: T): T {
  if (!owner) return fallback;
  return getJson("user:" + key, fallback);
}

export function userSet(key: string, value: unknown): void {
  if (!owner) return;
  setJson("user:" + key, value);
}

export function hasOwner(): boolean {
  return !!owner;
}
