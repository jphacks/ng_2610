import { randomBytes, timingSafeEqual } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { WebSocketServer } from 'ws';
import { AssetStore } from './assets.mjs';
import { DemoController, HttpError, MAX_MESSAGE_BYTES } from './runs.mjs';
import { TsunamiObserver } from './tsunami.mjs';
import { atomicWrite, createLogger, readJsonOrNull, ROOT, SERVER_VERSION, STATE_DIR } from './util.mjs';

export const PORT = Number(process.env.NIGEYO_PORT ?? 8788);
const HOST = '127.0.0.1';
const MAX_BODY = 8 * 1024;
const PUBLIC_UI_DIR = join(ROOT, 'public/demo');
const UI_FILES = { '/': ['index.html', 'text/html; charset=utf-8'], '/demo/app.js': ['app.js', 'text/javascript; charset=utf-8'], '/demo/style.css': ['style.css', 'text/css; charset=utf-8'] };
const FORWARD_HEADERS = ['cf-connecting-ip', 'cf-ray', 'cf-visitor', 'cdn-loop', 'x-forwarded-for', 'x-forwarded-host', 'x-forwarded-proto', 'forwarded', 'x-real-ip'];
const NO_STORE = 'no-store, no-cache, must-revalidate, max-age=0';

// Local operator API: Host must be loopback and no proxy/tunnel headers may be present.
export function isLocalRequest(req, port = PORT) {
  const host = req.headers.host ?? '';
  if (host !== `localhost:${port}` && host !== `127.0.0.1:${port}`) return false;
  return !FORWARD_HEADERS.some((h) => h in req.headers);
}

export function originAllowed(req, port = PORT) {
  const origin = req.headers.origin;
  return origin === `http://localhost:${port}` || origin === `http://127.0.0.1:${port}`;
}

export function bearerMatches(header, token) {
  const m = /^Bearer ([A-Za-z0-9_-]+)$/.exec(header ?? '');
  if (!m) return false;
  const a = Buffer.from(m[1]);
  const b = Buffer.from(token);
  return a.length === b.length && timingSafeEqual(a, b);
}

function normalizeOrigin(value) {
  try {
    const url = new URL(value);
    if (url.protocol !== 'https:' || url.pathname !== '/' && url.pathname !== '' || url.search || url.hash || url.username) return null;
    return url.origin;
  } catch {
    return null;
  }
}

async function readBody(req) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_BODY) throw new HttpError(413, 'body-too-large');
    chunks.push(chunk);
  }
  if (size === 0) return {};
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    throw new HttpError(400, 'invalid-json');
  }
}

function sendJson(res, status, body, extra = {}) {
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': NO_STORE, 'x-content-type-options': 'nosniff', ...extra });
  res.end(JSON.stringify(body));
}

function sendBytes(res, bytes, type, cache = NO_STORE) {
  res.writeHead(200, { 'content-type': type, 'content-length': bytes.length, 'cache-control': cache, 'x-content-type-options': 'nosniff' });
  res.end(bytes);
}

const escapeHtml = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

