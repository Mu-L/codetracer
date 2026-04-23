// index.js — Main-thread integration for the WASM DAP worker.
//
// This module creates the worker, optionally pushes trace files into the
// in-memory VFS, then starts the DAP server and sends a test "initialize"
// request to verify the round-trip.

const log = (msg) => {
  console.log(`[main] ${msg}`);
  const el = document.getElementById('resultField');
  if (el) el.textContent = msg;
};

const worker = new Worker(new URL('./worker.js', import.meta.url), { type: 'module' });
log('Worker created — waiting for WASM to load...');

// --- Helpers -------------------------------------------------------------

/**
 * Send a file into the worker's in-memory VFS.
 * Returns a promise that resolves when the worker acknowledges the write.
 */
function vfsWrite(path, data) {
  return new Promise((resolve, reject) => {
    const handler = (e) => {
      if (e.data && e.data.type === 'vfs-ack' && e.data.path === path) {
        worker.removeEventListener('message', handler);
        if (e.data.ok) resolve();
        else reject(new Error(e.data.error));
      }
    };
    worker.addEventListener('message', handler);
    worker.postMessage({ type: 'vfs-write', path, data });
  });
}

/**
 * Tell the worker to start the DAP server.
 * Returns a promise that resolves when the worker posts "ready".
 */
function startDap() {
  return new Promise((resolve) => {
    const handler = (e) => {
      if (e.data === 'ready') {
        worker.removeEventListener('message', handler);
        resolve();
      }
    };
    worker.addEventListener('message', handler);
    worker.postMessage({ type: 'start' });
  });
}

// --- Boot sequence -------------------------------------------------------

worker.onerror = (event) => {
  console.error('[main] Worker error:', event);
  log('Worker error — see console');
};

(async () => {
  // Wait for the WASM module to finish loading inside the worker.
  await new Promise((resolve) => {
    const handler = (e) => {
      if (e.data && e.data.type === 'wasm-loaded') {
        worker.removeEventListener('message', handler);
        resolve();
      }
    };
    worker.addEventListener('message', handler);
  });
  log('WASM loaded in worker.');

  // --- Optional: push trace files into the VFS here ---------------------
  // Example (uncomment and adapt when you have trace data):
  //
  //   const metadataJson = new TextEncoder().encode(JSON.stringify({ ... }));
  //   await vfsWrite('trace/metadata.json', metadataJson);
  //   log('VFS: metadata.json written');

  // --- Start the DAP server ---------------------------------------------
  await startDap();
  log('DAP server ready — sending initialize request...');

  // Install a general message handler for DAP responses.
  worker.onmessage = (e) => {
    console.log('[main] DAP response:', e.data);
    const parsed = typeof e.data === 'string' ? JSON.parse(e.data) : e.data;
    log(`DAP response: ${JSON.stringify(parsed).slice(0, 200)}`);
  };

  // Send a DAP "initialize" request to verify the round-trip.
  const initReq = {
    seq: 1,
    type: 'request',
    command: 'initialize',
    arguments: { clientName: 'WebClient', linesStartAt1: true },
  };

  log('Sending DAP initialize request...');
  worker.postMessage(initReq);
})();
