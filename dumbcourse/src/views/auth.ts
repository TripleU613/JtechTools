// Signing in, without making anyone type a password on a keypad if they'd
// rather not: password (with two-factor codes), an emailed link, an emailed
// code, or approving this phone from another device where you're already
// signed in. Plus sign-up, password reset and account activation — the
// full site's versions of those pages don't work on old browsers.

import {
  ApiError,
  errorMessage,
  get,
  getCsrf,
  post,
  put,
  refreshCsrf,
} from "../api.ts";
import { go } from "../app.ts";
import { APP_ROOT, settings } from "../config.ts";
import { $, byId } from "../dom.ts";
import { html, raw, type SafeHtml } from "../html.ts";
import { focus, focusContent } from "../nav.ts";
import { buildQuery, href, type RouteContext } from "../router.ts";
import { logout as endSession, user } from "../session.ts";
import { unregisterPush } from "../push.ts";
import { icon } from "../ui/icons.ts";
import { alertDialog, confirmDialog, toast } from "../ui/layers.ts";
import { useScreen } from "./common.ts";
import { setPreferDumbcourse } from "./preferences.ts";

// Where to go once signed in: only paths inside Dumbcourse.
function nextPath(ctx: RouteContext): string {
  const n = ctx.query.next || "";
  if (/^\/[^/\\]/.test(n) && n.indexOf("//") < 0) return n;
  return "/";
}

// A full reload after signing in picks up the fresh session everywhere
// (boot data, CSRF token, live updates).
function finishLogin(ctx: RouteContext): void {
  location.replace(APP_ROOT + nextPath(ctx));
}

function honeypot(): Promise<{ value: string; challenge: string }> {
  return get<{ value: string; challenge: string }>("/session/hp.json").then(
    (d) => ({
      value: d.value,
      challenge: String(d.challenge || "")
        .split("")
        .reverse()
        .join(""),
    })
  );
}

function field(
  id: string,
  label: string,
  input: SafeHtml,
  hint = ""
): SafeHtml {
  return html`<div class="field">
    <label class="field-label" for="${id}">${label}</label>${input}${hint
      ? html`<p class="hint">${hint}</p>`
      : ""}
  </div>`;
}

// Where showError writes: one on each sign-in screen.
function errorSlot(): SafeHtml {
  return html`<p
    id="authError"
    class="notice error"
    role="alert"
    hidden
    tabindex="-1"
  ></p>`;
}

function showError(message: string): void {
  const el = byId("authError");
  if (!el) {
    toast(message, "error");
    return;
  }
  el.textContent = message;
  el.hidden = false;
  focus(el);
}

function clearError(): void {
  const el = byId("authError");
  if (el) el.hidden = true;
}

function busy(btn: HTMLElement | null, on: boolean, label?: string): void {
  if (!btn) return;
  if (on) {
    btn.setAttribute("disabled", "");
    btn.setAttribute("data-label", btn.textContent || "");
    if (label) btn.textContent = label;
  } else {
    btn.removeAttribute("disabled");
    const l = btn.getAttribute("data-label");
    if (l) btn.textContent = l;
  }
}

function brand(sub = ""): SafeHtml {
  return html`<div class="auth-brand">
    ${settings.siteIcon
      ? html`<img src="${settings.siteIcon}" alt="" width="40" height="40" />`
      : icon("chat")}
    <h1>${settings.siteTitle}</h1>
    ${sub ? html`<p>${sub}</p>` : ""}
  </div>`;
}

// ── Sign in ───────────────────────────────────────────────────────────

const TFA_REASONS = [
  "invalid_second_factor",
  "invalid_second_factor_method",
  "not_enabled_second_factor_method",
];

interface LoginResponse {
  error?: string;
  reason?: string;
  user?: { id: number };
  totp_enabled?: boolean;
  backup_enabled?: boolean;
  security_key_enabled?: boolean;
  sent_to_email?: string;
  current_email?: string;
}

