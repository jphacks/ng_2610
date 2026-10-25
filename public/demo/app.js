const $ = (id) => document.getElementById(id);
const STATUS_TEXT = {
  preparing: '準備中', acquiring: '準備中', sending: '送信中', 'awaiting-ack': '送信中',
  scheduled: '端末で通知予約済み', 'ack-unknown': '端末の応答なし（予約成否不明）', failed: '端末が失敗を応答',
};
const REASON_TEXT = {
  'device-not-connected': 'iPhone が未接続です', 'no-hello': 'iPhone からの hello 待ち', 'heartbeat-stale': '生存報告が15秒以上ありません',
  'notifications-denied': '通知が拒否されています', 'notifications-not-determined': '通知許可が未設定です', 'notifications-provisional': '仮の通知許可です（通常の許可が必要）',
  'resource-version-mismatch': '素材バージョンが一致しません', 'language-package-missing': '言語パッケージがサーバーにありません', 'language-version-mismatch': '言語パッケージの版が一致しません',
  'session-in-progress': 'iPhone に未完了の案内があります（アプリで終了してください）', 'run-in-progress': '実行中です',
  'wallpaper-earthquake-missing': '地震壁紙が未検証です（demo:prepare）', 'wallpaper-tsunami-missing': '津波壁紙が未検証です（demo:prepare）',
};

