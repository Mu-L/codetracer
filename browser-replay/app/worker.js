// WebWorker: loads replay-server WASM and bridges postMessage to DAP
//
// The WASM module (db_backend) exposes a BrowserTransport that receives
// DAP JSON messages via postMessage and sends responses back the same way.
// This worker is the bootstrap: it initialises the WASM, signals readiness,
// and then lets the WASM module's own onmessage handler take over.
import init, { wasm_start } from './pkg/db_backend.js';

async function start() {
  try {
    await init();
    wasm_start();
    // wasm_start() sets up onmessage callback inside the WASM module.
    // The WASM module's BrowserTransport.post_message() sends responses
    // back to the main thread.
    self.postMessage("ready");
  } catch (e) {
    self.postMessage({ error: e.toString() });
  }
}

start();