export function loginRoute(ctx: RouteContext): void {
  const s = useScreen();
  if (user) {
    go(nextPath(ctx), { replace: true });
    return;
  }
  s.title("Sign in", { back: false });
  const a = settings.auth;
  const others: SafeHtml[] = [];
  if (a.pairing)
    others.push(
      html`<a
        class="btn block"
        href="${href("/login/device" + buildQuery({ next: ctx.query.next }))}"
        data-key="pair"
        >${icon("devices")}Sign in with another device</a
      >`
    );
  if (a.emailCode)
    others.push(
      html`<a
        class="btn block"
        href="${href("/login/code" + buildQuery({ next: ctx.query.next }))}"
        data-key="code"
        >${icon("key")}Email me a code</a
      >`
    );
  if (a.emailLink)
    others.push(
      html`<a
        class="btn block"
        href="${href("/login/email" + buildQuery({ next: ctx.query.next }))}"
        data-key="link"
        >${icon("mail")}Email me a sign-in link</a
      >`
    );
  for (let i = 0; i < a.providers.length; i++) {
    const p = a.providers[i];
    others.push(
      html`<button
        type="button"
        class="btn block"
        data-act="provider"
        data-provider="${p.name}"
      >
        ${icon("login")}Continue with ${p.title}
      </button>`
    );
  }

  s.render(
    html`<section class="auth">
      ${brand()} ${errorSlot()}
      ${a.local
        ? html`<form class="card form" data-login>
            ${field(
              "login",
              "Username or email",
              html`<input
                id="login"
                type="text"
                autocomplete="username"
                autocapitalize="off"
                autocorrect="off"
                spellcheck="false"
              />`
            )}
            ${field(
              "password",
              "Password",
              html`<input
                id="password"
                type="password"
                autocomplete="current-password"
              />`
            )}
            <div id="tfa" hidden>
              ${field(
                "tfaCode",
                "Two-factor code",
                html`<input
                  id="tfaCode"
                  type="tel"
                  inputmode="numeric"
                  autocomplete="one-time-code"
                  maxlength="16"
                />`
              )}
            </div>
            <button type="submit" class="btn primary block" data-login-btn>
              ${icon("login")}Sign in
            </button>
            <p class="auth-links">
              <a href="${href("/password-reset" + buildQuery({ login: "" }))}"
                >Forgot password?</a
              >
            </p>
          </form>`
        : html``}
      ${others.length
        ? html`<p class="auth-or">
              <span>${a.local ? "or" : "Sign in with"}</span>
            </p>
            <div class="auth-others">${others}</div>`
        : ""}
      ${a.signup && !a.inviteOnly
        ? html`<p class="auth-links">
            New here? <a href="${href("/signup")}">Create an account</a>
          </p>`
        : ""}
      <p class="auth-links small">
        <a href="${href("/preferences")}">Display settings</a> ·
        <a href="${href("/full-site")}" data-full-site>Full site</a>
      </p>
    </section>`
  );

  s.act("provider", (el) =>
    startProvider(el.getAttribute("data-provider") || "", nextPath(ctx))
  );

  const form = $("[data-login]") as HTMLFormElement | null;
  if (!form) {
    focusContent(".btn");
    return;
  }
  const loginEl = byId("login") as HTMLInputElement;
  const passEl = byId("password") as HTMLInputElement;
  const tfaBox = byId("tfa") as HTMLElement;
  const tfaEl = byId("tfaCode") as HTMLInputElement;
  const btn = $("[data-login-btn]") as HTMLElement;
  let tfaMethod = 1;

  form.addEventListener("submit", (e) => {
    e.preventDefault();
    clearError();
    const login = loginEl.value.replace(/^\s+|\s+$/g, "");
    if (!login || !passEl.value) {
      showError("Enter your username (or email) and password.");
      focus(!login ? loginEl : passEl);
      return;
    }
    const body: Record<string, unknown> = {
      login,
      password: passEl.value,
      timezone: timezone(),
    };
    if (!tfaBox.hidden && tfaEl.value) {
      const code = tfaEl.value.replace(/\s+/g, "");
      body.second_factor_token = code;
      // Backup codes are 16 hex characters; app codes are 6 digits.
      body.second_factor_method = /^\d{6}$/.test(code)
        ? 1
        : code.length === 16
          ? 2
          : tfaMethod;
    }
    busy(btn, true, "Signing in…");
    post<LoginResponse>("/session.json", body, {
      urlencoded: true,
      allowUnauthorized: true,
    }).then(
      (d) => {
        busy(btn, false);
        if (d && d.error) {
          // Discourse answers "invalid_second_factor_method" while no code
          // was sent yet, and "invalid_second_factor" for a wrong code.
          if (d.reason && TFA_REASONS.indexOf(d.reason) >= 0) {
            const first = tfaBox.hidden;
            tfaBox.hidden = false;
            tfaMethod = d.totp_enabled ? 1 : d.backup_enabled ? 2 : 1;
            if (
              !d.totp_enabled &&
              !d.backup_enabled &&
              d.security_key_enabled
            ) {
              showError(
                "Security keys don't work in this browser. Use Sign in with another device."
              );
              return;
            }
            if (first) {
              toast("Enter your two-factor code.");
              focus(tfaEl);
            } else {
              showError(d.error);
              tfaEl.value = "";
              focus(tfaEl);
            }
            return;
          }
          if (d.reason === "not_activated") {
            showError("Account not activated yet. Check your email.");
            offerResend(login);
            return;
          }
          showError(d.error);
          return;
        }
        finishLogin(ctx);
      },
      (err: unknown) => {
        busy(btn, false);
        showError(errorMessage(err));
      }
    );
  });
  if (!ctx.restore) focus(loginEl);
}

