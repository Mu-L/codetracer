//! [`TraceReader`] implementation that reads from `.ct` CTFS containers.
//!
//! See the module-level documentation on [`CTFSTraceReader`] for design
//! rationale and the two-format approach.

pub mod ctfs_container;

use std::collections::HashMap;
use std::error::Error;
use std::path::Path;

use log::info;

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
/// Supports two container layouts:
///
/// ## Old format (events-based, requires postprocessing)
///
/// Contains raw `TraceLowLevelEvent` values in `events.log` plus JSON
/// metadata in `meta.json`. These events must be processed by
/// [`TraceProcessor::postprocess`] at startup to build the in-memory `Db`.
/// This is the format produced by current recorders (Python, Ruby, JS,
/// blockchain VMs).
///
/// | File | Purpose |
/// |------|---------|
/// | `meta.json` | Trace metadata (workdir, program, args) |
/// | `events.log` | Encoded `TraceLowLevelEvent` stream (chunked Zstd or legacy CBOR) |
/// | `events.fmt` | Serialization format marker (`"split-binary"` or absent for CBOR) |
///
/// ## New format (pre-processed, no postprocessing needed)
///
/// Contains pre-computed data structures written by the seek-based writer.
/// The recorder (or a post-recording finalization step) builds the same
/// data structures that `postprocess` would produce and writes them as
/// separate CTFS internal files. The reader loads these directly into
/// `Db`, skipping the expensive event-by-event postprocessing entirely.
///
/// The new format is detected by the presence of `steps.dat` in the
/// container. See `Seek-Based-CTFS-Reader.md` for the full file layout.
///
/// | File | Purpose |
/// |------|---------|
/// | `meta.dat` | Binary metadata (replaces `meta.json`) |
/// | `steps.dat` + `steps.idx` | Pre-computed step records with variable values |
/// | `calls.dat` | Pre-computed call tree records |
/// | `events.dat` | Pre-computed I/O event records with step cross-references |
/// | `paths.dat` + `paths.off` | Interned source paths with offset index |
/// | `funcs.dat` + `funcs.off` | Interned function records with offset index |
/// | `types.dat` + `types.off` | Interned type records with offset index |
/// | `varnames.dat` + `varnames.off` | Interned variable names with offset index |
///
/// See [`crate::trace_processor`] for how `TraceLowLevelEvent` values are
/// processed into the `Db` struct (old format path only).
#[derive(Debug)]
pub struct CTFSTraceReader {
    /// The fully-populated in-memory database, built from CTFS contents
    /// during [`CTFSTraceReader::open`].
    db: Db,
}

/// Returns `true` if the CTFS container uses the new pre-processed format
/// (detected by the presence of `steps.dat`), meaning postprocessing can
/// be skipped entirely.
///
/// Returns `false` for old-format containers that store raw events in
/// `events.log` and require [`TraceProcessor::postprocess`].
fn is_new_format(ctfs: &CtfsReader) -> bool {
    ctfs.has_file("steps.dat")
}

impl CTFSTraceReader {
    /// Open a `.ct` CTFS trace file, parse its contents, and build the
    /// in-memory database.
    ///
    /// Automatically detects the container format:
    /// - **New format** (has `steps.dat`): loads pre-processed data directly,
    ///   skipping [`TraceProcessor::postprocess`]. Startup is bounded by I/O
    ///   and decompression, not by trace size.
    /// - **Old format** (has `events.log`): deserializes events and runs
    ///   [`TraceProcessor::postprocess`] to build the `Db`.
    ///
    /// # Errors
    ///
    /// Returns an error if:
    /// - The file cannot be opened or is not a valid CTFS container
    /// - Metadata is missing or malformed
    /// - The trace data cannot be deserialized
    /// - (Old format only) The `TraceProcessor` fails during postprocessing
    pub fn open(path: &Path) -> Result<Self, Box<dyn Error>> {
        let mut ctfs = CtfsReader::open(path)?;

        if is_new_format(&ctfs) {
            info!("CTFS new format detected — skipping postprocessing");
            Self::open_new_format(&mut ctfs)
        } else {
            info!("CTFS old format detected — running postprocessing");
            Self::open_old_format(&mut ctfs)
        }
    }

