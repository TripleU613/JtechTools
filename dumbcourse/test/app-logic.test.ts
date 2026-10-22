// Logic from modules that expect a browser; stub-dom provides one.
import assert from "node:assert/strict";
import { before, test } from "node:test";

type Reqpm = typeof import("../src/views/reqpm.ts");
type Composer = typeof import("../src/views/composer.ts");
type Router = typeof import("../src/router.ts");
type Emoji = typeof import("../src/content/emoji.ts");
type Cooked = typeof import("../src/content/cooked.ts");

let reqpm: Reqpm;
let composer: Composer;
let router: Router;
let emoji: Emoji;
let cooked: Cooked;

before(async () => {
  await import("./stub-dom.ts");
  reqpm = await import("../src/views/reqpm.ts");
  composer = await import("../src/views/composer.ts");
  router = await import("../src/router.ts");
  emoji = await import("../src/content/emoji.ts");
  cooked = await import("../src/content/cooked.ts");
});

const m = (kind: string, value: string) => ({ id: 1, kind, value });

test("REQ-PM: numbers without a country code dial as +1", () => {
  assert.deepEqual(reqpm.actionFor(m("phone", "(718) 555-0100"), "1"), {
    href: "tel:+17185550100",
    label: "Call",
  });
  assert.deepEqual(reqpm.actionFor(m("sms", "+972 52 123 4567"), "1"), {
    href: "sms:+972521234567",
    label: "Text",
  });
  assert.deepEqual(reqpm.actionFor(m("whatsapp", "646-820-1413"), "1"), {
    href: "https://wa.me/16468201413",
    label: "WhatsApp",
  });
  assert.equal(
    reqpm.actionFor(m("whatsapp", "052-123-4567"), "1"),
    null,
    "local format: no guessing"
  );
});

test("REQ-PM: a WhatsApp username is copy only", () => {
  assert.equal(reqpm.actionFor(m("whatsapp", "@jtech.user"), "1"), null);
  assert.equal(
    reqpm.actionFor(m("whatsapp", "jtech6468201413"), "1"),
    null,
    "digits in a username are not a number"
  );
});

test("REQ-PM: only safe links", () => {
  assert.equal(reqpm.actionFor(m("email", "a@b.co?cc=evil@x.com"), "1"), null);
  assert.deepEqual(reqpm.actionFor(m("email", "a@b.co"), "1"), {
    href: "mailto:a@b.co",
    label: "Email",
  });
  assert.equal(reqpm.actionFor(m("website", "javascript:alert(1)"), "1"), null);
  assert.equal(reqpm.actionFor(m("custom", "Ask at the desk"), "1"), null);
  assert.deepEqual(reqpm.actionFor(m("telegram", "@jtech_user"), "1"), {
    href: "https://t.me/jtech_user",
    label: "Telegram",
  });
  assert.equal(reqpm.actionFor(m("discord", "someone#1234"), "1"), null);
});

test("LanguageTool fixes apply back to front and skip overlaps", () => {
  const text = "teh cat sat on teh mat";
  const out = composer.applyFixes(text, [
    { offset: 0, length: 3, replacements: [{ value: "the" }] },
    { offset: 15, length: 3, replacements: [{ value: "the" }] },
    { offset: 1, length: 4, replacements: [{ value: "X" }] },
    { offset: 4, length: 3, replacements: [] },
  ]);
  assert.equal(out, "the cat sat on the mat");
});

test("query strings", () => {
  assert.deepEqual(router.parseQuery("?q=flip+phone&page=2&x=a%3Db"), {
    q: "flip phone",
    page: "2",
    x: "a=b",
  });
  assert.equal(
    router.buildQuery({ q: "a b", page: null, n: 3 }),
    "?q=a%20b&n=3"
  );
  assert.equal(router.buildQuery({}), "");
  assert.equal(router.href("/t/5"), "/dumb/t/5");
});

test("emojify escapes text and turns shortcodes into images", () => {
  const out = emoji.emojify(`<b>hi</b> :smile: :not a code:`).value;
  assert.ok(out.indexOf("&lt;b&gt;hi&lt;/b&gt; <img") === 0, out);
  assert.match(out, /class="emoji"/);
  assert.match(out, /src="\/images\/emoji\/twitter\/smile\.png\?v=15"/);
  assert.match(out, /:not a code:$/);
  assert.deepEqual(
    emoji.searchEmoji(["grin", "smile", "smiley", "cat_smile"], "smile"),
    ["smile", "smiley", "cat_smile"]
  );
});

test("search highlighting escapes and never splits an entity", async () => {
  const search = await import("../src/views/search.ts");
  assert.equal(
    search.highlight("Tom & <Jerry> battery", "amp battery").value,
    "Tom &amp; &lt;Jerry&gt; <mark>battery</mark>"
  );
  assert.equal(search.highlight("a <b>", "in:title @me").value, "a &lt;b&gt;");
});

test("forum links map to Dumbcourse screens", () => {
  assert.equal(cooked.appPathFor("/t/some-topic/12/3"), "/t/some-topic/12/3");
  assert.equal(cooked.appPathFor("https://forum.example/u/alice"), "/u/alice");
  assert.equal(cooked.appPathFor("/my/bookmarks"), "/bookmarks");
  assert.equal(cooked.appPathFor("/dumb/notifications"), "/notifications");
  assert.equal(cooked.appPathFor("/admin/users"), null);
  assert.equal(cooked.appPathFor("https://elsewhere.example/t/1"), null);
  assert.equal(cooked.appPathFor("//evil.example/t/1"), null);
  assert.equal(cooked.appPathFor("javascript:alert(1)"), null);
});