function offerResend(username: string): void {
  confirmDialog("Send the activation email again?", { ok: "Send" }).then(
    (ok) => {
      if (!ok) return;
      post("/u/action/send_activation_email.json", { username }).then(
        () => toast("Sent. Check your email.", "success"),
        (e: unknown) => toast(errorMessage(e), "error")
      );
    }
  );
}

function timezone(): string {
  try {
    const intl = (
      window as unknown as {
        Intl?: {
          DateTimeFormat?: () => {
            resolvedOptions: () => { timeZone?: string };
          };
        };
      }
    ).Intl;
    return (
      (intl &&
        intl.DateTimeFormat &&
        intl.DateTimeFormat().resolvedOptions().timeZone) ||
      ""
    );
  } catch {
    return "";
  }
}

// Social sign-in: a normal form POST to Discourse's /auth/:provider (it
// needs the CSRF token), coming back to Dumbcourse afterwards.
function startProvider(name: string, next: string): void {
  if (!/^[\w-]+$/.test(name)) return;
  const secure = location.protocol === "https:" ? "; secure" : "";
  document.cookie = `destination_url=${encodeURIComponent(APP_ROOT + next)}; path=/; max-age=600; samesite=lax${secure}`;
  const form = document.createElement("form");
  form.method = "POST";
  form.action = settings.subfolder + "/auth/" + name;
  const token = document.createElement("input");
  token.type = "hidden";
  token.name = "authenticity_token";
  token.value = getCsrf();
  form.appendChild(token);
  document.body.appendChild(form);
  form.submit();
}

// ── Email link ────────────────────────────────────────────────────────

export function emailLinkRoute(ctx: RouteContext): void {
  const s = useScreen();
  s.title("Email a sign-in link", { back: true });
  s.render(
    html`<section class="auth">
      ${brand()} ${errorSlot()}
      <form class="card form" data-email>
        ${field(
          "login",
          "Username or email",
          html`<input
            id="login"
            type="text"
            autocomplete="username"
            autocapitalize="off"
            value="${ctx.query.login || ""}"
          />`
        )}
        <button type="submit" class="btn primary block">
          ${icon("mail")}Send link
        </button>
      </form>
      <p class="auth-links"><a href="${href("/login")}">Back to sign in</a></p>
    </section>`
  );
  const form = $("[data-email]") as HTMLFormElement;
  form.addEventListener("submit", (e) => {
    e.preventDefault();
    clearError();
    const login = (byId("login") as HTMLInputElement).value.replace(
      /^\s+|\s+$/g,
      ""
    );
    if (!login) return showError("Enter your username or email.");
    post<{ success?: string; error?: string }>(
      "/u/email-login.json",
      { login },
      { allowUnauthorized: true }
    ).then(
      (d) => {
        if (d && d.error) return showError(d.error);
        void alertDialog(
          "If that account exists, a link is on its way.",
          "Check your email"
        );
      },
      (err: unknown) => showError(errorMessage(err))
    );
  });
  if (!ctx.restore) focusContent("#login");
}

interface EmailLoginInfo {
  can_login?: boolean;
  error?: string;
  second_factor_required?: boolean;
  security_key_required?: boolean;
  backup_enabled?: boolean;
  token_email?: string;
}

// Arriving from the emailed link (the server sends old browsers here
// instead of the full-site page).
export function emailLoginTokenRoute(ctx: RouteContext): Promise<void> {
  const s = useScreen();
  const token = ctx.params.token || "";
  s.title("Signing in", { back: false });
  s.loading("Checking your link…");
  return get<EmailLoginInfo>(
    `/session/email-login/${encodeURIComponent(token)}.json`,
    { allowUnauthorized: true }
  ).then(
    (info) => {
      if (!s.alive()) return;
      if (!info.can_login) {
        s.render(
          html`<section class="auth">
            ${brand()}
            <p class="notice error">
              ${info.error || "This link has expired or was already used."}
            </p>
            <a class="btn primary block" href="${href("/login/email")}"
              >Send a new link</a
            >
          </section>`
        );
        focusContent(".btn");
        return;
      }
      if (info.security_key_required && !info.backup_enabled) {
        s.render(
          html`<section class="auth">
            ${brand()}
            <p class="notice error">
              This account needs a security key, which this browser can't use.
              Open the link on a computer, or use Sign in with another device.
            </p>
          </section>`
        );
        return;
      }
      s.render(
        html`<section class="auth">
          ${brand(
            info.token_email ? `Sign in as ${info.token_email}` : "Sign in"
          )}
          ${errorSlot()}
          <form class="card form" data-confirm>
            ${info.second_factor_required
              ? field(
                  "tfaCode",
                  "Two-factor code",
                  html`<input
                    id="tfaCode"
                    type="tel"
                    inputmode="numeric"
                    autocomplete="one-time-code"
                    maxlength="16"
                  />`,
                  "From your authenticator app, or a backup code."
                )
              : ""}
            <button type="submit" class="btn primary block">
              ${icon("login")}Sign in
            </button>
          </form>
        </section>`
      );
      const form = $("[data-confirm]") as HTMLFormElement;
      form.addEventListener("submit", (e) => {
        e.preventDefault();
        const body: Record<string, unknown> = { timezone: timezone() };
        const tfa = byId("tfaCode") as HTMLInputElement | null;
        if (tfa) {
          const code = tfa.value.replace(/\s+/g, "");
          body.second_factor_token = code;
          body.second_factor_method = /^\d{6}$/.test(code) ? 1 : 2;
        }
        post<{ success?: string; error?: string }>(
          `/session/email-login/${encodeURIComponent(token)}.json`,
          body,
          { urlencoded: true, allowUnauthorized: true }
        ).then(
          (d) => (d && d.error ? showError(d.error) : finishLogin(ctx)),
          (err: unknown) => showError(errorMessage(err))
        );
      });
      focusContent(info.second_factor_required ? "#tfaCode" : ".btn");
    },
    (e: unknown) => s.error(errorMessage(e))
  );
}

