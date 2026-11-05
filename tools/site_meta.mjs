// What a page says when it is shared, and the files around the pages. Run when the site is deployed (.github/workflows/pages.yml):
//   node tools/site_meta.mjs <site> <out>
// Every page of <out> (a copy of <site>, or <site> itself) gets its canonical address, Open Graph and Twitter tags, from its own
// title and description; the home page its structured data. A redirect or a page marked noindex is left alone. Writes feed.xml
// (Atom, from CHANGELOG.md), sitemap.xml, site.webmanifest, llms.txt and a 404.html if there is none.
// The sharing card, site/img/card.png, is drawn once and kept in the repository: node tools/site_meta.mjs --card

const C = {
  name: 'Wren',
  site: 'https://wren.froment.software/',
  repository: 'https://github.com/sachahjkl/wren',
  tagline: 'A browser where WebAssembly runs everything, JavaScript included',
  card: 'img/card.png',
  logo: 'img/logo.png',
  logoFile: 'site/img/logo.png',
  changelog: 'changelog/',
  anchor: (v) => 'v' + v.replaceAll('.', '-'),
  theme: '#121212',
  accent: '#f39a2e',
  cardTitle: 'Wren',
  cardSize: 190,
  cardLogo: 150,
  ldType: 'SoftwareApplication',
  ld: { applicationCategory: 'BrowserApplication', operatingSystem: 'Windows, Linux' },
  rootDomain: true,
  ico: 'assets/wren.ico',
}

