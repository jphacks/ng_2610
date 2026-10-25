import { join } from 'node:path';
import WebSocket from 'ws';
import { atomicWrite, readJsonOrNull, SCHEMA_VERSION } from '../demo/util.mjs';
import { evaluate, initialState } from './engine.mjs';
import { validSubscription } from './regions.mjs';

/** A single national feed, with isolated durable per-installation state and outboxes. */
export class RegionalMonitor {
  constructor({ stateDir, log = async () => {}, WebSocketImpl = WebSocket, now = () => new Date() }) {
    this.path = join(stateDir, 'regional-monitor.json');
    this.log = log;
    this.WebSocketImpl = WebSocketImpl;
    this.now = now;
    this.records = {};
    this.clients = new Map();
    this.queue = Promise.resolve();
    this.state = 'stopped';
    this.stopped = false;
  }
  async load() {
    const saved = await readJsonOrNull(this.path);
    if (saved?.version === 1) this.records = saved.records ?? {};
    if (Object.values(this.records).some((r) => r.subscription?.enabled)) this.connect();
  }
  serial(work) {
    const result = this.queue.then(work);
    this.queue = result.catch((e) => this.log('regional-monitor-error', { reason: e.message }));
    return result;
  }
  save() { return atomicWrite(this.path, JSON.stringify({ version: 1, records: this.records })); }
  configure(id, subscription, send) {
    return this.serial(async () => {
      this.clients.set(id, send);
      if (!validSubscription(subscription)) subscription = { version: 1, enabled: false, targets: [] };
      const fingerprint = JSON.stringify(subscription);
      const old = this.records[id];
      if (!old || old.fingerprint !== fingerprint) {
        this.records[id] = { subscription, fingerprint, state: initialState(), pending: [] };
        try { await this.save(); }
        catch (e) { if (old) this.records[id] = old; else delete this.records[id]; throw e; }
      }
      if (subscription.enabled) this.connect();
      this.flush(id);
    });
  }
  detach(id, send) { if (this.clients.get(id) === send) this.clients.delete(id); }
  acknowledge(id, commandId) {
    return this.serial(async () => {
      const r = this.records[id];
      if (r) { r.pending = r.pending.filter((p) => p.commandId !== commandId); await this.save(); }
    });
  }
  ingest(item, { source = 'live' } = {}) {
    return this.serial(async () => {
      const changed = [];
      // Do not mutate committed state until its replacement has been persisted.
      const previous = this.records;
      this.records = structuredClone(previous);
      for (const [id, r] of Object.entries(this.records)) {
        const result = evaluate(item, r.subscription, r.state, { now: this.now(), source });
        r.state = result.state;
        if (result.action) {
          // Latest tsunami state or the same earthquake supersedes its older pending state.
          r.pending = r.pending.filter((p) => p.hazard !== result.action.hazard ||
            (p.hazard === 'earthquake' && p.sourceEventId !== result.action.sourceEventId));
          r.pending.push(result.action);
          changed.push(id);
        }
      }
      try { await this.save(); } catch (e) { this.records = previous; throw e; }
      for (const id of changed) this.flush(id);
      await this.log('regional-evaluated', { code: item?.code, matchedInstallations: changed.length, source });
    });
  }
  flush(id) {
    const r = this.records[id], send = this.clients.get(id);
    if (!r?.subscription.enabled || !send) return;
    for (const action of r.pending) {
      if (action.hazard === 'earthquake' && action.status === 'active' && this.now() - new Date(action.issuedAt) > 120_000) continue;
      const now = this.now();
      send({ schemaVersion: SCHEMA_VERSION, ...action, sentAt: now.toISOString(), expiresAt: new Date(+now + 20_000).toISOString() });
    }
  }
  connect() {
    if (this.stopped || this.ws || !Object.values(this.records).some((r) => r.subscription.enabled)) return;
    this.state = 'connecting';
    const ws = new this.WebSocketImpl('wss://api.p2pquake.net/v2/ws', { maxPayload: 1024 * 1024 });
    this.ws = ws;
    ws.on('open', () => { this.state = 'connected'; this.log('regional-feed-connected', {}); });
    ws.on('message', (data, binary) => {
      if (binary) return;
      let item;
      try { item = JSON.parse(data.toString('utf8')); } catch { return; }
      if ([556, 552].includes(item?.code)) this.ingest(item).catch(() => {});
    });
    ws.on('error', (e) => this.log('regional-feed-error', { reason: e.message }));
    ws.on('close', () => {
      if (this.ws !== ws) return;
      this.ws = null;
      if (this.stopped) return;
      this.state = 'reconnecting';
      // A disconnect never clears warning state.
      this.retry = setTimeout(() => this.connect(), 5000);
      this.retry.unref?.();
    });
    if (!this.deliveryTimer) {
      this.deliveryTimer = setInterval(() => { for (const id of this.clients.keys()) this.flush(id); }, 5000);
      this.deliveryTimer.unref?.();
    }
  }
  status(id) {
    const record = this.records[id];
    return { feed: this.state, enabled: record?.subscription.enabled ?? false, targets: record?.subscription.targets ?? [], state: record?.state ?? null, pending: record?.pending.length ?? 0 };
  }
  stop() {
    this.stopped = true;
    this.state = 'stopped';
    clearTimeout(this.retry);
    clearInterval(this.deliveryTimer);
    this.ws?.terminate();
    this.ws = null;
  }
}