// ── Email code (Discourse's one-time codes, when the forum has them on) ─

export function emailCodeRoute(ctx: RouteContext): void {
  const s = useScreen();
  s.title("Email me a code", { back: true });
  s.render(
    html`<section class="auth">
      ${brand()} ${errorSlot()}
      <form class="card form" data-code>
        <div id="step1">
          ${field(
            "email",
            "Email",
            html`<input
              id="email"
              type="email"
              autocomplete="email"
              autocapitalize="off"
            />`
          )}
        </div>
        <div id="step2" hidden>
          ${field(
            "code",
            "Code from the email",
            html`<input
              id="code"
              type="tel"
              inputmode="numeric"
              autocomplete="one-time-code"
              maxlength="6"
            />`
          )}
          <div id="tfaBox" hidden>
            ${field(
              "tfaCode",
              "Two-factor code",
              html`<input
                id="tfaCode"
                type="tel"
                inputmode="numeric"
                maxlength="16"
              />`
            )}
          </div>
        </div>
        <button type="submit" class="btn primary block" data-btn>
          Send code
        </button>
      </form>
      <p class="auth-links"><a href="${href("/login")}">Back to sign in</a></p>
    </section>`
  );
  const form = $("[data-code]") as HTMLFormElement;
  const btn = $("[data-btn]") as HTMLElement;
  let sent = false;
  form.addEventListener("submit", (e) => {
    e.preventDefault();
    clearError();
    const email = (byId("email") as HTMLInputElement).value.replace(
      /^\s+|\s+$/g,
      ""
    );
    if (!email) return showError("Enter your email address.");
    if (!sent) {
      busy(btn, true, "Sending…");
      honeypot()
        .then((hp) =>
          post(
            "/session/login-code.json",
            { email, password_confirmation: hp.value, challenge: hp.challenge },
            { allowUnauthorized: true }
          )
        )
        .then(
          () => {
            busy(btn, false);
            sent = true;
            (byId("step2") as HTMLElement).hidden = false;
            btn.textContent = "Sign in";
            focus(byId("code"));
            toast("If that address has an account, a code is on its way.");
          },
          (err: unknown) => {
            busy(btn, false);
            showError(errorMessage(err));
          }
        );
      return;
    }
    const code = (byId("code") as HTMLInputElement).value.replace(/\D/g, "");
    const body: Record<string, unknown> = { email, code, timezone: timezone() };
    const tfaBox = byId("tfaBox") as HTMLElement;
    const tfa = byId("tfaCode") as HTMLInputElement;
    if (!tfaBox.hidden && tfa.value) {
      const t = tfa.value.replace(/\s+/g, "");
      body.second_factor_token = t;
      body.second_factor_method = /^\d{6}$/.test(t) ? 1 : 2;
    }
    busy(btn, true, "Checking…");
    post<Record<string, unknown>>("/session/login-code/verify.json", body, {
      allowUnauthorized: true,
    }).then(
      (d) => {
        busy(btn, false);
        if (
          d &&
          (d.second_factor_required ||
            d.totp_enabled ||
            (!!d.reason && TFA_REASONS.indexOf(String(d.reason)) >= 0))
        ) {
          tfaBox.hidden = false;
          // Only a wrong code is an error; the first ask is just a prompt.
          if (d.error && d.reason === "invalid_second_factor")
            showError(String(d.error));
          focus(tfa);
          return;
        }
        if (d && d.error) return showError(String(d.error));
        if (d && (d.user_fields_required || d.name_required)) {
          return showError("Finish signing up with Create an account.");
        }
        finishLogin(ctx);
      },
      (err: unknown) => {
        busy(btn, false);
        showError(errorMessage(err));
      }
    );
  });
  if (!ctx.restore) focusContent("#email");
}

// ── Sign in with another device (this phone shows a code) ─────────────

