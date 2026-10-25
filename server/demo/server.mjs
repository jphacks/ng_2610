import { randomBytes, timingSafeEqual } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { WebSocketServer } from 'ws';
import { AssetStore } from './assets.mjs';
import { HttpError, MAX_MESSAGE_BYTES } from './runs.mjs';
import { TsunamiObserver } from './tsunami.mjs';
import { DeviceHub } from './devices.mjs';
import { RegionalMonitor } from '../monitoring/service.mjs';
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

export function renderSetupPage(manifest) {
  const cards = (manifest?.shortcuts ?? []).map((s) => {
    const href = s.file ? `/public/shortcuts/${encodeURIComponent(s.file)}` : null;
    return `<li><h2>${escapeHtml(s.title)}</h2>
<p>自動化の開始条件も同梱：アプリ <b>nigeyo</b>、タイトルが <code>${escapeHtml(s.triggerTitle)}</code> を含む。</p>
<p>画像はこのショートカットに同梱されています。追加すれば画像も端末に保存され、通知時のダウンロードは不要です。</p>
${href ? `<a class="btn" href="${escapeHtml(href)}">${escapeHtml(s.title)} を追加（自動化・画像込み）</a>` : '<p>配布ファイルの署名が未完了です。Macで npm run shortcuts:build を実行してください。</p>'}
<p><a download="${escapeHtml(s.id)}.png" href="/public/assets/wallpapers/${escapeHtml(s.id)}.png">画像だけ保存</a> · v${escapeHtml(s.version)}</p></li>`;
  }).join('');
  return `<!doctype html><html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>nigeyo ショートカット</title><style>body{font:16px/1.6 -apple-system,system-ui,sans-serif;background:#f7f6f0;color:#20241f;margin:auto;padding:24px;max-width:640px}
li{padding:12px}ol{padding-left:24px}.downloads{padding:0;list-style:none}.downloads li{background:#fff;border-radius:20px;margin:16px 0;padding:20px}.btn{display:inline-block;background:#20241f;color:white;padding:14px;border-radius:12px;text-decoration:none}code{background:#e6ede2;padding:2px 5px;border-radius:4px}</style></head>
<body><h1>地震・津波の2種類を準備</h1>
<p>まず以前の「nigeyo」共通ショートカットを呼ぶ通知オートメーションを無効にしてください。重複すると壁紙が上書きされます。</p>
<ol class="downloads">${cards}</ol>
<h2>追加した自動化を有効にする</h2><ol>
<li>上の2つを追加すると、画像と通知タイトルの条件も一緒に取り込まれます。別の自動化を新規作成する必要はありません。</li>
<li>「nigeyo 地震」の編集画面で、通知条件のアプリが手元の <b>nigeyo</b>、タイトルが <code>EARTHQUAKE_TEST</code> を含むことを確認。</li>
<li>「nigeyo 津波」は同じアプリ、タイトルが <code>TSUNAMI_TEST</code> を含むことを確認。両方とも対象アプリを端末にインストール済みのnigeyoへ選び直してください。開発用IDや未インストールの場合、別アプリ名が表示されることがあります。</li>
<li>インポートされた各オートメーションをオンにし、必要に応じて「ロック中の実行を許可」を有効にします。OSが求める確認は利用者が行います。</li>
<li>両方を一度手動実行して壁紙変更の権限を許可。画像・プレビューオフ・ロック画面の対象を確認してください。</li>
<li>ネット接続を切った状態でも各ショートカットで正しい画像になるか確認後、通知からの実行を試してください。</li></ol>
<p>対象はiOS 27以降です。配布ファイルの標準アプリIDは <code>jp.nigeyo.hackathon</code>。開発者用の別Bundle IDでインストールした場合はアプリを選び直してください。タイトル条件を消した全通知対象の設定にはしないでください。</p>
<p>条件は同梱されていますが、有効化・初回権限の許可はiPhoneで必要です。ロック解除が必要な処理はOSに従います。</p>
<p><a href="/public/shortcuts/bundle.zip">自動化付きショートカット2つ・画像2枚・手順をまとめて保存（ZIP）</a></p>
<p>壁紙は各端末内の画像から設定されます。名古屋と東京で別の通知が同時に届いても画像を共有しません。トンネルURLが変わっても再設定は不要です。</p>
</body></html>`;
}

