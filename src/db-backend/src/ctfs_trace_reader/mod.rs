//! [`TraceReader`] implementation that reads from `.ct` CTFS containers.
//!
//! See the module-level documentation on [`CTFSTraceReader`] for design
//! rationale and the phased implementation plan.

pub mod ctfs_container;

use std::collections::HashMap;
use std::error::Error;
use std::path::Path;

use codetracer_trace_types::{
    CallKey, FullValueRecord, FunctionId, FunctionRecord, PathId, Place, StepId, TraceLowLevelEvent, TypeId,
    TypeRecord, ValueRecord, VariableId,
};

use crate::db::{CellChange, Db, DbCall, DbRecordEvent, DbStep, EndOfProgram};
use crate::trace_processor::TraceProcessor;
use crate::trace_reader::TraceReader;

use ctfs_container::CtfsReader;

/// A [`TraceReader`] backed by a `.ct` CTFS container file.
///
/// **Phase 1 (current):** Loads all data into memory at open time, identical
/// to [`crate::in_memory_trace_reader::InMemoryTraceReader`] but reading from
/// a CTFS binary container instead of the `trace-processor` pipeline. This
/// proves the plumbing works end-to-end: CTFS file -> parse container ->
/// extract events -> `TraceProcessor::postprocess` -> populated `Db` -> serve
/// via `TraceReader`.
///
/// **Phase 2 (future):** On-demand loading with LRU cache for per-step data.
/// The CTFS hierarchical block maps enable O(log n) seeking, so only the data
/// needed for the current DAP request would be decompressed and loaded.
///
/// # Container layout
///
/// A `.ct` file is a CTFS binary container (see `CTFS-Binary-Format.md` spec)
/// containing internal files:
///
/// | File | Purpose |
/// |------|---------|
/// | `meta.json` | Trace metadata (workdir, program, args) |
/// | `events.log` | CBOR-encoded `TraceLowLevelEvent` stream |
/// | `paths.idx` | Interned source paths |
/// | `types.idx` | Interned type records |
/// | `funcs.idx` | Interned function records |
///
/// See [`crate::trace_processor`] for how `TraceLowLevelEvent` values are
/// processed into the `Db` struct.
#[derive(Debug)]
pub struct CTFSTraceReader {
    /// The fully-populated in-memory database, built from CTFS contents
    /// during [`CTFSTraceReader::open`].
    db: Db,
}

impl CTFSTraceReader {
    /// Open a `.ct` CTFS trace file, parse its contents, and build the
    /// in-memory database.
    ///
    /// # Errors
    ///
    /// Returns an error if:
    /// - The file cannot be opened or is not a valid CTFS container
    /// - The `meta.json` internal file is missing or malformed
    /// - The trace events cannot be deserialized
    /// - The `TraceProcessor` fails during postprocessing
    pub fn open(path: &Path) -> Result<Self, Box<dyn Error>> {
        let mut ctfs = CtfsReader::open(path)?;

        // 1. Read and parse trace metadata
        let meta_bytes = ctfs.read_file("meta.json")?;
        let meta: codetracer_trace_types::TraceMetadata = serde_json::from_slice(&meta_bytes)?;

        let workdir = if meta.workdir.as_os_str().is_empty() {
            // Fall back to the parent directory of the program path
            Path::new(&meta.program)
                .parent()
                .unwrap_or(Path::new("."))
                .to_path_buf()
        } else {
            meta.workdir.clone()
        };

        // 2. Read the trace events from the container.
        //    Current format: CBOR-encoded TraceLowLevelEvent sequence in
        //    `events.log`. Future formats may use seekable Zstd compression
        //    (see CTFS-Binary-Format.md, Seekable Zstd Compression Layer).
        let events = Self::load_events(&mut ctfs)?;

        // 3. Run the same postprocessing pipeline that the existing
        //    trace-processor uses, populating a Db struct from the events.
        let mut db = Db::new(&workdir);
        let mut processor = TraceProcessor::new(&mut db);
        processor.postprocess(&events)?;

        Ok(CTFSTraceReader { db })
    }