interface PairStart {
  code: string;
  expires_in: number;
  poll_interval: number;
  approve_url: string;
}

function prettyCode(code: string): string {
  return code.length === 8 ? code.slice(0, 4) + "-" + code.slice(4) : code;
}

export function pairRoute(ctx: RouteContext): Promise<void> {
  const s = useScreen();
  s.title("Sign in with another device", { back: true });
  s.loading("Getting a code…");
  let timer: ReturnType<typeof setTimeout> | null = null;
  let countdown: ReturnType<typeof setInterval> | null = null;
  s.onLeave(() => {
    if (timer) clearTimeout(timer);
    if (countdown) clearInterval(countdown);
  });
  return post<PairStart>(
    settings.basePath + "/auth/pair.json",
    {},
    { allowUnauthorized: true }
  ).then(
    (d) => {
      if (!s.alive()) return;
      const url = location.host + d.approve_url;
      let left = d.expires_in;
      s.render(
        html`<section class="auth pair">
          <p class="pair-step">On a signed-in device, open</p>
          <p class="pair-url">${url}</p>
          <p class="pair-step">and enter</p>
          <p
            class="pair-code"
            tabindex="0"
            aria-label="Code ${d.code.split("").join(" ")}"
          >
            ${prettyCode(d.code)}
          </p>
          <p class="hint" id="pairLeft" aria-live="off"></p>
          <div class="btn-row" data-row>
            <button type="button" class="btn" data-act="pair-new">
              New code</button
            ><a class="btn ghost" href="${href("/login")}">Cancel</a>
          </div>
        </section>`
      );
      s.act("pair-new", () =>
        go(ctx.path + location.search, { replace: true })
      );
      const tick = () => {
        left--;
        const el = byId("pairLeft");
        if (el)
          el.textContent =
            left > 0
              ? `Code expires in ${Math.floor(left / 60)}:${left % 60 < 10 ? "0" : ""}${left % 60}`
              : "This code expired.";
      };
      tick();
      countdown = setInterval(tick, 1000);
      const poll = () => {
        timer = null;
        if (!s.alive()) return;
        if (left <= 0) {
          const el = byId("pairLeft");
          if (el) el.textContent = "This code expired. Get a new one.";
          return;
        }
        get<{ status: string }>(settings.basePath + "/auth/pair/poll.json", {
          allowUnauthorized: true,
        }).then(
          (r) => {
            if (!s.alive()) return;
            if (r.status === "approved") {
              toast("Approved — signing you in.", "success");
              finishLogin(ctx);
              return;
            }
            if (r.status === "expired" || r.status === "denied") {
              const el = byId("pairLeft");
              if (el)
                el.textContent =
                  r.status === "denied"
                    ? "The request was declined."
                    : "This code expired. Get a new one.";
              return;
            }
            timer = setTimeout(poll, d.poll_interval * 1000);
          },
          () => {
            timer = setTimeout(poll, d.poll_interval * 2000);
          }
        );
      };
      timer = setTimeout(poll, d.poll_interval * 1000);
      focusContent(".pair-code");
    },
    (e: unknown) =>
      s.error(errorMessage(e), () =>
        go(ctx.path + location.search, { replace: true })
      )
  );
}

// ── Approve a device (the signed-in side) ─────────────────────────────

interface PairLookup {
  device: string;
  approximate_location?: string | null;
  requested_at: string;
}

export function linkRoute(ctx: RouteContext): void {
  const s = useScreen();
  s.title("Sign in another device", { back: true });
  s.render(
    html`<section class="auth">
      ${brand()} ${errorSlot()}
      <form class="card form" data-link>
        ${field(
          "pairCode",
          "Code",
          html`<input
            id="pairCode"
            type="text"
            autocomplete="off"
            autocapitalize="characters"
            spellcheck="false"
            maxlength="9"
            placeholder="ABCD-2345"
            value="${ctx.query.code || ""}"
          />`
        )}
        <button type="submit" class="btn primary block">Continue</button>
      </form>
      <p class="notice">
        ${icon("shield")} Only enter a code from your own device.
      </p>
    </section>`
  );
  const form = $("[data-link]") as HTMLFormElement;
  form.addEventListener("submit", (e) => {
    e.preventDefault();
    clearError();
    const code = (byId("pairCode") as HTMLInputElement).value
      .toUpperCase()
      .replace(/[^A-Z0-9]/g, "");
    if (code.length !== 8)
      return showError("The code has 8 letters and numbers.");
    get<PairLookup>(
      settings.basePath +
        "/auth/pair/lookup.json?code=" +
        encodeURIComponent(code)
    ).then(
      (d) => {
        confirmDialog(
          `Sign in this device as @${user ? user.username : ""}?\n\n${d.device}${d.approximate_location ? "\n" + d.approximate_location : ""}\n\nOnly approve a device you're holding.`,
          { title: "Approve sign-in", ok: "Yes, sign it in", cancel: "No" }
        ).then((ok) => {
          const action = ok ? "approve" : "deny";
          post(settings.basePath + `/auth/pair/${action}.json`, { code }).then(
            () => {
              if (ok)
                void alertDialog(
                  "Done. The other device is signing in now.",
                  "Approved"
                );
              else toast("Declined.");
              (byId("pairCode") as HTMLInputElement).value = "";
            },
            (err: unknown) => showError(errorMessage(err))
          );
        });
      },
      (err: unknown) =>
        showError(
          err instanceof ApiError && err.status === 404
            ? "That code isn't valid or has expired."
            : errorMessage(err)
        )
    );
  });
  if (!ctx.restore) focusContent("#pairCode");
}

