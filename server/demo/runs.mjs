import { acquireQuake } from './quake.mjs';
import { acquireTsunamiForDrill } from './tsunami.mjs';
import { SCHEMA_VERSION, uuid } from './util.mjs';

export const HEARTBEAT_STALE_MS = 15_000;
export const ACK_TIMEOUT_MS = 5_000;
export const COMMAND_TTL_MS = 20_000;
export const MAX_MESSAGE_BYTES = 16 * 1024;
const ERROR_CODES = new Set(['unsupported-version', 'invalid-payload', 'expired-command', 'clock-skew', 'notifications-denied',
  'storage-failed', 'notification-failed', 'session-busy', 'language-mismatch', 'language-package-missing', 'stale-revision']);
const AUTH_STATES = new Set(['not-determined', 'denied', 'authorized', 'provisional']);
const isUuid = (v) => typeof v === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);

export class HttpError extends Error {
  constructor(status, code) {
    super(code);
    this.status = status;
    this.code = code;
  }
}

// Validates a device → server message. Returns { ok, message } or { ok:false, errorCode }.
export function validateDeviceMessage(text) {
  if (Buffer.byteLength(text) > MAX_MESSAGE_BYTES) return { ok: false, errorCode: 'invalid-payload' };
  let m;
  try {
    m = JSON.parse(text);
  } catch {
    return { ok: false, errorCode: 'invalid-payload' };
  }
  if (m?.schemaVersion !== SCHEMA_VERSION) return { ok: false, errorCode: 'unsupported-version' };
  // Swift encodes UUIDs in upper case; ids generated here are lower case.
  for (const k of ['installationId', 'runId', 'commandId', 'sessionId', 'currentSessionId']) if (typeof m[k] === 'string') m[k] = m[k].toLowerCase();
  switch (m.type) {
    case 'hello':
      if (!isUuid(m.installationId) || typeof m.preferredLanguage !== 'string' || !AUTH_STATES.has(m.notificationAuthorization) ||
          !Number.isInteger(m.languagePackageVersion) || !Number.isInteger(m.resourceVersion) || typeof m.liveActivitiesEnabled !== 'boolean') {
        return { ok: false, errorCode: 'invalid-payload' };
      }
      return { ok: true, message: m };
    case 'heartbeat':
      if (!isUuid(m.installationId) || typeof m.appState !== 'string') return { ok: false, errorCode: 'invalid-payload' };
      if (m.currentSessionId != null && !isUuid(m.currentSessionId)) return { ok: false, errorCode: 'invalid-payload' };
      return { ok: true, message: m };
    case 'notification-ack': {
      if (!['scheduled', 'duplicate', 'rejected', 'failed'].includes(m.status)) return { ok: false, errorCode: 'invalid-payload' };
      const isStart = isUuid(m.runId);
      const isHazard = isUuid(m.commandId) && isUuid(m.sessionId) && Number.isInteger(m.hazardRevision);
      if (!isStart && !isHazard) return { ok: false, errorCode: 'invalid-payload' };
      if ((m.status === 'rejected' || m.status === 'failed') && !ERROR_CODES.has(m.errorCode)) return { ok: false, errorCode: 'invalid-payload' };
      return { ok: true, message: m };
    }
    default:
      return { ok: false, errorCode: 'invalid-payload' };
  }
}

/**
 * Owns the single device connection, demo runs and tsunami updates.
 * Everything that reaches the phone goes through send(); nothing here touches HTTP.
 */
export class DemoController {
  constructor({ assets, log, fetchImpl, stateDir, fixtureDir, now = () => new Date(), timers = { setTimeout, clearTimeout } }) {
    this.assets = assets;
    this.log = log;
    this.fetchImpl = fetchImpl;
    this.stateDir = stateDir;
    this.fixtureDir = fixtureDir;
    this.now = now;
    this.timers = timers;
    this.device = null;
    this.run = null;
    this.history = [];
    this.tsunamiTargetArea = null;
  }

