#!/usr/bin/env node
/**
 * AIVISE Build Script for GitHub Pages
 *
 * Fetches data from AIHOT API, injects into index.html template,
 * and outputs static HTML to the docs/ directory.
 *
 * Usage: node build.js
 */

const https = require('https');
const http = require('http');
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

// ===== Configuration =====
const API_BASE = 'https://aihot.virxact.com/api/public/items';
const TEMPLATE_FILE = path.join(__dirname, 'index.html');
const OUTPUT_DIR = path.join(__dirname, 'docs');
const OUTPUT_FILE = path.join(OUTPUT_DIR, 'index.html');
const USER_AGENT = 'AIVISE-GitHub-Bot/1.0 (+https://github.com/your-username/aihot-website)';

// API params per OpenAPI 3.1 spec
const API_MODE = 'selected';
const API_TAKE = 100; // max per OpenAPI spec
const API_DAYS_BACK = 7; // fetch 7 days of data for static site

// ===== Fetch with User-Agent =====
function fetchWithUA(url) {
  return new Promise((resolve, reject) => {
    const parsed = new URL(url);
    const lib = parsed.protocol === 'https:' ? https : http;

    const options = {
      hostname: parsed.hostname,
      port: parsed.port || (parsed.protocol === 'https:' ? 443 : 80),
      path: parsed.pathname + parsed.search,
      method: 'GET',
      headers: {
        'User-Agent': USER_AGENT,
        'Accept': 'application/json',
      },
      timeout: 30000,
    };

    const req = lib.request(options, (res) => {
      // Handle redirects
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        return fetchWithUA(res.headers.location).then(resolve).catch(reject);
      }

      if (res.statusCode !== 200) {
        let body = '';
        res.on('data', chunk => body += chunk);
        res.on('end', () => {
          reject(new Error(`HTTP ${res.statusCode}: ${body.slice(0, 500)}`));
        });
        return;
      }

      let body = '';
      res.on('data', chunk => body += chunk);
      res.on('end', () => {
        try {
          resolve(JSON.parse(body));
        } catch (e) {
          reject(new Error(`Failed to parse JSON: ${body.slice(0, 500)}`));
        }
      });
    });

    req.on('timeout', () => {
      req.destroy();
      reject(new Error('Request timeout (30s)'));
    });

    req.on('error', reject);
    req.end();
  });
}

// ===== Fetch all items with cursor pagination =====
async function fetchAllItems() {
  console.log('[1/3] Fetching data from AIHOT API...');

  const since = new Date(Date.now() - API_DAYS_BACK * 86400000).toISOString();
  let allItems = [];
  let cursor = null;
  let page = 1;

  while (true) {
    const params = new URLSearchParams({
      mode: API_MODE,
      take: API_TAKE,
      since: since,
    });
    if (cursor) {
      params.set('cursor', cursor);
    }

    const url = `${API_BASE}?${params.toString()}`;
    console.log(`  Page ${page}: fetching...`);

    const data = await fetchWithUA(url);
    const items = data.items || [];
    allItems = allItems.concat(items);

    console.log(`  Page ${page}: got ${items.length} items (total: ${allItems.length})`);

    if (!data.hasNext || !data.nextCursor) {
      break;
    }
    cursor = data.nextCursor;
    page++;

    // Safety limit: max 10 pages
    if (page > 10) {
      console.log('  Safety limit reached (10 pages)');
      break;
    }
  }

  console.log(`  Fetched ${allItems.length} total items\n`);
  return allItems;
}

// ===== Build HTML =====
function buildHtml(items) {
  console.log('[2/3] Building static HTML...');

  const template = fs.readFileSync(TEMPLATE_FILE, 'utf-8');
  const buildTime = new Date().toISOString();

  // Sanitize items: ensure all fields are serializable, remove circular refs
  const sanitizedItems = items.map(item => ({
    id: item.id || '',
    title: item.title || '',
    summary: item.summary || '',
    url: item.url || '',
    source: item.source || '',
    category: item.category || '',
    publishedAt: item.publishedAt || buildTime,
    image: item.image || '',
  }));

  // Build the data object
  const buildData = {
    buildTime: buildTime,
    apiSource: 'AIHOT Public API',
    items: sanitizedItems,
  };

  // JSON.stringify produces valid JSON; only escape backticks for JS const injection
  const jsonData = JSON.stringify(buildData).replace(/`/g, '\\`');

  // Inject BUILD_DATA constant before the </script> tag
  // The template already has __EMBEDDED_DATA__ = typeof BUILD_DATA !== 'undefined' ? BUILD_DATA : null;
  // We define BUILD_DATA as a const before that line
  const buildDataDef = `const BUILD_DATA = ${jsonData};\n`;

  // Find the line with __EMBEDDED_DATA__ and insert BUILD_DATA before it
  const embedMarker = "__EMBEDDED_DATA__";
  const markerIndex = template.indexOf(embedMarker);

  if (markerIndex === -1) {
    // Fallback: insert before </script>
    const lastScriptEnd = template.lastIndexOf('</script>');
    if (lastScriptEnd === -1) {
      throw new Error('Cannot find injection point in template');
    }
    const result = template.slice(0, lastScriptEnd) + '\n' + buildDataDef + template.slice(lastScriptEnd);
    return result;
  }

  // Find the start of the line containing __EMBEDDED_DATA__
  const lineStart = template.lastIndexOf('\n', markerIndex - 1) + 1;
  const result = template.slice(0, lineStart) + buildDataDef + template.slice(lineStart);

  return result;
}

// ===== Deploy to docs/ =====
function deploy(html) {
  console.log('[3/3] Writing to docs/ directory...');

  if (!fs.existsSync(OUTPUT_DIR)) {
    fs.mkdirSync(OUTPUT_DIR, { recursive: true });
    console.log(`  Created ${OUTPUT_DIR}/`);
  }

  fs.writeFileSync(OUTPUT_FILE, html, 'utf-8');
  const sizeKB = Math.round(html.length / 1024);
  console.log(`  Written ${OUTPUT_FILE} (${sizeKB} KB)`);

  // Copy CNAME file to docs/ for GitHub Pages custom domain
  const cnameSrc = path.join(__dirname, 'CNAME');
  const cnameDest = path.join(OUTPUT_DIR, 'CNAME');
  if (fs.existsSync(cnameSrc)) {
    fs.copyFileSync(cnameSrc, cnameDest);
    console.log(`  Copied CNAME -> ${cnameDest}`);
  }
}

// ===== Main =====
async function main() {
  const t0 = Date.now();
  console.log('========================================');
  console.log('  AIVISE Build for GitHub Pages');
  console.log(`  Started at ${new Date().toISOString()}`);
  console.log('========================================\n');

  try {
    const items = await fetchAllItems();
    const html = buildHtml(items);
    deploy(html);

    const elapsed = Math.round((Date.now() - t0) / 1000);
    console.log(`\n========================================`);
    console.log(`  Build complete in ${elapsed}s`);
    console.log(`  Items: ${items.length}`);
    console.log(`  Output: ${OUTPUT_FILE}`);
    console.log(`========================================`);
    process.exit(0);
  } catch (err) {
    console.error('\nBuild failed:', err.message);
    process.exit(1);
  }
}

main();
