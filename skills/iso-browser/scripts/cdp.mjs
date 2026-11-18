// One long-lived CDP connection to the user's own Chrome, driven op by op.
//
//   node cdp.mjs [port]          start; prints "waiting for Allow", then "connected"
//   curl -s -X POST 127.0.0.1:9334 -d '{"op":"tabs"}'
//
// Chrome (autoConnect) asks "Allow remote debugging?" once per connection, and
// the connect call hangs until the user answers. One process, kept for the
// whole session, means one prompt. Ops:
//   tabs                       list open pages (index, url, title)
//   use   {url}                adopt the open tab whose URL contains `url`
//   open  {url}                open ONE new tab (only after the user agreed)
//   goto  {url}                navigate the current tab
//   text                       visible text of the current tab (first 6000 chars)
//   shot  {out}                screenshot of the current tab to `out`
//   eval  {js}                 evaluate `js` in the page, return the result
//   click {selector|text|x,y}  click, then wait briefly
//   type  {text, selector?}    fill `selector`, or type at the focus
//   key   {key}                press a key ("Enter", "Meta+A")
//   done                       close the tab this helper opened (never a user's), exit
// Playwright is resolved from the current directory's project, so run it from
// a repository that has `@playwright/test` (or `playwright`) installed.
import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import { createRequire } from "node:module";
import { homedir } from "node:os";
import { join } from "node:path";

const PORT = Number(process.argv[2] ?? 9334);
const ALLOW_TIMEOUT_MS = 120_000;
const ACTIVE_PORT = {
  darwin: "Library/Application Support/Google/Chrome/DevToolsActivePort",
  linux: ".config/google-chrome/DevToolsActivePort",
  win32: "AppData/Local/Google/Chrome/User Data/DevToolsActivePort",
}[process.platform];

const require = createRequire(join(process.cwd(), "package.json"));
const load = (name) => {
  try {
    return require(name);
  } catch {
    return null;
  }
};
const { chromium } = load("@playwright/test") ?? load("playwright") ?? {};
if (!chromium) {
  console.error("no playwright here: run from a project that installs @playwright/test");
  process.exit(2);
}

// autoConnect answers 404 on /json/version; the file names the live socket.
const [cdpPort, cdpPath] = readFileSync(join(homedir(), ACTIVE_PORT), "utf8").split("\n");
console.log("waiting for Allow: ask the user to click Allow in Chrome now");
const browser = await chromium.connectOverCDP(`ws://127.0.0.1:${cdpPort}${cdpPath}`, {
  timeout: ALLOW_TIMEOUT_MS,
});
browser.on("disconnected", () => process.exit(1));
const [context] = browser.contexts();
let page = null;
let opened = null;
console.log("connected");

const current = () => {
  if (!page) {
    throw new Error("no tab: `use` an open one, or `open` one the user agreed to");
  }
  return page;
};

const ops = {
  click: async ({ selector, text, x, y }) => {
    const p = current();
    if (selector) {
      await p.locator(selector).first().click();
    } else if (text) {
      await p.getByText(text).first().click();
    } else {
      await p.mouse.click(x, y);
    }
    await p.waitForTimeout(800);
    return "ok";
  },
  done: async () => {
    if (opened) {
      await opened.close();
    }
    setTimeout(() => process.exit(0), 100);
    return opened ? "closed the tab it opened" : "left every tab open";
  },
  eval: async ({ js }) => current().evaluate(js),
  goto: async ({ url }) => {
    await current().goto(url, { timeout: 60_000, waitUntil: "networkidle" });
    return current().url();
  },
  key: async ({ key }) => {
    await current().keyboard.press(key);
    await current().waitForTimeout(400);
    return "ok";
  },
  open: async ({ url }) => {
    opened = await context.newPage();
    page = opened;
    if (url) {
      await page.goto(url, { timeout: 60_000, waitUntil: "networkidle" });
    }
    return page.url();
  },
  shot: async ({ out }) => {
    await current().screenshot({ path: out });
    return out;
  },
  tabs: async () =>
    Promise.all(
      context.pages().map(async (p, index) => ({ index, title: await p.title(), url: p.url() }))
    ),
  text: async () => (await current().innerText("body")).slice(0, 6000),
  type: async ({ selector, text }) => {
    const p = current();
    if (selector) {
      await p.locator(selector).first().fill(text);
    } else {
      await p.keyboard.insertText(text);
    }
    await p.waitForTimeout(400);
    return "ok";
  },
  use: ({ url }) => {
    const matches = context.pages().filter((p) => p.url().includes(url));
    if (matches.length !== 1) {
      throw new Error(`${matches.length} tabs match ${url}: ask the user which one`);
    }
    [page] = matches;
    return page.url();
  },
};

createServer((req, res) => {
  let body = "";
  req.on("data", (chunk) => {
    body += chunk;
  });
  req.on("end", async () => {
    try {
      const spec = JSON.parse(body);
      const op = ops[spec.op];
      if (!op) {
        throw new Error(`unknown op ${spec.op}`);
      }
      res.end(JSON.stringify({ out: await op(spec) }));
    } catch (error) {
      res.end(JSON.stringify({ error: String(error) }));
    }
  });
}).listen(PORT, "127.0.0.1");