async function api(path, body) {
  const res = await fetch(path, body === undefined ? {} : { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(json.error ?? `HTTP ${res.status}`);
  return json;
}

function setGrid(el, rows) {
  el.replaceChildren(...rows.flatMap(([k, v]) => {
    const dt = document.createElement('dt');
    dt.textContent = k;
    const dd = document.createElement('dd');
    dd.textContent = v ?? '—';
    return [dt, dd];
  }));
}

const fmt = (iso) => (iso ? new Date(iso).toLocaleTimeString('ja-JP', { hour12: false }) + '.' + String(new Date(iso).getMilliseconds()).padStart(3, '0') : null);
let lastStatus = null;
let selectedDeviceId = null;
let refreshGeneration = 0;
const target = (body = {}) => ({ ...body, deviceId: selectedDeviceId });

async function refresh() {
  const generation = ++refreshGeneration;
  let s;
  try {
    s = await api('/api/status' + (selectedDeviceId ? `?deviceId=${encodeURIComponent(selectedDeviceId)}` : ''));
    if (generation !== refreshGeneration) return;
  } catch {
    $('run-state').textContent = 'サーバーに接続できません';
    return;
  }
  lastStatus = s;
  if (s.selectedDeviceId) selectedDeviceId = s.selectedDeviceId;
  const select = $('device-select');
  select.replaceChildren(...s.devices.map((entry, index) => Object.assign(document.createElement('option'), {
    value: entry.id, textContent: `iPhone ${index + 1} · ${entry.device?.installationId?.slice(0, 8) ?? entry.id.slice(0, 8)} · ${entry.device?.language ?? '接続準備中'}`,
    selected: entry.id === selectedDeviceId,
  })));
  if (!s.selectedDeviceId) select.prepend(Object.assign(document.createElement('option'), { textContent: selectedDeviceId ? '選択した端末が切断されました。送信先を選び直してください' : '接続中の端末なし', value: '', selected: true, disabled: true }));
  if (document.activeElement !== $('origin') && s.origin) $('origin').value = s.origin;
  $('pairing').value = s.pairingString ?? '';
  const d = s.device;
  const age = d?.lastHeartbeatAt ? Math.round((Date.now() - Date.parse(d.lastHeartbeatAt)) / 1000) : null;
  setGrid($('device'), [
    ['端末', d ? '接続中' : '未接続'], ['言語', d?.language], ['通知許可', d?.notificationAuthorization],
    ['生存報告', d?.lastHeartbeatAt ? `${fmt(d.lastHeartbeatAt)}（${age}秒前）${d.heartbeatFresh ? '' : ' ⚠ 期限切れ'}` : null],
    ['素材', `端末 v${d?.resourceVersion ?? '—'} / サーバー v${s.assets.resourceVersion ?? '—'}`],
    ['言語パッケージ', `端末 v${d?.languagePackageVersion ?? '—'} / サーバー ${s.assets.languages.map((l) => `${l.languageId}@${l.packageVersion}`).join(', ')}`],
    ['Live Activity', d ? String(d.liveActivitiesEnabled) : null],
  ]);
  const reasons = s.readiness.reasons;
  $('readiness').className = reasons.length ? 'reasons' : 'reasons ok';
  $('readiness').replaceChildren(...(reasons.length ? reasons : ['ready: 開始できます']).map((r) => Object.assign(document.createElement('li'), { textContent: REASON_TEXT[r] ?? r })));
  for (const b of document.querySelectorAll('.start')) b.disabled = !s.readiness.ready;

  const run = s.run;
  $('run-state').textContent = run ? STATUS_TEXT[run.status] ?? run.status : '準備中';
  const tsunamiCmd = run?.tsunamiCommands?.at(-1);
  $('tsunami-box').hidden = !(run && run.scenario === 'earthquake-tsunami' && ['scheduled', 'ack-unknown'].includes(run.status));
  if (tsunamiCmd) $('run-state').textContent += ` ／ 津波: ${STATUS_TEXT[tsunamiCmd.status] ?? tsunamiCmd.status}`;

  const a = run?.acquisition;
  setGrid($('ops-grid'), [
    ['runId', run?.runId], ['取得元 source', a?.source], ['API失敗理由', a?.failureReason ?? (a ? 'なし' : null)],
    ['元情報ID', a?.quake?.sourceEventId], ['元発表時刻', a?.quake?.issuedAt], ['発生時刻', a?.quake?.occurredAt],
    ['取得開始/終了', a ? `${fmt(a.startedAt)} → ${fmt(a.finishedAt)}` : null], ['データ取得時刻', a?.fetchedAt],
    ['送信', run?.sends?.map((x) => `#${x.attempt} ${fmt(x.sentAt)}${x.delivered ? '' : ' (未送出)'}`).join(', ')],
    ['ACK', run?.ack ? `${run.ack.status}${run.ack.errorCode ? ` (${run.ack.errorCode})` : ''} 受信 ${fmt(run.ack.serverReceivedAt)}` : null],
    ['通知予約時刻', run?.ack?.scheduledAt], ['受信時 iOS 状態', run?.ack ? `${run.ack.appState} / protectedData=${run.ack.protectedDataAvailable}` : null],
    ['津波コマンド', tsunamiCmd ? `${tsunamiCmd.commandId} rev${tsunamiCmd.hazardRevision} source=${tsunamiCmd.source} ${tsunamiCmd.acquisition?.failureReason ? `(API: ${tsunamiCmd.acquisition.failureReason})` : ''} → ${tsunamiCmd.ack?.status ?? tsunamiCmd.status}` : null],
    ['壁紙', '端末内の地震／津波ショートカット画像'], ['津波対象区', s.tsunami.targetArea],
  ]);
  $('raw').textContent = a?.raw ?? '';
  $('observer').textContent = JSON.stringify(s.tsunami.observer, null, 2);
  $('history').textContent = JSON.stringify(s.history, null, 2);
  if (document.activeElement !== $('target-area')) $('target-area').value = s.tsunami.targetArea ?? '';
  if (document.activeElement !== $('auto-adopt')) $('auto-adopt').checked = s.tsunami.observer.autoAdopt === true;
}

const act = (fn) => async (e) => {
  e?.preventDefault();
  try {
    await fn();
  } catch (err) {
    alert(err.message);
  }
  refresh();
};

$('device-select').addEventListener('change', () => { selectedDeviceId = $('device-select').value || null; refresh(); });
$('origin-form').addEventListener('submit', act(() => api('/api/config', { origin: $('origin').value.trim() })));
$('copy-pairing').addEventListener('click', act(() => navigator.clipboard.writeText($('pairing').value)));
$('rotate').addEventListener('click', act(() => api('/api/pairing/rotate', {})));
for (const b of document.querySelectorAll('.start')) b.addEventListener('click', act(async () => {
  for (const x of document.querySelectorAll('.start')) x.disabled = true;
  await api('/api/demo/run', target({ scenario: b.dataset.scenario }));
}));
$('send-tsunami').addEventListener('click', act(() => api('/api/demo/tsunami', target())));
$('reset').addEventListener('click', act(() => api('/api/demo/reset', target())));
$('tsunami-form').addEventListener('submit', act(() => api('/api/tsunami/observe', target({ enabled: true, targetArea: $('target-area').value, autoAdopt: $('auto-adopt').checked }))));
$('observe-stop').addEventListener('click', act(() => api('/api/tsunami/observe', target({ enabled: false }))));
try {
  $('notes').value = localStorage.getItem('nigeyo-notes') ?? '';
} catch {}
$('notes').addEventListener('input', () => { try { localStorage.setItem('nigeyo-notes', $('notes').value); } catch {} });

refresh();
setInterval(refresh, 1000);