// ── Sign up ───────────────────────────────────────────────────────────

export function signupRoute(ctx: RouteContext): void {
  const s = useScreen();
  s.title("Create account", { back: true });
  const a = settings.auth;
  if (!a.signup || a.inviteOnly) {
    s.render(
      html`<section class="auth">
        ${brand()}
        <p class="notice">
          ${a.inviteOnly
            ? "This forum is invite-only."
            : "New accounts can't be created right now."}
        </p>
        <a class="btn block" href="${href("/login")}">Back to sign in</a>
      </section>`
    );
    return;
  }
  const userFields = a.userFields.filter((f) => f.show_on_signup || f.required);
  const extra: SafeHtml[] = userFields.map((f) => {
    const id = "uf" + f.id;
    const label = f.name + (f.required ? " *" : "");
    if (f.field_type === "dropdown" || f.field_type === "multiselect") {
      return field(
        id,
        label,
        html`<select
          id="${id}"
          ${f.field_type === "multiselect" ? raw(" multiple") : ""}
        >
          ${f.required ? "" : html`<option value="">—</option>`}${f.options.map(
            (o) => html`<option value="${o}">${o}</option>`
          )}
        </select>`,
        f.description ? f.description.replace(/<[^>]*>/g, "") : ""
      );
    }
    if (f.field_type === "confirm" || f.field_type === "checkbox") {
      return html`<label class="check"
        ><input id="${id}" type="checkbox" /><span
          >${label}${f.description
            ? html` — ${f.description.replace(/<[^>]*>/g, "")}`
            : ""}</span
        ></label
      >`;
    }
    return field(
      id,
      label,
      html`<input id="${id}" type="text" />`,
      f.description ? f.description.replace(/<[^>]*>/g, "") : ""
    );
  });
  const showName = a.fullNameVisible || a.fullNameRequired;
  s.render(
    html`<section class="auth">
      ${brand()} ${errorSlot()}
      <form class="card form" data-signup>
        ${field(
          "suEmail",
          "Email",
          html`<input
            id="suEmail"
            type="email"
            autocomplete="email"
            autocapitalize="off"
          />`
        )}
        ${field(
          "suUser",
          "Username",
          html`<input
            id="suUser"
            type="text"
            autocomplete="username"
            autocapitalize="off"
            autocorrect="off"
            spellcheck="false"
            maxlength="${a.usernameMax}"
          />`
        )}
        ${showName
          ? field(
              "suName",
              a.fullNameRequired ? "Full name" : "Full name (optional)",
              html`<input id="suName" type="text" autocomplete="name" />`
            )
          : ""}
        ${field(
          "suPass",
          "Password",
          html`<input
            id="suPass"
            type="password"
            autocomplete="new-password"
            placeholder="${a.passwordMin}+ characters"
          />`
        )}
        ${extra}
        ${a.hcaptchaSiteKey
          ? html`<p class="notice">
              Sign-up needs a captcha this browser may not support.
            </p>`
          : ""}
        <button type="submit" class="btn primary block" data-su-btn>
          ${icon("user")}Create account
        </button>
      </form>
      <p class="auth-links">
        Already have an account? <a href="${href("/login")}">Sign in</a>
      </p>
    </section>`
  );

  const form = $("[data-signup]") as HTMLFormElement;
  const btn = $("[data-su-btn]") as HTMLElement;
  form.addEventListener("submit", (e) => {
    e.preventDefault();
    clearError();
    const val = (id: string) => {
      const el = byId(id) as HTMLInputElement | null;
      return el ? el.value.replace(/^\s+|\s+$/g, "") : "";
    };
    const email = val("suEmail");
    const username = val("suUser");
    const name = val("suName");
    const password = (byId("suPass") as HTMLInputElement).value;
    if (!/.+@.+\..+/.test(email))
      return showError("Enter a valid email address.");
    if (username.length < a.usernameMin)
      return showError(`Usernames need at least ${a.usernameMin} characters.`);
    if (password.length < a.passwordMin)
      return showError(`Passwords need at least ${a.passwordMin} characters.`);
    if (a.fullNameRequired && !name) return showError("Enter your full name.");
    const fields: Record<string, string | string[]> = {};
    for (let i = 0; i < userFields.length; i++) {
      const f = userFields[i];
      const el = byId("uf" + f.id) as HTMLInputElement & HTMLSelectElement;
      if (!el) continue;
      let v: string | string[] = "";
      if (f.field_type === "confirm" || f.field_type === "checkbox")
        v = el.checked ? "true" : "";
      else if (f.field_type === "multiselect") {
        const picked: string[] = [];
        for (let k = 0; k < el.options.length; k++)
          if (el.options[k].selected && el.options[k].value)
            picked.push(el.options[k].value);
        v = picked;
      } else v = el.value.replace(/^\s+|\s+$/g, "");
      if (f.required && (!v || (typeof v !== "string" && !v.length)))
        return showError(`${f.name} is required.`);
      if (v && (typeof v === "string" || v.length)) fields[String(f.id)] = v;
    }
    busy(btn, true, "Creating…");
    get<{ available?: boolean; suggestion?: string; errors?: string[] }>(
      `/u/check_username.json?username=${encodeURIComponent(username)}`
    )
      .then((c) => {
        if (c && c.available === false) {
          throw new ApiError(
            c.errors && c.errors.length
              ? c.errors.join(" ")
              : `That username is taken.${c.suggestion ? " Try " + c.suggestion + "." : ""}`,
            422
          );
        }
        return honeypot();
      })
      .then((hp) =>
        post<{
          success?: boolean;
          message?: string;
          errors?: Record<string, string[]> | string[];
          active?: boolean;
        }>(
          "/u.json",
          {
            email,
            username,
            name,
            password,
            password_confirmation: hp.value,
            challenge: hp.challenge,
            user_fields: fields,
            timezone: timezone(),
          },
          { urlencoded: true }
        )
      )
      .then(
        (d) => {
          busy(btn, false);
          if (d && d.success) {
            const msg = String(
              d.message || "Account created. Check your email to activate it."
            ).replace(/<[^>]*>/g, "");
            s.render(
              html`<section class="auth">
                ${brand()}
                <p class="notice ok">${msg}</p>
                <a class="btn primary block" href="${href("/login")}"
                  >Go to sign in</a
                >
              </section>`
            );
            focusContent(".btn");
            if (d.active) finishLogin(ctx);
            return;
          }
          const errs =
            d && d.errors
              ? Object.prototype.toString.call(d.errors) === "[object Array]"
                ? (d.errors as string[])
                : flatten(d.errors as Record<string, string[]>)
              : [];
          showError(
            errs.length
              ? errs.join(" ")
              : String((d && d.message) || "Sign-up failed.").replace(
                  /<[^>]*>/g,
                  ""
                )
          );
        },
        (err: unknown) => {
          busy(btn, false);
          showError(errorMessage(err));
        }
      );
  });
  if (!ctx.restore) focusContent("#suEmail");
}