  // ---- device ----
  attachDevice(socket, remoteInfo = {}) {
    if (this.device) return false;
    this.device = { socket, connectedAt: this.now().toISOString(), lastHeartbeatAt: null, hello: null, heartbeat: null, remoteInfo };
    this.log('device-connected', {});
    return true;
  }

  detachDevice(socket) {
    if (this.device?.socket !== socket) return;
    this.device = null;
    this.log('device-disconnected', {});
  }

  disconnectDevice() {
    this.device?.socket.close(4001, 'pairing-rotated');
    this.device = null;
  }

  handleDeviceText(socket, text) {
    if (this.device?.socket !== socket) return;
    const result = validateDeviceMessage(text);
    if (!result.ok) {
      this.send({ type: 'error', errorCode: result.errorCode });
      this.log('device-invalid-message', { errorCode: result.errorCode });
      return;
    }
    const m = result.message;
    const receivedAt = this.now().toISOString();
    if (m.type === 'hello') {
      this.device.hello = m;
      this.device.lastHeartbeatAt = receivedAt;
      this.log('device-hello', { appVersion: m.appVersion, preferredLanguage: m.preferredLanguage, notificationAuthorization: m.notificationAuthorization, resourceVersion: m.resourceVersion, languagePackageVersion: m.languagePackageVersion });
    } else if (m.type === 'heartbeat') {
      this.device.heartbeat = m;
      this.device.lastHeartbeatAt = receivedAt;
    } else if (m.type === 'notification-ack') {
      this.handleAck(m, receivedAt);
    }
  }

  send(payload) {
    if (!this.device) return false;
    this.device.socket.send(JSON.stringify({ schemaVersion: SCHEMA_VERSION, ...payload }));
    return true;
  }

  heartbeatFresh() {
    const at = this.device?.lastHeartbeatAt;
    return Boolean(at) && this.now().getTime() - Date.parse(at) <= HEARTBEAT_STALE_MS;
  }

  readiness() {
    const reasons = [];
    const hello = this.device?.hello;
    if (!this.device) reasons.push('device-not-connected');
    else if (!hello) reasons.push('no-hello');
    if (this.device && !this.heartbeatFresh()) reasons.push('heartbeat-stale');
    if (hello) {
      if (hello.notificationAuthorization !== 'authorized') reasons.push(`notifications-${hello.notificationAuthorization}`);
      if (hello.resourceVersion !== this.assets.resourceVersion) reasons.push('resource-version-mismatch');
      const pkg = this.assets.languagePackageVersion(hello.preferredLanguage);
      if (pkg == null) reasons.push('language-package-missing');
      else if (pkg !== hello.languagePackageVersion) reasons.push('language-version-mismatch');
    }
    if (this.isBusy()) reasons.push('run-in-progress');
    for (const kind of ['earthquake', 'tsunami']) if (!this.assets.wallpaper(kind)) reasons.push(`wallpaper-${kind}-missing`);
    return { ready: reasons.length === 0, reasons };
  }

  isBusy() {
    return Boolean(this.run) && ['preparing', 'acquiring', 'sending', 'awaiting-ack'].includes(this.run.status);
  }

  // ---- earthquake run ----
  startRun({ scenario }) {
    if (!['earthquake', 'earthquake-tsunami', 'tsunami'].includes(scenario)) throw new HttpError(400, 'invalid-scenario');
    if (this.isBusy()) throw new HttpError(409, 'run-in-progress');
    if (!this.device) throw new HttpError(409, 'device-not-connected');
    if (!this.heartbeatFresh()) throw new HttpError(409, 'heartbeat-stale');
    const { ready, reasons } = this.readiness();
    if (!ready) throw new HttpError(409, reasons[0]);
    const run = {
      runId: uuid(), scenario, status: 'preparing', createdAt: this.now().toISOString(), language: this.device.hello.preferredLanguage,
      languagePackageVersion: this.device.hello.languagePackageVersion, acquisition: null, sends: [], ack: null, hazardRevision: 0, tsunamiCommands: [],
    };
    if (this.run) this.history.unshift(this.run);
    this.history = this.history.slice(0, 20);
    this.run = run;
    this.log('run-created', { runId: run.runId, scenario });
    this.executeRun(run).catch((err) => {
      run.status = 'failed';
      run.error = err.message;
      this.log('run-failed', { runId: run.runId, reason: err.message, failureReason: err.failureReason ?? null });
    });
    return run;
  }

