#!/usr/bin/env node
// Lightweight search crawler (no API key)
// Usage: node ops/search_crawler.mjs "freedom.gov State Department"

const query = process.argv.slice(2).join(' ').trim();
if (!query) {
  console.error('Usage: node ops/search_crawler.mjs "<query>"');
  process.exit(1);
}

const UA = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36';

function stripTags(s = '') {
  return s.replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function decodeEntities(s = '') {
  return s
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>');
}

async function get(url) {
  const res = await fetch(url, {
    headers: { 'user-agent': UA, 'accept-language': 'en-US,en;q=0.9' },
    redirect: 'follow',
  });
  const text = await res.text();
  return { url: res.url, status: res.status, text };
}

function parseGoogle(html) {
  const blocked = /google\.com\/sorry|unusual traffic|not a robot|recaptcha/i.test(html);
  const out = [];
  const re = /<a href="\/url\?q=([^"&]+)[^"]*"[^>]*>([\s\S]*?)<\/a>/gi;
  let m;
  while ((m = re.exec(html)) && out.length < 10) {
    const href = decodeURIComponent(m[1]);
    if (!/^https?:\/\//i.test(href)) continue;
    const title = decodeEntities(stripTags(m[2]));
    if (!title) continue;
    out.push({ title, url: href });
  }
  return { blocked, results: out };
}

function parseBing(html) {
  const out = [];
  const re = /<li class="b_algo"[\s\S]*?<h2><a href="([^"]+)"[^>]*>([\s\S]*?)<\/a><\/h2>/gi;
  let m;
  while ((m = re.exec(html)) && out.length < 10) {
    out.push({ title: decodeEntities(stripTags(m[2])), url: decodeEntities(m[1]) });
  }
  return { blocked: false, results: out };
}

function parseDDG(html) {
  const out = [];
  const re = /<a[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/gi;
  let m;
  while ((m = re.exec(html)) && out.length < 10) {
    out.push({ title: decodeEntities(stripTags(m[2])), url: decodeEntities(m[1]) });
  }
  return { blocked: /captcha|challenge|robot/i.test(html), results: out };
}

(async () => {
  const q = encodeURIComponent(query);
  const targets = [
    { name: 'google', url: `https://www.google.com/search?q=${q}&hl=en` , parse: parseGoogle},
    { name: 'bing', url: `https://www.bing.com/search?q=${q}` , parse: parseBing},
    { name: 'duckduckgo', url: `https://duckduckgo.com/html/?q=${q}` , parse: parseDDG},
  ];

  const report = [];
  for (const t of targets) {
    try {
      const { url, status, text } = await get(t.url);
      const parsed = t.parse(text);
      report.push({
        engine: t.name,
        status,
        finalUrl: url,
        blocked: !!parsed.blocked,
        results: parsed.results,
      });
    } catch (err) {
      report.push({ engine: t.name, error: String(err) });
    }
  }

  console.log(JSON.stringify({ query, at: new Date().toISOString(), report }, null, 2));
})();