function flatten(errors: Record<string, string[]>): string[] {
  const out: string[] = [];
  for (const k in errors)
    if (errors.hasOwnProperty(k))
      for (let i = 0; i < errors[k].length; i++) out.push(errors[k][i]);
  return out;
}

// ── Password reset ────────────────────────────────────────────────────

export function forgotRoute(ctx: RouteContext): void {
  const s = useScreen();
  s.title("Reset password", { back: true });
  s.render(
    html`<section class="auth">
      ${brand()} ${errorSlot()}
      <form class="card form" data-forgot>
        ${field(
          "login",
          "Username or email",
          html`<input
            id="login"
            type="text"
            autocomplete="username"
            autocapitalize="off"
            value="${ctx.query.login || ""}"
          />`
        )}
        <button type="submit" class="btn primary block">
          ${icon("mail")}Send reset link
        </button>
      </form>
      <p class="auth-links"><a href="${href("/login")}">Back to sign in</a></p>
    </section>`
  );
  const form = $("[data-forgot]") as HTMLFormElement;
  form.addEventListener("submit", (e) => {
    e.preventDefault();
    clearError();
    const login = (byId("login") as HTMLInputElement).value.replace(
      /^\s+|\s+$/g,
      ""
    );
    if (!login) return showError("Enter your username or email.");
    post<{ error?: string }>(
      "/session/forgot_password.json",
      { login },
      { allowUnauthorized: true }
    ).then(
      (d) => {
        if (d && d.error) return showError(d.error);
        void alertDialog(
          "If that account exists, a link is on its way.",
          "Check your email"
        );
      },
      (err: unknown) => showError(errorMessage(err))
    );
  });
  if (!ctx.restore) focusContent("#login");
}

