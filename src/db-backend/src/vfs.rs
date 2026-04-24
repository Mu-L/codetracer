//! Simple in-memory virtual file system for WASM.
//!
//! The `vfs` crate's `MemoryFS` internally calls `SystemTime::now()` when
//! creating files and directories, which panics on `wasm32-unknown-unknown`
//! because time is not implemented on that target. This module provides a
//! minimal HashMap-based alternative that avoids any system calls.

use codetracer_trace_types::{TraceLowLevelEvent, TraceMetadata};
use once_cell::sync::Lazy;
use std::collections::HashMap;
use std::error::Error;
use std::sync::Mutex;

/// Simple in-memory file store: maps virtual paths to byte contents.
///
/// The WASM module is single-threaded, so the Mutex is never contended.
/// We use it to satisfy `Sync` requirements for `static` storage.
static VFS_STORE: Lazy<Mutex<HashMap<String, Vec<u8>>>> = Lazy::new(|| Mutex::new(HashMap::new()));

/// Write a file into the in-memory VFS store.
pub fn vfs_write(path: &str, data: Vec<u8>) {
    let mut store = VFS_STORE.lock().unwrap();
    store.insert(path.to_string(), data);
}

/// Read file bytes from the in-memory VFS store.
pub fn vfs_read(path: &str) -> Option<Vec<u8>> {
    let store = VFS_STORE.lock().unwrap();
    store.get(path).cloned()
}

/// Check whether a file exists in the in-memory VFS store.
pub fn vfs_exists(path: &str) -> bool {
    let store = VFS_STORE.lock().unwrap();
    store.contains_key(path)
}

/// Load trace events from the in-memory VFS.
///
/// Reads the file bytes from the VFS store and deserializes them directly
/// — no real filesystem access is performed, so it is safe in WASM.
pub fn load_trace_data_vfs(
    virtual_path: &str,
    file_format: codetracer_trace_reader::TraceEventsFileFormat,
) -> Result<Vec<TraceLowLevelEvent>, Box<dyn Error>> {
    let bytes = vfs_read(virtual_path).ok_or_else(|| format!("VFS file not found: {virtual_path}"))?;

    match file_format {
        codetracer_trace_reader::TraceEventsFileFormat::Json => {
            // Deserialize JSON trace events directly from the VFS bytes.
            let events: Vec<TraceLowLevelEvent> = serde_json::from_slice(&bytes)?;
            Ok(events)
        }
        codetracer_trace_reader::TraceEventsFileFormat::Binary
        | codetracer_trace_reader::TraceEventsFileFormat::BinaryV0 => {
            // The cbor+zstd reader expects Read + Write + Seek; a Cursor
            // over the in-memory bytes satisfies all three traits.
            let mut cursor = std::io::Cursor::new(bytes);
            let events = codetracer_trace_reader::cbor_zstd_reader::read_trace(&mut cursor)?;
            Ok(events)
        }
        codetracer_trace_reader::TraceEventsFileFormat::Ctfs => {
            Err("CTFS trace-event loading from VFS is not supported; \
                 use CTFSTraceReader::from_bytes instead"
                .into())
        }
    }
}

/// Load and deserialize trace metadata JSON from the in-memory VFS.
pub fn load_trace_metadata_vfs(virtual_path: &str) -> Result<TraceMetadata, Box<dyn Error>> {
    let bytes = vfs_read(virtual_path).ok_or_else(|| format!("VFS file not found: {virtual_path}"))?;
    let s = std::str::from_utf8(&bytes)?;
    Ok(serde_json::from_str(s)?)
}