    /// Open a new-format CTFS container by loading pre-processed data
    /// directly into the `Db`, bypassing `TraceProcessor::postprocess`.
    ///
    /// The new format stores the same data structures that `postprocess`
    /// would build, but written at recording time (or during a finalization
    /// step). This eliminates the O(n) startup cost where n is the number
    /// of trace events.
    ///
    /// # Current status
    ///
    /// The new-format writer does not exist yet — no recorder currently
    /// produces `steps.dat`. This method is the reader-side infrastructure
    /// for M37 (remove postprocessing startup). Once the seek-based writer
    /// is implemented, this path will be exercised automatically for any
    /// `.ct` file containing `steps.dat`.
    fn open_new_format(ctfs: &mut CtfsReader) -> Result<Self, Box<dyn Error>> {
        // TODO(M37): Implement loading pre-processed data from the new-format
        // CTFS internal files (steps.dat, calls.dat, events.dat, etc.).
        //
        // The implementation will:
        // 1. Read binary metadata from `meta.dat`
        // 2. Load interning tables (paths.dat+off, funcs.dat+off, types.dat+off, varnames.dat+off)
        // 3. Load pre-computed steps, calls, events, step_map, cell_changes
        //    directly into Db fields — no TraceProcessor involved
        //
        // For now, return an error indicating the format is recognized but
        // the reader is not yet implemented. This preserves forward
        // compatibility: when the writer starts producing new-format files,
        // this error will surface clearly during development.
        Err(format!(
            "CTFS new format detected (steps.dat present) but the seek-based \
             reader is not yet implemented. Container: {}. \
             This path will be filled in when the seek-based writer is available.",
            ctfs.file_names().join(", ")
        ).into())
    }

    /// Open an old-format CTFS container by deserializing raw events from
    /// `events.log` and running `TraceProcessor::postprocess` to build
    /// the in-memory `Db`.
    ///
    /// This is the original loading path. It will remain available for
    /// backward compatibility with traces recorded before the seek-based
    /// writer was introduced.
    fn open_old_format(ctfs: &mut CtfsReader) -> Result<Self, Box<dyn Error>> {
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
        //    Old format: CBOR-encoded TraceLowLevelEvent sequence in
        //    `events.log`, optionally with split-binary encoding indicated
        //    by `events.fmt`.
        let events = Self::load_events(ctfs)?;

        // 3. Run the postprocessing pipeline to populate a Db struct from
        //    the raw events. This is the expensive O(n) step that the new
        //    format eliminates.
        let mut db = Db::new(&workdir);
        let mut processor = TraceProcessor::new(&mut db);
        processor.postprocess(&events)?;

        Ok(CTFSTraceReader { db })
    }

    /// Extract `TraceLowLevelEvent` values from the CTFS container.
    ///
    /// Supports three data layouts, detected automatically:
    ///
    /// 1. **Chunked split-binary** (new default): `events.fmt` contains
    ///    `"split-binary"` and `events.log` uses inline 16-byte chunk
    ///    headers with Zstd-compressed payloads. Decompressed via
    ///    [`codetracer_ctfs::ChunkedReader`], then decoded via
    ///    [`codetracer_trace_writer::split_binary::decode_events`].
    ///
    /// 2. **Chunked CBOR**: `events.log` uses chunk headers but
    ///    `events.fmt` is absent or does not say `"split-binary"`.
    ///    Decompressed via `ChunkedReader`, then deserialized as CBOR.
    ///
    /// 3. **Legacy CBOR streaming**: No chunk headers (e.g. older zeekstd
    ///    frames). Falls back to sequential `cbor4ii::serde::from_reader`.
    ///
    /// If `events.log` is missing entirely, an empty event list is
    /// returned so that the reader can still be constructed (useful for
    /// metadata-only traces or tests).
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

        // Detect the serialization format. The presence of `events.fmt`
        // with the content `"split-binary"` indicates the new split-binary
        // encoding; otherwise we fall back to CBOR.
        let is_split_binary = match ctfs.read_file("events.fmt") {
            Ok(fmt) => fmt == b"split-binary",
            Err(_) => false, // Legacy: no format marker means CBOR
        };

        // Try the chunked format first (new writer produces inline 16-byte
        // chunk headers followed by Zstd-compressed payloads).
        if let Ok(decompressed) = codetracer_ctfs::ChunkedReader::decompress_all(&event_bytes) {
            if is_split_binary {
                return Ok(codetracer_trace_writer::split_binary::decode_events(&decompressed));
            } else {
                // Chunked CBOR — decompress, then parse CBOR from the buffer
                return Self::deserialize_cbor_from_buffer(&decompressed);
            }
        }

