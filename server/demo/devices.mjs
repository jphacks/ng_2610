import { DemoController, HttpError } from './runs.mjs';
import { uuid } from './util.mjs';

// Each connection owns its controller, runs, ACKs and retry timers. The asset store is
// immutable and shared: a Tokyo command cannot change a Nagoya phone's wallpaper.
export class DeviceHub {
  constructor(options) {
    this.options = options;
    this.connections = new Map();
  }

  attach(socket) {
    const id = uuid();
    const controller = new DemoController(this.options);
    controller.attachDevice(socket);
    this.connections.set(id, { id, controller });
    return controller;
  }

  detach(socket) {
    for (const [id, entry] of this.connections) {
      if (entry.controller.device?.socket !== socket) continue;
      entry.controller.dispose();
      this.connections.delete(id);
    }
  }

  // Do not silently send to an arbitrary phone when more than one is connected.
  target(id) {
    if (id != null) {
      const entry = this.connections.get(id);
      if (!entry) throw new HttpError(404, 'device-not-found');
      return entry.controller;
    }
    if (this.connections.size > 1) throw new HttpError(409, 'device-selection-required');
    const entry = this.connections.values().next().value;
    if (!entry) throw new HttpError(409, 'device-not-connected');
    return entry.controller;
  }

  status(id) {
    const devices = [...this.connections.values()].map(({ id, controller }) => ({ id, ...controller.status() }));
    const selected = id ? devices.find((d) => d.id === id) : devices[0];
    return { devices, selectedDeviceId: selected?.id ?? null,
      ...(selected ?? { device: null, run: null, history: [], readiness: { ready: false, reasons: [id ? 'device-not-found' : 'device-not-connected'] } }) };
  }

  close() {
    for (const { controller } of this.connections.values()) controller.dispose();
    this.connections.clear();
  }
}