export function resetTokenRoute(ctx: RouteContext): Promise<void> {
  const s = useScreen();
  const token = ctx.params.token || "";
  s.title("New password", { back: false });
  s.loading();
  return get<{
    second_factor_required?: boolean;
    security_key_required?: boolean;
    backup_enabled?: boolean;
  }>(`/u/password-reset/${encodeURIComponent(token)}.json`, {
    allowUnauthorized: true,
  }).then(
    (info) => {
      if (!s.alive()) return;
      s.render(
        html`<section class="auth">
          ${brand()} ${errorSlot()}
          <form class="card form" data-reset>
            ${field(
              "newPass",
              "New password",
              html`<input
                id="newPass"
                type="password"
                autocomplete="new-password"
                placeholder="${settings.auth.passwordMin}+ characters"
              />`
            )}
            ${info.second_factor_required || info.security_key_required
              ? field(
                  "tfaCode",
                  "Two-factor code",
                  html`<input
                    id="tfaCode"
                    type="tel"
                    inputmode="numeric"
                    maxlength="16"
                  />`
                )
              : ""}
            <button type="submit" class="btn primary block">
              ${icon("check")}Save password
            </button>
          </form>
        </section>`
      );
      const form = $("[data-reset]") as HTMLFormElement;
      form.addEventListener("submit", (e) => {
        e.preventDefault();
        clearError();
        const password = (byId("newPass") as HTMLInputElement).value;
        if (password.length < settings.auth.passwordMin)
          return showError(`At least ${settings.auth.passwordMin} characters.`);
        const body: Record<string, unknown> = {
          password,
          timezone: timezone(),
        };
        const tfa = byId("tfaCode") as HTMLInputElement | null;
        if (tfa && tfa.value) {
          const code = tfa.value.replace(/\s+/g, "");
          body.second_factor_token = code;
          body.second_factor_method = /^\d{6}$/.test(code) ? 1 : 2;
        }
        put<{
          success?: boolean;
          message?: string;
          errors?: Record<string, string[]>;
          requires_approval?: boolean;
        }>(`/u/password-reset/${encodeURIComponent(token)}.json`, body, {
          allowUnauthorized: true,
        }).then(
          (d) => {
            if (d && d.success) {
              toast("Password saved.", "success");
              if (d.requires_approval) {
                s.render(
                  html`<section class="auth">
                    ${brand()}
                    <p class="notice ok">
                      Password saved. Your account is awaiting approval.
                    </p>
                  </section>`
                );
                return;
              }
              finishLogin(ctx);
              return;
            }
            showError(
              d && d.errors
                ? flatten(d.errors).join(" ")
                : String((d && d.message) || "Couldn't save that password.")
            );
          },
          (err: unknown) => showError(errorMessage(err))
        );
      });
      focusContent("#newPass");
    },
    (e: unknown) => s.error(errorMessage(e))
  );
}

// ── Account activation ────────────────────────────────────────────────

export function activateRoute(ctx: RouteContext): void {
  const s = useScreen();
  const token = ctx.params.token || "";
  s.title("Activate account", { back: false });
  s.render(
    html`<section class="auth">
      ${brand()} ${errorSlot()}
      <button type="button" class="btn primary block" data-act="activate">
        ${icon("check")}Activate my account
      </button>
    </section>`
  );
  s.act("activate", (el) => {
    busy(el, true, "Activating…");
    honeypot()
      .then((hp) =>
        put<{
          success?: boolean;
          message?: string;
          needs_approval?: boolean;
          redirect_to?: string;
        }>(
          `/u/activate-account/${encodeURIComponent(token)}.json`,
          { password_confirmation: hp.value, challenge: hp.challenge },
          { allowUnauthorized: true }
        )
      )
      .then(
        (d) => {
          busy(el, false);
          if (d && d.needs_approval) {
            s.render(
              html`<section class="auth">
                ${brand()}
                <p class="notice ok">
                  Activated. Your account is awaiting approval.
                </p>
              </section>`
            );
            return;
          }
          toast("Account activated.", "success");
          finishLogin(ctx);
        },
        (err: unknown) => {
          busy(el, false);
          showError(errorMessage(err));
        }
      );
  });
  focusContent("[data-act=activate]");
}

// ── Log out / full site ───────────────────────────────────────────────

export function logoutRoute(ctx: RouteContext): void {
  const s = useScreen();
  s.title("Log out", { back: true });
  if (!user) {
    location.replace(APP_ROOT + "/login");
    return;
  }
  const leave = () => {
    s.loading("Logging out…");
    unregisterPush()
      .then(() => endSession())
      .then(() => {
        refreshCsrf().then(
          () => location.replace(APP_ROOT + "/login"),
          () => location.replace(APP_ROOT + "/login")
        );
      });
  };
  if (ctx.query.expired === "1") {
    leave();
    return;
  }
  confirmDialog(`Log out? Drafts on this phone are deleted.`, {
    ok: "Log out",
    danger: true,
  }).then((ok) => {
    if (ok) leave();
    else go("/", { replace: true });
  });
}

export function fullSiteRoute(): void {
  // An explicit choice: stop sending this phone to Dumbcourse.
  setPreferDumbcourse(false);
  location.href = (settings.subfolder || "") + "/";
}