import { execFileSync } from 'node:child_process'
import { copyFileSync, cpSync, existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const FEED_VERSIONS = 30
const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')

// The card: --card draws it, in a local Chromium, once. The site only carries the picture.
function card() {
  const browser = [
    process.env.CHROME,
    'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
    'C:/Program Files/Google/Chrome/Application/chrome.exe',
    '/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser',
  ].find((p) => p && existsSync(p))
  if (!browser) { console.error('no Chromium found: set CHROME'); process.exit(2) }
  const dir = mkdtempSync(join(tmpdir(), 'site-card-'))
  try {
    const page = join(dir, 'card.html')
    writeFileSync(page, `<!doctype html><meta charset="utf-8"><style>
${C.cardFont ?? ''}
html, body { margin: 0; width: 1200px; height: 630px; overflow: hidden; background: #111; color: #f2f2f2; }
main { box-sizing: border-box; width: 1200px; height: 630px; padding: 0 72px 68px; display: flex; flex-direction: column; justify-content: flex-end;
  font-family: ${C.cardFamily ?? '"Segoe UI Variable Display", "Segoe UI", sans-serif'}; }
img { display: block; width: ${C.cardLogo ?? 168}px; height: ${C.cardLogo ?? 168}px; margin: 0 0 18px -6px; }
h1 { margin: 0; font-size: ${C.cardSize}px; line-height: 1.02; font-weight: 700; letter-spacing: -0.035em; }
h1 span { color: #8a8a8a; } h1 em { font-style: normal; color: ${C.accent}; }
p { margin: 22px 0 0; font-size: 42px; line-height: 1.2; font-weight: 400; color: #a3a3a3; }
</style><main><img src="${pathToFileURL(join(repo, C.logoFile)).href}" alt=""><h1>${C.cardTitle}</h1><p>${C.tagline}</p></main>`)
    execFileSync(browser, ['--headless=new', '--disable-gpu', '--hide-scrollbars', '--allow-file-access-from-files', `--user-data-dir=${join(dir, 'profile')}`,
      '--virtual-time-budget=5000', '--force-device-scale-factor=1', '--window-size=1200,630', `--screenshot=${join(dir, 'out.png')}`, pathToFileURL(page).href], { stdio: 'ignore' })
    copyFileSync(join(dir, 'out.png'), join(repo, 'site', C.card))
    console.log('site/' + C.card)
  } finally {
    rmSync(dir, { recursive: true, force: true, maxRetries: 5 })
  }
}

// CHANGELOG.md: "## [x.y.z] - date", then its text.
function versions() {
  const out = []
  let r = null
  for (const l of readFileSync(join(repo, 'CHANGELOG.md'), 'utf8').split(/\r?\n/)) {
    const h = l.match(/^## \[([^\]]+)\](?: - (\d{4}-\d{2}-\d{2}))?/)
    if (h) { r = h[2] ? { version: h[1], date: h[2], lines: [] } : null; if (r) out.push(r); continue }
    if (/^## /.test(l) || /^\[[^\]]+\]:/.test(l)) { r = null; continue }
    if (r) r.lines.push(l)
  }
  return out
}

function inline(text) {
  const code = []
  const s = esc(text.replace(/`([^`]+)`/g, (_, c) => { code.push(`<code>${esc(c)}</code>`); return `\u0001${code.length - 1}\u0002` }))
  return s.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>').replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g, '<a href="$2">$1</a>').replace(/\u0001(\d+)\u0002/g, (_, i) => code[+i])
}

// A version's text as HTML: its headings and its entries, an entry possibly on several lines.
function body(lines) {
  const out = []
  let item = null
  const flush = () => { if (item !== null) { out.push(`<li>${inline(item)}</li>`); item = null } }
  for (const raw of lines) {
    const l = raw.trim()
    const h = l.match(/^### (.+)$/)
    const m = l.match(/^- (.*)$/)
    if (h) { flush(); out.push(`<h3>${esc(h[1])}</h3>`) }
    else if (m) { flush(); item = m[1] }
    else if (!l) flush()
    else if (item !== null) item += ' ' + l
    else out.push(`<p>${inline(l)}</p>`)
  }
  flush()
  return out.join('').replace(/(<li>.*?<\/li>)+/g, (list) => `<ul>${list}</ul>`)
}

const feed = (rs) => `<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <id>${C.site}</id>
  <title>${esc(C.name)}: releases</title>
  <subtitle>${esc(C.tagline)}</subtitle>
  <link rel="self" type="application/atom+xml" href="${C.site}feed.xml"/>
  <link rel="alternate" type="text/html" href="${C.site}"/>
  <icon>${C.site}${C.logo}</icon>
  <author><name>Sacha Froment</name><uri>https://froment.software</uri></author>
  <updated>${rs[0].date}T00:00:00Z</updated>
${rs.map((r) => `  <entry>
    <id>${C.site}${C.changelog}#${C.anchor(r.version)}</id>
    <title>${esc(C.name)} ${esc(r.version)}</title>
    <link rel="alternate" type="text/html" href="${C.site}${C.changelog}#${C.anchor(r.version)}"/>
    <updated>${r.date}T00:00:00Z</updated>
    <content type="html">${esc(body(r.lines))}</content>
  </entry>`).join('\n')}
</feed>
`

const data = () => JSON.stringify({
  '@context': 'https://schema.org',
  '@type': C.ldType,
  name: C.name,
  description: C.tagline,
  url: C.site,
  image: C.site + C.card,
  ...C.ld,
  author: { '@type': 'Person', name: 'Sacha Froment', url: 'https://froment.software' },
  publisher: { '@type': 'Organization', name: 'Froment Software', url: 'https://froment.software' },
}, null, 2)

const pick = (html, re) => (html.match(re) ?? [])[1]

function tags(html, address, home) {
  const title = pick(html, /<title>([^<]*)<\/title>/) ?? C.name
  const description = pick(html, /<meta name="description" content="([^"]*)"/) ?? esc(C.tagline)
  const alt = esc(`${C.name}: ${C.tagline}`)
  const image = C.site + C.card
  return [
    html.includes('rel="canonical"') ? '' : `<link rel="canonical" href="${address}">`,
    '<meta name="author" content="Sacha Froment">',
    `<meta name="theme-color" content="${C.theme}">`,
    `<link rel="alternate" type="application/atom+xml" title="${esc(C.name)}: releases" href="${C.site}feed.xml">`,
    `<link rel="apple-touch-icon" href="${C.site}${C.logo}">`,
    `<link rel="manifest" href="${C.site}site.webmanifest">`,
    `<meta property="og:type" content="${home ? 'website' : 'article'}">`,
    `<meta property="og:site_name" content="${esc(C.name)}">`,
    '<meta property="og:locale" content="en_US">',
    `<meta property="og:title" content="${title}">`,
    `<meta property="og:description" content="${description}">`,
    `<meta property="og:url" content="${address}">`,
    `<meta property="og:image" content="${image}">`,
    `<meta property="og:image:secure_url" content="${image}">`,
    '<meta property="og:image:type" content="image/png">',
    '<meta property="og:image:width" content="1200">',
    '<meta property="og:image:height" content="630">',
    `<meta property="og:image:alt" content="${alt}">`,
    '<meta name="twitter:card" content="summary_large_image">',
    `<meta name="twitter:title" content="${title}">`,
    `<meta name="twitter:description" content="${description}">`,
    `<meta name="twitter:image" content="${image}">`,
    `<meta name="twitter:image:alt" content="${alt}">`,
    home ? `<script type="application/ld+json">\n${data()}\n</script>` : '',
  ].filter(Boolean).join('\n')
}

const pngSize = (file) => { const b = readFileSync(file); return `${b.readUInt32BE(16)}x${b.readUInt32BE(20)}` }

function publish(from, out) {
  if (resolve(from) !== resolve(out)) cpSync(from, out, { recursive: true })
  if (!existsSync(join(out, C.card))) { console.error(`no ${C.card}: node tools/site_meta.mjs --card`); process.exit(1) }

  const listed = []
  const pages = readdirSync(out, { recursive: true }).map((f) => f.replaceAll('\\', '/')).filter((f) => f.endsWith('.html') && f !== '404.html')
  for (const page of pages) {
    const path = join(out, page)
    const html = readFileSync(path, 'utf8')
    if (!html.includes('</head>') || /<meta name="robots" content="noindex|http-equiv="refresh"/i.test(html)) continue
    const address = C.site + page.replace(/(^|\/)index\.html$/, '$1')
    writeFileSync(path, html.replace('</head>', () => `${tags(html, address, page === 'index.html')}\n</head>`))
    listed.push(address)
  }

  const rs = versions()
  if (!rs.length) { console.error('no version in CHANGELOG.md'); process.exit(1) }
  writeFileSync(join(out, 'feed.xml'), feed(rs.slice(0, FEED_VERSIONS)))
  writeFileSync(join(out, 'sitemap.xml'), `<?xml version="1.0" encoding="utf-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${listed.sort().map((a) => `  <url><loc>${a}</loc></url>`).join('\n')}
</urlset>
`)
  writeFileSync(join(out, 'site.webmanifest'), JSON.stringify({
    name: C.name, short_name: C.name, description: C.tagline, lang: 'en', start_url: './', scope: './', display: 'browser',
    background_color: C.theme, theme_color: C.theme,
    icons: [{ src: C.logo, sizes: pngSize(join(out, C.logo)), type: 'image/png' }],
  }, null, 2) + '\n')
  writeFileSync(join(out, 'llms.txt'), `# ${C.name}

> ${C.tagline}

## Pages

- [${C.name}](${C.site}): the home page.
- [Changelog](${C.site}${C.changelog}): every version.
- [Releases feed](${C.site}feed.xml): new versions, in Atom.
- [Source](${C.repository}): the repository.
`)
  if (!existsSync(join(out, '404.html'))) writeFileSync(join(out, '404.html'), `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<meta name="color-scheme" content="dark">
<title>Not found · ${esc(C.name)}</title>
<link rel="icon" href="${C.site}${C.logo}">
<style>
html { background: ${C.theme}; color: #e6e6e6; font: 18px/1.5 system-ui, sans-serif; }
body { margin: 18vh auto 0; padding: 0 24px; max-width: 34rem; }
img { display: block; width: 72px; height: 72px; }
h1 { margin: 20px 0 8px; font-size: 2.2rem; }
a { color: ${C.accent}; }
</style>
</head>
<body>
<img src="${C.site}${C.logo}" alt="">
<h1>Not found</h1>
<p>This page does not exist. <a href="${C.site}">${esc(C.name)}</a></p>
</body>
</html>
`)
  if (C.rootDomain) {
    writeFileSync(join(out, 'robots.txt'), `User-agent: *\nAllow: /\n\nSitemap: ${C.site}sitemap.xml\n`)
    if (C.ico) copyFileSync(join(repo, C.ico), join(out, 'favicon.ico'))
  }
  console.log(`${listed.length} pages, ${Math.min(rs.length, FEED_VERSIONS)} versions in the feed: ${out}`)
}

const args = process.argv.slice(2)
if (args[0] === '--card') card()
else if (args.length === 2) publish(args[0], args[1])
else { console.error('usage: node tools/site_meta.mjs <site> <out> | --card'); process.exit(2) }