        // Fallback: legacy CBOR streaming (zeekstd frames, no chunk headers).
        // This path handles older `.ct` files that pre-date the chunked format.
        Self::deserialize_cbor_from_buffer(&event_bytes)
    }

    /// Deserialize a sequence of individually-encoded CBOR
    /// `TraceLowLevelEvent` values from an in-memory buffer.
    ///
    /// Uses `cbor4ii::serde::from_reader` in a loop, the same approach as
    /// `codetracer_trace_reader` for the standalone binary trace format.
    /// A parse error after at least one successful event is treated as a
    /// truncated stream (common during streaming recording when the
    /// recorder has not flushed completely).
    fn deserialize_cbor_from_buffer(data: &[u8]) -> Result<Vec<TraceLowLevelEvent>, Box<dyn Error>> {
        use std::io::BufRead;

        let mut events = Vec::new();
        let mut buf_reader = std::io::BufReader::new(data);

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
// All methods delegate to the inner `Db`, exactly like
// `InMemoryTraceReader`. The difference is how the Db is populated:
//
// - Old format: events.log -> load_events -> TraceProcessor::postprocess -> Db
// - New format: steps.dat + calls.dat + ... -> direct Db load (no postprocess)
//
// Both formats produce the same Db, so the TraceReader implementation is
// identical regardless of which loading path was used.

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

    fn path_entries_iter(&self) -> Box<dyn Iterator<Item = (&str, PathId)> + '_> {
        Box::new(self.db.path_map.iter().map(|(s, &id)| (s.as_str(), id)))
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

    // ── Transitional ───────────────────────────────────────────────

    fn as_db(&self) -> &Db {
        &self.db
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

    /// Verify that old-format detection works: a container with only
    /// `meta.json` (no `steps.dat`) uses the old postprocessing path.
    #[test]
    fn test_ctfs_old_format_detected_without_steps_dat() {
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("old-format.ct");

        let meta_json = br#"{"workdir":"/tmp","program":"/tmp/test","args":[]}"#;
        ctfs_container::write_minimal_ctfs(&ct_path, &[("meta.json", meta_json)]).unwrap();

        // Old format should work fine (goes through postprocess path)
        let reader = CTFSTraceReader::open(&ct_path).unwrap();
        assert_eq!(reader.step_count(), 0);
    }

    /// Verify that new-format detection works: a container with `steps.dat`
    /// is recognized as new-format. Since the new-format reader is not yet
    /// implemented, this should return an error indicating the format is
    /// recognized but unsupported.
    #[test]
    fn test_ctfs_new_format_detected_with_steps_dat() {
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("new-format.ct");

        // Create a container with steps.dat to trigger new-format detection.
        // The content doesn't matter — we just need the file to exist.
        let meta_json = br#"{"workdir":"/tmp","program":"/tmp/test","args":[]}"#;
        ctfs_container::write_minimal_ctfs(
            &ct_path,
            &[("meta.json", meta_json), ("steps.dat", b"placeholder")],
        )
        .unwrap();

        let result = CTFSTraceReader::open(&ct_path);
        // New-format reader is not yet implemented, so this should error
        assert!(result.is_err());
        let err_msg = result.unwrap_err().to_string();
        assert!(
            err_msg.contains("seek-based reader is not yet implemented"),
            "expected 'not yet implemented' error, got: {err_msg}"
        );
    }

    /// Verify the `is_new_format` helper function directly.
    #[test]
    fn test_is_new_format_detection() {
        let dir = tempfile::tempdir().unwrap();

        // Old format: no steps.dat
        let old_path = dir.path().join("old.ct");
        let meta_json = br#"{"workdir":"/tmp","program":"/tmp/test","args":[]}"#;
        ctfs_container::write_minimal_ctfs(&old_path, &[("meta.json", meta_json)]).unwrap();
        let old_ctfs = CtfsReader::open(&old_path).unwrap();
        assert!(!is_new_format(&old_ctfs));

        // New format: has steps.dat
        let new_path = dir.path().join("new.ct");
        ctfs_container::write_minimal_ctfs(
            &new_path,
            &[("meta.json", meta_json), ("steps.dat", b"data")],
        )
        .unwrap();
        let new_ctfs = CtfsReader::open(&new_path).unwrap();
        assert!(is_new_format(&new_ctfs));
    }
}
