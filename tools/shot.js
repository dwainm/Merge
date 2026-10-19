#!/usr/bin/env node
// Screenshots of a gitastic server at desktop and phone width.
//
//   NODE_PATH=/root/projects/dwainm.github.io/node_modules \
//   node tools/shot.js --url http://localhost:PORT --out /tmp/gitastic-shots [--full] /path/one ...
//
// Writes <out>/<path-slug>.desktop.png (1280x800, full page) and <out>/<path-slug>.phone.png
// (390x844, the viewport; --full for the whole page).
const fs = require("fs");
const path = require("path");
const puppeteer = require("puppeteer-core");

const argv = process.argv.slice(2);
const opt = { paths: [] };
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === "--url") opt.url = argv[++i];
  else if (a === "--out") opt.out = argv[++i];
  else if (a === "--full") opt.full = true;
  else opt.paths.push(a);
}
if (!opt.url || !opt.out || opt.paths.length === 0) {
  console.error("usage: shot.js --url URL --out DIR [--full] PATH...");
  process.exit(2);
}
const base = opt.url.replace(/\/$/, "");
fs.mkdirSync(opt.out, { recursive: true });

const viewports = {
  desktop: { width: 1280, height: 800, deviceScaleFactor: 1 },
  phone: { width: 390, height: 844, deviceScaleFactor: 2, isMobile: true, hasTouch: true },
};
const slug = (p) => (p.replace(/^\//, "").replace(/[^a-zA-Z0-9]+/g, "-").replace(/-+$/, "") || "home");

(async () => {
  const browser = await puppeteer.launch({
    executablePath: "/usr/bin/chromium",
    headless: true,
    args: ["--no-sandbox", "--disable-gpu"],
  });
  try {
    for (const [size, viewport] of Object.entries(viewports)) {
      const page = await browser.newPage();
      await page.setViewport(viewport);
      for (const p of opt.paths) {
        await page.goto(`${base}${p}`, { waitUntil: "networkidle0" });
        await new Promise((r) => setTimeout(r, 400)); // let LiveView connect
        const file = path.join(opt.out, `${slug(p)}.${size}.png`);
        await page.screenshot({ path: file, fullPage: size === "desktop" || !!opt.full });
        console.log(file);
      }
      await page.close();
    }
  } finally {
    await browser.close();
  }
})().catch((e) => { console.error(e.message); process.exit(1); });
