// replay-test.js — Main-thread driver for the client-side WASM replay test.
//
// This script:
//   1. Parses trace configuration from URL query parameters.
//   2. Creates a WebWorker (worker.js) that loads the WASM DAP server.
//   3. Tells the worker to fetch trace files from the HTTP server into the VFS.
//   4. Starts the DAP server and sends the full DAP initialization sequence.
//   5. Reports results via DOM elements that Playwright can observe.
//
// The server is assumed to be a dumb static file server — no server-side
// logic, no WebSocket, no custom endpoints. The browser does everything.

// ---------------------------------------------------------------------------
// DOM helpers
// ---------------------------------------------------------------------------

const statusEl = document.getElementById('status');
const logEl = document.getElementById('log');

function setStatus(text, level = 'pending') {
  statusEl.textContent = text;
  statusEl.className = `status ${level}`;
}

function appendLog(msg) {
  const line = `[${new Date().toISOString().slice(11, 23)}] ${msg}\n`;
  logEl.textContent += line;
  // Auto-scroll to bottom.
  logEl.scrollTop = logEl.scrollHeight;
  console.log(`[replay-test] ${msg}`);
}

// ---------------------------------------------------------------------------
// Configuration from query parameters
// ---------------------------------------------------------------------------

const params = new URLSearchParams(window.location.search);

// VFS folder name — trace files are written as `<traceFolder>/<filename>`.
const traceFolder = params.get('traceFolder') || 'trace';

// Comma-separated list of file names to fetch from the server.
// Default: the standard DB trace layout.
const fileNames = (params.get('files') || 'trace.json,trace_metadata.json,trace_paths.json')
  .split(',')
  .map(s => s.trim())
  .filter(Boolean);

// Base URL for trace files on the server. Defaults to /traces/ relative to
// the current origin.
const traceBaseUrl = params.get('traceBaseUrl') || '/traces/';

appendLog(`traceFolder=${traceFolder}, files=[${fileNames.join(', ')}]`);
appendLog(`traceBaseUrl=${traceBaseUrl}`);

// ---------------------------------------------------------------------------
// Worker lifecycle
// ---------------------------------------------------------------------------

const worker = new Worker(new URL('./worker.js', import.meta.url), { type: 'module' });

/**
 * Wait for a specific message type from the worker.
 * Returns a promise that resolves with the message data.
 */
function waitForMessage(type, timeoutMs = 30_000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      worker.removeEventListener('message', handler);
      reject(new Error(`Timed out waiting for worker message type="${type}" after ${timeoutMs}ms`));
    }, timeoutMs);

    function handler(event) {
      const data = event.data;
      // DAP responses come as plain strings (JSON).
      if (type === 'dap-response' && typeof data === 'string') {
        worker.removeEventListener('message', handler);
        clearTimeout(timer);
        resolve(JSON.parse(data));
        return;
      }
      if (data && data.type === type) {
        worker.removeEventListener('message', handler);
        clearTimeout(timer);
        resolve(data);
        return;
      }
    }
    worker.addEventListener('message', handler);
  });
}

/**
 * Collect all worker messages for a given duration. Useful for DAP responses
 * where multiple messages arrive after a single request.
 */
function collectMessages(durationMs = 2000) {
  return new Promise((resolve) => {
    const messages = [];
    function handler(event) {
      const data = event.data;
      if (typeof data === 'string') {
        try { messages.push(JSON.parse(data)); } catch { messages.push(data); }
      } else {
        messages.push(data);
      }
    }
    worker.addEventListener('message', handler);
    setTimeout(() => {
      worker.removeEventListener('message', handler);
      resolve(messages);
    }, durationMs);
  });
}

worker.onerror = (event) => {
  appendLog(`WORKER ERROR: ${event.message}`);
  setStatus('Worker error — see console', 'error');
};

// ---------------------------------------------------------------------------
// Main sequence
// ---------------------------------------------------------------------------