  async executeRun(run) {
    run.status = 'acquiring';
    const acq = await acquireQuake({ fetchImpl: this.fetchImpl, stateDir: this.stateDir, fixtureDir: this.fixtureDir, now: this.now });
    run.acquisition = { source: acq.source, failureReason: acq.failureReason, startedAt: acq.startedAt, finishedAt: acq.finishedAt, fetchedAt: acq.fetchedAt, sha256: acq.sha256, quake: acq.quake, raw: acq.raw };
    this.log('quake-acquired', { runId: run.runId, source: acq.source, failureReason: acq.failureReason, sourceEventId: acq.quake.sourceEventId, issuedAt: acq.quake.issuedAt, startedAt: acq.startedAt, finishedAt: acq.finishedAt });
    // Image first, then the notification command (spec §4.3, §11.3).
    // The tsunami scenario starts straight in the tsunami guide; the quake is kept as its trigger.
    const hazard = run.scenario === 'tsunami' ? 'tsunami' : 'earthquake';
    await this.assets.selectWallpaper(hazard);
    run.status = 'sending';
    run.command = { type: 'start-guide', runId: run.runId, mode: 'demo', source: acq.source, language: run.language, scenario: run.scenario,
      languagePackageVersion: run.languagePackageVersion, stateRevision: 1, hazard, quake: acq.quake };
    this.sendWithRetry(run, () => run.command, (attempt) => run.sends.push(attempt), 'start');
  }

  // Sends now; if no ACK in 5 s resend once with the same id; after another 5 s → ack-unknown.
  sendWithRetry(target, buildCommand, record, kind) {
    const attempt = (n) => {
      const sentAt = this.now();
      const payload = { ...buildCommand(), sentAt: sentAt.toISOString(), expiresAt: new Date(sentAt.getTime() + COMMAND_TTL_MS).toISOString() };
      const delivered = this.send(payload);
      record({ attempt: n, sentAt: payload.sentAt, delivered });
      this.log(`${kind}-sent`, { runId: this.run?.runId, commandId: payload.commandId ?? null, attempt: n, delivered });
      if (target.status === 'sending') target.status = 'awaiting-ack';
      target.ackTimer = this.timers.setTimeout(() => {
        if (target.ack) return;
        if (n === 1) attempt(2);
        else {
          target.status = 'ack-unknown';
          this.log(`${kind}-ack-unknown`, { runId: this.run?.runId, commandId: payload.commandId ?? null });
        }
      }, ACK_TIMEOUT_MS);
    };
    attempt(1);
  }

  handleAck(m, receivedAt) {
    const run = this.run;
    if (!run) return;
    let target = null;
    if (m.runId) {
      if (m.runId !== run.runId) return this.log('ack-unknown-run', { runId: m.runId });
      target = run;
    } else {
      target = run.tsunamiCommands.find((c) => c.commandId === m.commandId && m.sessionId === run.runId);
      if (!target) return this.log('ack-unknown-command', { commandId: m.commandId });
    }
    // First ACK wins. ack-unknown has no ACK yet, so a late success still upgrades it (spec §7.2).
    if (target.ack) return;
    target.ack = { ...m, serverReceivedAt: receivedAt };
    if (target.ackTimer) this.timers.clearTimeout(target.ackTimer);
    target.status = m.status === 'scheduled' || m.status === 'duplicate' ? 'scheduled' : 'failed';
    this.log('ack-received', { runId: run.runId, commandId: m.commandId ?? null, status: m.status, errorCode: m.errorCode ?? null, appState: m.appState ?? null, protectedDataAvailable: m.protectedDataAvailable ?? null, scheduledAt: m.scheduledAt ?? null, stateRevision: m.stateRevision ?? null });
  }