    /// Extract `TraceLowLevelEvent` values from the CTFS container.
    ///
    /// Tries `events.log` first (CBOR-encoded event stream). If that file
    /// is not present, returns an empty event list so that the reader can
    /// still be constructed (useful for metadata-only traces or tests).
    fn load_events(ctfs: &mut CtfsReader) -> Result<Vec<TraceLowLevelEvent>, Box<dyn Error>> {
        let event_bytes = match ctfs.read_file("events.log") {
            Ok(bytes) => bytes,
            Err(_) => {
                // No events file — return an empty trace. This allows opening
                // minimal .ct files that only contain metadata (e.g. in tests).
                return Ok(Vec::new());
            }
        };

        if event_bytes.is_empty() {
            return Ok(Vec::new());
        }

        // Deserialize the CBOR-encoded event stream using cbor4ii, the same
        // library used by codetracer_trace_reader for the standalone binary
        // trace format. The events.log file contains a sequence of
        // individually-encoded CBOR values (one per TraceLowLevelEvent).
        //
        // cbor4ii::serde::from_reader reads exactly one CBOR value from the
        // stream. We wrap the bytes in a BufReader and read until EOF.
        use std::io::BufRead;

        let mut events = Vec::new();
        let mut buf_reader = std::io::BufReader::new(event_bytes.as_slice());

        loop {
            // Check for EOF before attempting to deserialize
            let buf = buf_reader.fill_buf()?;
            if buf.is_empty() {
                break;
            }

            match cbor4ii::serde::from_reader::<TraceLowLevelEvent, _>(&mut buf_reader) {
                Ok(event) => {
                    events.push(event);
                }
                Err(e) => {
                    // If we have already read some events, treat a parse error
                    // at the tail as a truncated stream (common during streaming
                    // recording — the recorder may not have flushed completely).
                    if !events.is_empty() {
                        log::warn!(
                            "CTFS: stopped reading events after {count} events: {e}. \
                             Treating as truncated stream.",
                            count = events.len()
                        );
                        break;
                    } else {
                        return Err(format!("failed to deserialize any events from events.log: {e}").into());
                    }
                }
            }
        }

        Ok(events)
    }
}

// ── TraceReader implementation ─────────────────────────────────────────
//
// Phase 1: delegates every method to the inner `Db`, exactly like
// `InMemoryTraceReader`. The only difference is *how* the Db is
// populated (from a CTFS container rather than from load_trace_data +
// TraceProcessor called in the handler).

impl TraceReader for CTFSTraceReader {
    // ── Interning tables ────────────────────────────────────────────

    fn path(&self, id: PathId) -> Option<&str> {
        self.db.paths.get(id).map(|s| s.as_str())
    }

    fn function(&self, id: FunctionId) -> Option<&FunctionRecord> {
        self.db.functions.get(id)
    }

    fn type_record(&self, id: TypeId) -> Option<&TypeRecord> {
        self.db.types.get(id)
    }

    fn variable_name(&self, id: VariableId) -> Option<&str> {
        self.db.variable_names.get(id).map(|s| s.as_str())
    }

    fn path_count(&self) -> usize {
        self.db.paths.len()
    }

    fn function_count(&self) -> usize {
        self.db.functions.len()
    }

    fn type_count(&self) -> usize {
        self.db.types.len()
    }

    // ── Per-step data ───────────────────────────────────────────────

    fn step(&self, id: StepId) -> Option<&DbStep> {
        self.db.steps.get(id)
    }

    fn step_count(&self) -> usize {
        self.db.steps.len()
    }

    fn variables_at(&self, step_id: StepId) -> Option<&[FullValueRecord]> {
        self.db.variables.get(step_id).map(|v| v.as_slice())
    }

    fn compound_at(&self, step_id: StepId) -> Option<&HashMap<Place, ValueRecord>> {
        self.db.compound.get(step_id)
    }

    fn cells_at(&self, step_id: StepId) -> Option<&HashMap<Place, ValueRecord>> {
        self.db.cells.get(step_id)
    }

    fn cell_changes_for(&self, place: &Place) -> Option<&Vec<CellChange>> {
        self.db.cell_changes.get(place)
    }

    fn variable_cells_at(&self, step_id: StepId) -> Option<&HashMap<VariableId, Place>> {
        self.db.variable_cells.get(step_id)
    }

    // ── Call tree ───────────────────────────────────────────────────

    fn call(&self, key: CallKey) -> Option<&DbCall> {
        self.db.calls.get(key)
    }

    fn call_count(&self) -> usize {
        self.db.calls.len()
    }

    // ── Events ──────────────────────────────────────────────────────

    fn events(&self) -> &[DbRecordEvent] {
        &self.db.events
    }

    fn event_count(&self) -> usize {
        self.db.events.len()
    }

    // ── Secondary indices ───────────────────────────────────────────