(async () => {
  try {
    // Step 1: Wait for WASM to load in the worker.
    setStatus('Loading WASM module...', 'pending');
    await waitForMessage('wasm-loaded');
    appendLog('WASM module loaded in worker');

    // Step 2: Tell the worker to fetch trace files from the HTTP server.
    setStatus('Fetching trace files from server...', 'pending');
    const filesToFetch = fileNames.map(name => ({
      url: `${traceBaseUrl}${name}`,
      vfsPath: `${traceFolder}/${name}`,
    }));
    appendLog(`Requesting ${filesToFetch.length} file(s): ${filesToFetch.map(f => f.url).join(', ')}`);

    worker.postMessage({ type: 'load-trace', files: filesToFetch });

    // Wait for either success or error from the worker.
    const loadResult = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        worker.removeEventListener('message', handler);
        reject(new Error('Timed out waiting for trace-loaded after 30s'));
      }, 30_000);

      function handler(event) {
        const data = event.data;
        if (data && data.type === 'trace-loaded') {
          worker.removeEventListener('message', handler);
          clearTimeout(timer);
          resolve(data);
        } else if (data && data.type === 'trace-load-error') {
          worker.removeEventListener('message', handler);
          clearTimeout(timer);
          reject(new Error(`Trace load failed: ${data.error}`));
        }
      }
      worker.addEventListener('message', handler);
    });
    for (const f of loadResult.files) {
      appendLog(`VFS: ${f.vfsPath} (${f.bytes} bytes)`);
    }
    appendLog('All trace files loaded into VFS');

    // Step 3: Start the DAP server.
    setStatus('Starting DAP server...', 'pending');
    worker.postMessage({ type: 'start' });
    // wasm_start() posts the string "ready".
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('DAP start timeout')), 10_000);
      function handler(event) {
        if (event.data === 'ready') {
          worker.removeEventListener('message', handler);
          clearTimeout(timer);
          resolve();
        }
      }
      worker.addEventListener('message', handler);
    });
    appendLog('DAP server started (ready)');

    // Step 4: Send DAP initialize request.
    setStatus('Sending DAP initialize...', 'pending');
    const initCollector = collectMessages(3000);
    worker.postMessage({
      seq: 1,
      type: 'request',
      command: 'initialize',
      arguments: {
        clientID: 'wasm-replay-test',
        clientName: 'WASM Replay Test',
        adapterID: 'codetracer',
        linesStartAt1: true,
        columnsStartAt1: true,
        supportsRunInTerminalRequest: false,
      },
    });
    const initResponses = await initCollector;
    appendLog(`initialize responses (${initResponses.length}):`);
    for (const resp of initResponses) {
      appendLog(`  ${JSON.stringify(resp).slice(0, 300)}`);
    }

    // Check that we got an "initialize" response with success: true.
    const initResponse = initResponses.find(
      r => r.command === 'initialize' && r.type === 'response'
    );
    if (!initResponse || !initResponse.success) {
      throw new Error('DAP initialize failed: ' + JSON.stringify(initResponse));
    }
    appendLog('DAP initialize succeeded');

    // Step 5: Send DAP launch request — tells the backend which VFS folder
    // to load the trace from.
    setStatus('Sending DAP launch...', 'pending');
    const launchCollector = collectMessages(3000);
    worker.postMessage({
      seq: 2,
      type: 'request',
      command: 'launch',
      arguments: {
        traceFolder: traceFolder,
      },
    });
    const launchResponses = await launchCollector;
    appendLog(`launch responses (${launchResponses.length}):`);
    for (const resp of launchResponses) {
      appendLog(`  ${JSON.stringify(resp).slice(0, 300)}`);
    }

    // Step 6: Send configurationDone — this triggers VFS setup_from_vfs.
    setStatus('Sending DAP configurationDone...', 'pending');
    const configCollector = collectMessages(5000);
    worker.postMessage({
      seq: 3,
      type: 'request',
      command: 'configurationDone',
      arguments: {},
    });
    const configResponses = await configCollector;
    appendLog(`configurationDone responses (${configResponses.length}):`);
    for (const resp of configResponses) {
      appendLog(`  ${JSON.stringify(resp).slice(0, 300)}`);
    }

    // Check for the configurationDone response and any stopped/entry events.
    const configDoneResp = configResponses.find(
      r => r.command === 'configurationDone' && r.type === 'response'
    );
    if (!configDoneResp || !configDoneResp.success) {
      throw new Error('DAP configurationDone failed: ' + JSON.stringify(configDoneResp));
    }

    // After configurationDone + run_to_entry, we expect a "stopped" event
    // indicating the trace is ready for inspection.
    const stoppedEvent = configResponses.find(
      r => r.type === 'event' && r.event === 'stopped'
    );

    // -----------------------------------------------------------------------
    // Report final status
    // -----------------------------------------------------------------------
    const totalResponses = initResponses.length + launchResponses.length + configResponses.length;
    if (stoppedEvent) {
      setStatus('DAP replay ready — trace loaded and stopped at entry', 'ok');
      appendLog(`SUCCESS: stopped event received (reason: ${stoppedEvent.body?.reason})`);
    } else {
      // Even without a stopped event, configurationDone success means the
      // trace loaded. Some traces may not emit a stopped event.
      setStatus('DAP initialized and configured — trace loaded', 'ok');
      appendLog(`PARTIAL SUCCESS: configurationDone succeeded but no stopped event`);
    }

    // Expose results for Playwright assertions.
    window.__replayTestResult = {
      success: true,
      initResponse,
      configDoneResponse: configDoneResp,
      stoppedEvent: stoppedEvent || null,
      totalResponses,
    };

  } catch (err) {
    appendLog(`ERROR: ${err.message}`);
    setStatus(`Error: ${err.message}`, 'error');
    window.__replayTestResult = { success: false, error: err.message };
  }
})();