export async function createDemoServer({ port = PORT, stateDir = STATE_DIR, fetchImpl, assets = new AssetStore(), log = createLogger(), fixtureDir, timers, monitorOptions = {} } = {}) {
  await assets.load();
  const configPath = join(stateDir, 'config.json');
  const config = { origin: null, ...(await readJsonOrNull(configPath)) };
  let token = randomBytes(32).toString('base64url');
  const hub = new DeviceHub({ assets, log, fetchImpl, stateDir, fixtureDir, timers });
  const monitor = new RegionalMonitor({ ...monitorOptions, stateDir, log });
  await monitor.load();
  const saveConfig = () => atomicWrite(configPath, JSON.stringify(config, null, 2));
  const pairingString = () => (config.origin ? `${config.origin.replace(/^https:/, 'wss:')}/public/device?token=${token}` : null);

  async function handleLocal(req, res, path, url) {
    if (req.method === 'GET' && UI_FILES[path]) {
      const [file, type] = UI_FILES[path];
      return sendBytes(res, await readFile(join(PUBLIC_UI_DIR, file)), type);
    }
    if (req.method === 'GET' && path === '/api/status') {
      const status = hub.status(url.searchParams.get('deviceId'));
      const selected = hub.connections.get(status.selectedDeviceId)?.controller;
      return sendJson(res, 200, { serverVersion: SERVER_VERSION, origin: config.origin, pairingString: pairingString(), assets: assets.status(), monitoring: monitor.status(selected?.device?.hello?.installationId), tsunami: { targetArea: selected?.tsunamiTargetArea ?? null, observer: selected?.observer?.status() ?? { state: 'stopped', events: [] } }, ...status });
    }
    if (req.method !== 'POST') throw new HttpError(404, 'not-found');
    if (!originAllowed(req, server.address()?.port ?? port)) throw new HttpError(403, 'origin-mismatch');
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
        hub.close();
        await log('pairing-rotated', {});
        return sendJson(res, 200, { pairingString: pairingString() });
      case '/api/demo/run': {
        const run = hub.target(body.deviceId).startRun({ scenario: body.scenario });
        return sendJson(res, 202, { runId: run.runId });
      }
      case '/api/demo/tsunami': {
        const command = await hub.target(body.deviceId).sendTsunami({ origin: 'drill' });
        return sendJson(res, 202, { commandId: command.commandId, source: command.source });
      }
      case '/api/tsunami/observe': {
        const controller = hub.target(body.deviceId);
        const observer = controller.observer;
        if (typeof body.targetArea === 'string') {
          controller.tsunamiTargetArea = body.targetArea.trim().slice(0, 64) || null;
        }
        if (body.enabled === true) observer.start({ targetArea: controller.tsunamiTargetArea, autoAdopt: body.autoAdopt === true });
        else if (body.enabled === false) observer.stop();
        return sendJson(res, 200, observer.status());
      }
      case '/api/demo/reset':
        hub.target(body.deviceId).reset();
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
      return res.end(renderSetupPage(assets.shortcutManifest));
    }
    if (path === '/public/assets/wallpaper.png') {
      throw new HttpError(410, 'shared-wallpaper-removed-reinstall-shortcuts');
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
    let path, url;
    try {
      url = new URL(req.url, 'http://x');
      path = url.pathname;
    } catch {
      return sendJson(res, 400, { error: 'bad-url' });
    }
    try {
      if (path.startsWith('/public/')) return await handlePublic(req, res, path);
      if (!isLocalRequest(req, server.address()?.port ?? port)) throw new HttpError(403, 'local-only');
      return await handleLocal(req, res, path, url);
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
    wss.handleUpgrade(req, socket, head, (ws) => {
      const controller = hub.attach(ws);
      controller.observer = new TsunamiObserver({ log, onCandidate: (summary, raw) => controller.sendTsunami({ summary, raw, origin: 'observer' }).catch((err) => log('tsunami-adopt-failed', { reason: err.message })) });
      let installationId;
      const regionalSend = (payload) => { if (ws.readyState === 1) ws.send(JSON.stringify(payload)); };
      ws.on('message', (data, isBinary) => {
        if (isBinary) return controller.send({ type: 'error', errorCode: 'invalid-payload' });
        let message;
        try { message = JSON.parse(data.toString('utf8')); } catch { /* existing validator replies */ }
        if (message?.type === 'regional-ack') {
          if (installationId && message.schemaVersion === 2 && typeof message.commandId === 'string' && message.status === 'stored') {
            monitor.acknowledge(installationId, message.commandId).catch(() => {});
          }
          return;
        }
        controller.handleDeviceText(ws, data.toString('utf8'));
        const hello = controller.device?.hello;
        if (message?.type === 'hello' && hello?.installationId === message.installationId?.toLowerCase()) {
          if (installationId && installationId !== hello.installationId) monitor.detach(installationId, regionalSend);
          installationId = hello.installationId;
          monitor.configure(installationId, hello.regionalSubscription, regionalSend).catch(() => {});
        }
        if (message?.type === 'heartbeat' && installationId) monitor.flush(installationId);
      });
      ws.on('close', () => { monitor.detach(installationId, regionalSend); hub.detach(ws); });
      ws.on('error', () => hub.detach(ws));
    });
  });

  await new Promise((resolve) => server.listen(port, HOST, resolve));
  return {
    server, hub, assets, config, monitor,
    get token() { return token; },
    close: () => new Promise((resolve) => { monitor.stop(); hub.close(); wss.close(); server.close(resolve); }),
  };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const app = await createDemoServer();
  console.log(`nigeyo demo server on http://127.0.0.1:${PORT}`);
  console.log(`Tunnel: npm exec --cache /private/tmp/nigeyo-npm-cache --yes --package cloudflared -- cloudflared tunnel --protocol http2 --url http://127.0.0.1:${PORT}`);
  if (!app.assets.resourceVersion) console.warn('assets/manifest.json missing. Run: npm run demo:prepare');
}