    fn path_id_for(&self, path: &str) -> Option<PathId> {
        self.db.path_map.get(path).copied()
    }

    fn steps_on_line(&self, path_id: PathId, line: usize) -> Option<&Vec<DbStep>> {
        self.db.step_map.get(path_id).and_then(|by_line| by_line.get(&line))
    }

    fn step_map_for_path(&self, path_id: PathId) -> Option<&HashMap<usize, Vec<DbStep>>> {
        self.db.step_map.get(path_id)
    }

    // ── Iteration helpers ────────────────────────────────────────────

    fn functions_iter(&self) -> Box<dyn Iterator<Item = (FunctionId, &FunctionRecord)> + '_> {
        Box::new(self.db.functions.iter().enumerate().map(|(i, f)| (FunctionId(i), f)))
    }

    fn calls_iter(&self) -> Box<dyn Iterator<Item = &DbCall> + '_> {
        Box::new(self.db.calls.iter())
    }

    fn steps_from(&self, start_id: StepId) -> &[DbStep] {
        let start = start_id.0 as usize;
        if start < self.db.steps.items.len() {
            &self.db.steps.items[start..]
        } else {
            &[]
        }
    }

    // ── Instructions ────────────────────────────────────────────────

    fn instructions_at(&self, step_id: StepId) -> Option<&Vec<String>> {
        self.db.instructions.get(step_id)
    }

    // ── Derived queries ─────────────────────────────────────────────

    fn load_step_events(&self, step_id: StepId, exact: bool) -> Vec<DbRecordEvent> {
        self.db.load_step_events(step_id, exact)
    }

    // ── Metadata ────────────────────────────────────────────────────

    fn workdir(&self) -> &Path {
        &self.db.workdir
    }

    fn end_of_program(&self) -> &EndOfProgram {
        &self.db.end_of_program
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Verify that a minimal .ct file with only `meta.json` can be opened
    /// and produces an empty trace (zero steps, zero calls, etc.).
    #[test]
    fn test_ctfs_trace_reader_opens_minimal_ct_file() {
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("test.ct");

        // Create a minimal CTFS container with just meta.json.
        let meta_json = br#"{"workdir":"/tmp","program":"/tmp/test","args":[]}"#;
        ctfs_container::write_minimal_ctfs(&ct_path, &[("meta.json", meta_json)]).unwrap();

        // Open with CTFSTraceReader
        let reader = CTFSTraceReader::open(&ct_path).unwrap();
        assert_eq!(reader.step_count(), 0);
        assert_eq!(reader.call_count(), 0);
        assert_eq!(reader.event_count(), 0);
        assert_eq!(reader.workdir().to_str().unwrap(), "/tmp");
    }

    /// Verify that a .ct file without `events.log` opens successfully
    /// (metadata-only trace).
    #[test]
    fn test_ctfs_trace_reader_missing_events_log() {
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("no-events.ct");

        let meta_json = br#"{"workdir":"/home/user","program":"/home/user/app","args":["--flag"]}"#;
        ctfs_container::write_minimal_ctfs(&ct_path, &[("meta.json", meta_json)]).unwrap();

        let reader = CTFSTraceReader::open(&ct_path).unwrap();
        assert_eq!(reader.step_count(), 0);
        assert_eq!(reader.workdir().to_str().unwrap(), "/home/user");
    }

    /// Verify that workdir falls back to the program's parent directory
    /// when the metadata workdir field is empty.
    #[test]
    fn test_ctfs_trace_reader_workdir_fallback() {
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("fallback.ct");

        let meta_json = br#"{"workdir":"","program":"/opt/bin/my_program","args":[]}"#;
        ctfs_container::write_minimal_ctfs(&ct_path, &[("meta.json", meta_json)]).unwrap();

        let reader = CTFSTraceReader::open(&ct_path).unwrap();
        assert_eq!(reader.workdir().to_str().unwrap(), "/opt/bin");
    }

    /// Verify that opening a non-existent file returns an error.
    #[test]
    fn test_ctfs_trace_reader_nonexistent_file() {
        let result = CTFSTraceReader::open(Path::new("/nonexistent/path/trace.ct"));
        assert!(result.is_err());
    }

    /// Verify that opening a file with invalid magic bytes returns an error.
    #[test]
    fn test_ctfs_trace_reader_invalid_magic() {
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("bad.ct");
        std::fs::write(&ct_path, b"this is not a CTFS file at all!").unwrap();

        let result = CTFSTraceReader::open(&ct_path);
        assert!(result.is_err());
    }
}
