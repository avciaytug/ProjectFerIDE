// Çekirdekle WebSocket üzerinden JSON-RPC + olay akışı. Bağlantı koparsa yeniden bağlanır.

export class Rpc {
  constructor(token) {
    this.token = token;
    this.seq = 0;
    this.pending = new Map();
    this.handlers = new Map();
    this.queue = [];
    this.ws = null;
    this.connected = false;
    this.retry = 0;
  }

  connect() {
    return new Promise((resolve) => {
      const url = `ws://${location.host}/ws?token=${encodeURIComponent(this.token)}`;
      const ws = new WebSocket(url);
      this.ws = ws;
      ws.onopen = () => {
        this.connected = true;
        this.retry = 0;
        for (const m of this.queue.splice(0)) ws.send(m);
        this.emit('_connection', { connected: true });
        resolve();
      };
      ws.onmessage = (e) => {
        let msg;
        try { msg = JSON.parse(e.data); } catch { return; }
        if (msg.event) {
          this.emit(msg.event, msg.data);
          return;
        }
        const p = this.pending.get(msg.id);
        if (!p) return;
        this.pending.delete(msg.id);
        if (msg.error !== undefined) p.reject(new Error(msg.error));
        else p.resolve(msg.result);
      };
      ws.onclose = () => {
        const was = this.connected;
        this.connected = false;
        if (was) this.emit('_connection', { connected: false });
        for (const [, p] of this.pending) p.reject(new Error('Bağlantı koptu'));
        this.pending.clear();
        const wait = Math.min(5000, 300 * 2 ** this.retry++);
        setTimeout(() => this.connect().then(resolve), wait);
      };
    });
  }

  call(method, params = {}) {
    const id = ++this.seq;
    const msg = JSON.stringify({ id, method, params });
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      if (this.connected) this.ws.send(msg);
      else this.queue.push(msg);
    });
  }

  on(event, fn) {
    if (!this.handlers.has(event)) this.handlers.set(event, new Set());
    this.handlers.get(event).add(fn);
    return () => this.handlers.get(event).delete(fn);
  }

  emit(event, data) {
    for (const fn of this.handlers.get(event) || []) {
      try { fn(data); } catch (err) { console.error(event, err); }
    }
  }
}
