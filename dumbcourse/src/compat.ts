// The only file allowed to touch DOM APIs that old engines may lack. The
// build refuses `.closest(`, `.remove()`, `new Event(` and friends
// everywhere else, so every caller goes through these.

type PromiseExecutor<T> = (
  resolve: (value?: T | PromiseLike<T>) => void,
  reject: (reason?: unknown) => void
) => void;

// A small Promise for engines without one (Android 4.x stock browser).
// Enough for then/catch/resolve/reject/all/race, which is all the app uses.
function installPromise(): void {
  const w = window as unknown as { Promise?: unknown };
  if (typeof w.Promise === "function") return;

  const PENDING = 0;
  const FULFILLED = 1;
  const REJECTED = 2;
  const defer = (fn: () => void): void => {
    setTimeout(fn, 0);
  };

  function Mini(this: MiniPromise, executor: PromiseExecutor<unknown>) {
    const self = this;
    self.s = PENDING;
    self.v = undefined;
    self.q = [];
    let done = false;
    const settle = (state: number, value: unknown) => {
      if (done) return;
      done = true;
      if (
        state === FULFILLED &&
        value &&
        (typeof value === "object" || typeof value === "function")
      ) {
        let then: unknown;
        try {
          then = (value as { then?: unknown }).then;
        } catch (e) {
          done = false;
          settle(REJECTED, e);
          return;
        }
        if (typeof then === "function") {
          done = false;
          let called = false;
          try {
            (
              then as (a: (v: unknown) => void, b: (r: unknown) => void) => void
            ).call(
              value,
              (v) => {
                if (!called) {
                  called = true;
                  settle(FULFILLED, v);
                }
              },
              (r) => {
                if (!called) {
                  called = true;
                  settle(REJECTED, r);
                }
              }
            );
          } catch (e) {
            if (!called) settle(REJECTED, e);
          }
          return;
        }
      }
      self.s = state;
      self.v = value;
      const queue = self.q;
      self.q = [];
      for (let i = 0; i < queue.length; i++) queue[i]();
    };
    try {
      executor(
        (v) => settle(FULFILLED, v),
        (r) => settle(REJECTED, r)
      );
    } catch (e) {
      settle(REJECTED, e);
    }
  }

  interface MiniPromise {
    s: number;
    v: unknown;
    q: Array<() => void>;
  }

  const proto = Mini.prototype as {
    then: (
      this: MiniPromise,
      ok?: (v: unknown) => unknown,
      bad?: (r: unknown) => unknown
    ) => unknown;
    catch: (this: MiniPromise, bad: (r: unknown) => unknown) => unknown;
  };
  proto.then = function (ok, bad) {
    const self = this;
    return new (Mini as unknown as new (
      e: PromiseExecutor<unknown>
    ) => MiniPromise)((resolve, reject) => {
      const run = () => {
        defer(() => {
          const handler = self.s === FULFILLED ? ok : bad;
          if (typeof handler !== "function") {
            if (self.s === FULFILLED) resolve(self.v);
            else reject(self.v);
            return;
          }
          try {
            resolve(handler(self.v));
          } catch (e) {
            reject(e);
          }
        });
      };
      if (self.s === PENDING) self.q.push(run);
      else run();
    });
  };
  proto.catch = function (bad) {
    return proto.then.call(this, undefined, bad);
  };

  const Ctor = Mini as unknown as {
    resolve: (v: unknown) => unknown;
    reject: (r: unknown) => unknown;
    all: (list: unknown[]) => unknown;
    race: (list: unknown[]) => unknown;
    new (e: PromiseExecutor<unknown>): {
      then: (a: (v: unknown) => void, b: (r: unknown) => void) => void;
    };
  };
  Ctor.resolve = (v) => new Ctor((res) => res(v));
  Ctor.reject = (r) => new Ctor((_res, rej) => rej(r));
  Ctor.all = (list) =>
    new Ctor((res, rej) => {
      const out: unknown[] = [];
      let left = list.length;
      if (!left) {
        res(out);
        return;
      }
      for (let i = 0; i < list.length; i++) {
        new Ctor((r) => r(list[i])).then((v) => {
          out[i] = v;
          if (--left === 0) res(out);
        }, rej);
      }
    });
  Ctor.race = (list) =>
    new Ctor((res, rej) => {
      for (let i = 0; i < list.length; i++)
        new Ctor((r) => r(list[i])).then(res, rej);
    });
  w.Promise = Ctor;
}

export function installPolyfills(): void {
  installPromise();
  const w = window as unknown as { requestAnimationFrame?: unknown };
  if (typeof w.requestAnimationFrame !== "function") {
    w.requestAnimationFrame = (cb: () => void) => setTimeout(cb, 16);
  }
}

// Element#matches, with the prefixed names older engines used.
export function matches(el: Element, selector: string): boolean {
  const e = el as Element & {
    matches?: (s: string) => boolean;
    webkitMatchesSelector?: (s: string) => boolean;
    mozMatchesSelector?: (s: string) => boolean;
    msMatchesSelector?: (s: string) => boolean;
  };
  const fn =
    e.matches ||
    e.webkitMatchesSelector ||
    e.mozMatchesSelector ||
    e.msMatchesSelector;
  return fn ? fn.call(el, selector) : false;
}

// Element#closest. Accepts any event target, so callers can pass
// `event.target` directly (it may be a text node on old engines).
export function closest(
  target: EventTarget | Node | null,
  selector: string
): HTMLElement | null {
  let node = target as Node | null;
  while (node && node.nodeType !== 1) node = node.parentNode;
  while (node && node.nodeType === 1) {
    if (matches(node as Element, selector)) return node as HTMLElement;
    node = node.parentNode;
  }
  return null;
}

export function removeNode(node: Node | null | undefined): void {
  if (node && node.parentNode) node.parentNode.removeChild(node);
}

// Fires a bubbling `input` (or other plain) event the old-fashioned way,
// which every engine understands.
export function fire(el: EventTarget, type: string): void {
  const ev = document.createEvent("Event");
  ev.initEvent(type, true, true);
  el.dispatchEvent(ev);
}

// scrollIntoView without the options object old engines misread.
export function scrollIntoView(el: Element, alignTop: boolean): void {
  el.scrollIntoView(alignTop);
}

export function prefersLight(): boolean {
  try {
    return !!(
      window.matchMedia &&
      window.matchMedia("(prefers-color-scheme: light)").matches
    );
  } catch {
    return false;
  }
}

export function prefersReducedMotion(): boolean {
  try {
    return !!(
      window.matchMedia &&
      window.matchMedia("(prefers-reduced-motion: reduce)").matches
    );
  } catch {
    return false;
  }
}

// Short side over long side of the physical screen, 0 if unknown.
export function screenShape(): number {
  const s = window.screen;
  if (!s || !s.width || !s.height) return 0;
  return Math.min(s.width, s.height) / Math.max(s.width, s.height);
}

export function onMediaChange(query: string, cb: () => void): void {
  try {
    const mq = window.matchMedia && window.matchMedia(query);
    if (!mq) return;
    const m = mq as MediaQueryList & { addListener?: (fn: () => void) => void };
    if (typeof m.addEventListener === "function")
      m.addEventListener("change", cb);
    else if (m.addListener) m.addListener(cb);
  } catch {
    // Not supported: the theme simply follows the saved choice.
  }
}