  // ---- tsunami update (same session) ----
  async sendTsunami({ summary = null, raw = null, origin = 'drill' } = {}) {
    const run = this.run;
    if (!run || !['scheduled', 'ack-unknown'].includes(run.status)) throw new HttpError(409, 'no-active-session');
    if (!this.device) throw new HttpError(409, 'device-not-connected');
    let source = 'local';
    let tsunami = null;
    let acquisition = null;
    if (summary) {
      source = 'live-api';
      tsunami = summary;
      acquisition = { source, origin, raw };
    } else {
      const acq = await acquireTsunamiForDrill({ fetchImpl: this.fetchImpl, stateDir: this.stateDir, fixtureDir: this.fixtureDir, targetArea: this.tsunamiTargetArea, now: this.now });
      acquisition = { source: acq.source, failureReason: acq.failureReason, fetchedAt: acq.fetchedAt, raw: acq.raw, record: acq.record };
      // Only adopt API data when it names the configured area; otherwise a labelled local drill.
      if (acq.summary) {
        source = acq.source;
        tsunami = acq.summary;
      }
    }
    await this.assets.selectWallpaper('tsunami');
    run.hazardRevision += 1;
    const command = { commandId: uuid(), hazardRevision: run.hazardRevision, status: 'sending', ack: null, sends: [], source, acquisition, createdAt: this.now().toISOString() };
    run.tsunamiCommands.push(command);
    this.log('tsunami-prepared', { runId: run.runId, commandId: command.commandId, source, failureReason: acquisition.failureReason ?? null, sourceEventId: tsunami?.sourceEventId ?? null, issuedAt: tsunami?.issuedAt ?? null, origin });
    const payload = { type: 'hazard-update', commandId: command.commandId, sessionId: run.runId, hazardRevision: command.hazardRevision, hazard: 'tsunami',
      mode: 'demo', source, language: run.language, languagePackageVersion: run.languagePackageVersion, tsunami };
    this.sendWithRetry(command, () => payload, (a) => command.sends.push(a), 'tsunami');
    return command;
  }

  reset() {
    if (this.isBusy()) throw new HttpError(409, 'run-in-progress');
    if (this.run) this.history.unshift(this.run);
    this.run = null;
  }

  publicRun(run) {
    if (!run) return null;
    const strip = ({ ackTimer, ...rest }) => rest;
    return { ...strip(run), tsunamiCommands: run.tsunamiCommands.map(strip) };
  }

  status() {
    const d = this.device;
    return {
      device: d ? {
        connectedAt: d.connectedAt, lastHeartbeatAt: d.lastHeartbeatAt, heartbeatFresh: this.heartbeatFresh(),
        appVersion: d.hello?.appVersion ?? null, language: d.hello?.preferredLanguage ?? null, notificationAuthorization: d.hello?.notificationAuthorization ?? null,
        liveActivitiesEnabled: d.hello?.liveActivitiesEnabled ?? null, resourceVersion: d.hello?.resourceVersion ?? null, languagePackageVersion: d.hello?.languagePackageVersion ?? null,
        appState: d.heartbeat?.appState ?? null, protectedDataAvailable: d.heartbeat?.protectedDataAvailable ?? null, currentSessionId: d.heartbeat?.currentSessionId ?? null,
      } : null,
      readiness: this.readiness(),
      run: this.publicRun(this.run),
      history: this.history.slice(0, 5).map((r) => ({ runId: r.runId, scenario: r.scenario, status: r.status, source: r.acquisition?.source ?? null, createdAt: r.createdAt })),
    };
  }
}