export function renderSetupPage(manifest, origin) {
  const items = (manifest?.shortcuts ?? []).map((s) => {
    const href = s.iCloudURL ?? (s.file ? `/public/shortcuts/${encodeURIComponent(s.file)}` : null);
    return `<li><h2>${escapeHtml(s.title)}</h2>
<p>Runs for every Nigeyo notification (<code>${escapeHtml(s.triggerTitle)}</code>). The server swaps the image behind the URL.</p>
<p>Wallpaper URL: <code>${escapeHtml(origin ?? '(set origin on the Mac)')}${escapeHtml(s.wallpaperPath)}</code></p>
<p>Version ${escapeHtml(s.version)} · iOS ${escapeHtml(s.minimumOSVersion)}+</p>
${href ? `<p><a class="btn" href="${escapeHtml(href)}">Add “${escapeHtml(s.title)}”</a></p>` : '<p class="warn">Signed file not prepared yet (npm run shortcuts:build).</p>'}</li>`;
  }).join('\n');
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Nigeyo shortcuts</title><style>body{font:16px/1.5 -apple-system,system-ui,sans-serif;background:#f7f6f0;color:#20241f;margin:0;padding:24px;max-width:640px}
li{background:#fff;border-radius:20px;padding:16px;margin:12px 0;list-style:none}ol{padding:0}.btn{display:inline-block;background:#20241f;color:#fff;padding:14px 20px;border-radius:12px;text-decoration:none;font-weight:700}
code{background:#e6ede2;padding:2px 6px;border-radius:6px}.warn{color:#b3361b}.steps li{background:none;list-style:decimal;margin:4px 0 4px 20px;padding:0}</style></head>
<body><h1>Nigeyo shortcut (1) + automation (1)</h1>
<p>One shortcut and one automation cover both earthquake and tsunami. When the import asks for the URL, replace <code>YOUR-TUNNEL.trycloudflare.com</code> with this server's host.</p>
<ol>${items}</ol>
<h2>Automation (one, iOS does not allow importing automations)</h2><ol class="steps">
<li>Shortcuts → Automation → <b>+</b> → <b>Notification</b> → App: <b>Nigeyo</b> (no title filter).</li>
<li>Choose <b>Run Immediately</b> and turn off <b>Notify When Run</b>.</li>
<li>Action: <b>Run Shortcut → Nigeyo</b>. The shortcut sets the wallpaper and then opens the app.</li>
<li>Run the shortcut once by hand to grant network and wallpaper permission.</li>
<li>Lock the iPhone and start the earthquake or tsunami demo on the Mac.</li></ol>
<p>Offline backup: save <a href="/public/assets/wallpapers/earthquake.png">earthquake.png</a> and <a href="/public/assets/wallpapers/tsunami.png">tsunami.png</a> to Files.</p>
</body></html>`;
}

export async function createDemoServer({ port = PORT, stateDir = STATE_DIR, fetchImpl, assets = new AssetStore(), log = createLogger(), fixtureDir } = {}) {
  await assets.load();
  const configPath = join(stateDir, 'config.json');
  const config = { origin: null, tsunamiTargetArea: null, ...(await readJsonOrNull(configPath)) };
  let token = randomBytes(32).toString('base64url');
  const controller = new DemoController({ assets, log, fetchImpl, stateDir, fixtureDir });
  controller.tsunamiTargetArea = config.tsunamiTargetArea;
  const observer = new TsunamiObserver({
    log,
    onCandidate: (summary, raw) => controller.sendTsunami({ summary, raw, origin: 'observer' }).catch((err) => log('tsunami-adopt-failed', { reason: err.message })),
  });
  const saveConfig = () => atomicWrite(configPath, JSON.stringify(config, null, 2));
  const pairingString = () => (config.origin ? `${config.origin.replace(/^https:/, 'wss:')}/public/device?token=${token}` : null);

  async function handleLocal(req, res, path) {
    if (req.method === 'GET' && UI_FILES[path]) {
      const [file, type] = UI_FILES[path];
      return sendBytes(res, await readFile(join(PUBLIC_UI_DIR, file)), type);
    }
    if (req.method === 'GET' && path === '/api/status') {
      return sendJson(res, 200, { serverVersion: SERVER_VERSION, origin: config.origin, pairingString: pairingString(), assets: assets.status(), tsunami: { targetArea: config.tsunamiTargetArea, observer: observer.status() }, ...controller.status() });
    }
    if (req.method !== 'POST') throw new HttpError(404, 'not-found');
    if (!originAllowed(req, port)) throw new HttpError(403, 'origin-mismatch');
    const body = await readBody(req);
    switch (path) {
      case '/api/config': {
        const origin = normalizeOrigin(body.origin);
        if (!origin) throw new HttpError(400, 'invalid-origin');
        config.origin = origin;
        await saveConfig();
        await log('config-origin', { origin });
        return sendJson(res, 200, { origin, pairingString: pairingString() });
      }
      case '/api/pairing/rotate':
        token = randomBytes(32).toString('base64url');
        controller.disconnectDevice();
        await log('pairing-rotated', {});
        return sendJson(res, 200, { pairingString: pairingString() });
      case '/api/demo/run': {
        const run = controller.startRun({ scenario: body.scenario });
        return sendJson(res, 202, { runId: run.runId });
      }
      case '/api/demo/tsunami': {
        const command = await controller.sendTsunami({ origin: 'drill' });
        return sendJson(res, 202, { commandId: command.commandId, source: command.source });
      }
      case '/api/tsunami/observe': {
        if (typeof body.targetArea === 'string') {
          config.tsunamiTargetArea = body.targetArea.trim().slice(0, 64) || null;
          controller.tsunamiTargetArea = config.tsunamiTargetArea;
          await saveConfig();
        }
        if (body.enabled === true) observer.start({ targetArea: config.tsunamiTargetArea, autoAdopt: body.autoAdopt === true });
        else if (body.enabled === false) observer.stop();
        return sendJson(res, 200, observer.status());
      }
      case '/api/demo/reset':
        controller.reset();
        return sendJson(res, 200, { ok: true });
      default:
        throw new HttpError(404, 'not-found');
    }
  }

  async function handlePublic(req, res, path) {
    if (req.method !== 'GET') throw new HttpError(405, 'method-not-allowed');
    if (path === '/public/health') return sendJson(res, 200, { ok: true, version: SERVER_VERSION });
    if (path === '/public/assets/manifest.json' && assets.manifest) return sendJson(res, 200, assets.manifest);
    if (path === '/public/languages/manifest.json' && assets.languageManifest) return sendJson(res, 200, assets.languageManifest);
    if (path === '/public/shortcuts/manifest.json' && assets.shortcutManifest) return sendJson(res, 200, assets.shortcutManifest);
    if (path === '/public/shortcuts/setup') {
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': NO_STORE, 'content-security-policy': "default-src 'none'; style-src 'unsafe-inline'; img-src 'self'" });
      return res.end(renderSetupPage(assets.shortcutManifest, config.origin));
    }
    if (path === '/public/assets/wallpaper.png') {
      const bytes = assets.wallpaper();
      if (bytes) return sendBytes(res, bytes, 'image/png');
    }
    const wp = /^\/public\/assets\/wallpapers\/(earthquake|tsunami)\.png$/.exec(path);
    if (wp) {
      const bytes = assets.wallpaper(wp[1]);
      if (bytes) return sendBytes(res, bytes, 'image/png');
    }
    const lang = /^\/public\/languages\/([A-Za-z0-9-]{2,35})\.json$/.exec(path);
    if (lang) {
      const bytes = await assets.languageFile(lang[1]);
      if (bytes) return sendBytes(res, bytes, 'application/json; charset=utf-8', 'no-cache');
    }
    const sc = /^\/public\/shortcuts\/([A-Za-z0-9._-]+\.(?:shortcut|zip))$/.exec(path);
    if (sc) {
      const bytes = await assets.shortcutFile(sc[1]);
      if (bytes) return sendBytes(res, bytes, sc[1].endsWith('.zip') ? 'application/zip' : 'application/octet-stream', 'no-cache');
    }
    throw new HttpError(404, 'not-found');
  }

  const server = createServer(async (req, res) => {
    let path;
    try {
      path = new URL(req.url, 'http://x').pathname;
    } catch {
      return sendJson(res, 400, { error: 'bad-url' });
    }
    try {
      if (path.startsWith('/public/')) return await handlePublic(req, res, path);
      if (!isLocalRequest(req, port)) throw new HttpError(403, 'local-only');
      return await handleLocal(req, res, path);
    } catch (err) {
      const status = err instanceof HttpError ? err.status : 500;
      if (status === 500) console.error(err);
      if (!res.headersSent) sendJson(res, status, { error: err instanceof HttpError ? err.code : 'internal-error' });
    }
  });

  const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_MESSAGE_BYTES });
  server.on('upgrade', (req, socket, head) => {
    const path = new URL(req.url, 'http://x').pathname;
    const reject = (code, text) => {
      socket.write(`HTTP/1.1 ${code} ${text}\r\nConnection: close\r\n\r\n`);
      socket.destroy();
    };
    if (path !== '/public/device') return reject(404, 'Not Found');
    if (!bearerMatches(req.headers.authorization, token)) return reject(401, 'Unauthorized');
    if (controller.device) return reject(409, 'Conflict');
    wss.handleUpgrade(req, socket, head, (ws) => {
      if (!controller.attachDevice(ws)) return ws.close(4009, 'device-busy');
      ws.on('message', (data, isBinary) => {
        if (isBinary) return controller.send({ type: 'error', errorCode: 'invalid-payload' });
        controller.handleDeviceText(ws, data.toString('utf8'));
      });
      ws.on('close', () => controller.detachDevice(ws));
      ws.on('error', () => controller.detachDevice(ws));
    });
  });

  await new Promise((resolve) => server.listen(port, HOST, resolve));
  return {
    server, controller, assets, observer, config,
    get token() { return token; },
    close: () => new Promise((resolve) => { observer.stop(); controller.disconnectDevice(); wss.close(); server.close(resolve); }),
  };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const app = await createDemoServer();
  console.log(`Nigeyo demo server on http://127.0.0.1:${PORT}`);
  console.log(`Tunnel: npm exec --cache /private/tmp/nigeyo-npm-cache --yes --package cloudflared -- cloudflared tunnel --protocol http2 --url http://127.0.0.1:${PORT}`);
  if (!app.assets.resourceVersion) console.warn('assets/manifest.json missing. Run: npm run demo:prepare');
}
