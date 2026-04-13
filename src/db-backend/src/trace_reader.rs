use std::collections::HashMap;
use std::path::Path;

use codetracer_trace_types::{
    CallKey, FullValueRecord, FunctionId, FunctionRecord, PathId, Place, StepId, TypeId, TypeRecord, ValueRecord,
    VariableId,
};

use crate::db::{CellChange, Db, DbCall, DbRecordEvent, DbStep, EndOfProgram};

/// Facade for reading trace data.
///
/// Implementations may load data from in-memory arrays (current `Db`),
/// memory-mapped CTFS files (future), or any other backing store.
///
/// The trait is intentionally read-only — it never mutates the underlying
/// data. Methods that return `Option` signal "no such id" rather than
/// panicking, so callers can decide how to handle missing data.
///
/// # Design notes
///
/// * **Interning tables** (paths, functions, types, variable names) are
///   small enough to always live in memory, even in a file-backed
///   implementation.
/// * **Per-step data** (steps, variables, compound values, cells) may be
///   large. In a CTFS-backed implementation these would be seek-addressed
///   from a memory-mapped file.
/// * **Secondary indices** (path_map, step_map) accelerate lookups that
///   the handler performs frequently.
pub trait TraceReader: std::fmt::Debug + Send {
    // ── Interning tables ────────────────────────────────────────────

    /// Resolve a path id to its string representation (relative to workdir).
    fn path(&self, id: PathId) -> Option<&str>;

    /// Look up a function record by id.
    fn function(&self, id: FunctionId) -> Option<&FunctionRecord>;

    /// Look up a type record by id.
    fn type_record(&self, id: TypeId) -> Option<&TypeRecord>;

    /// Resolve a variable id to its human-readable name.
    fn variable_name(&self, id: VariableId) -> Option<&str>;

    /// Total number of recorded paths.
    fn path_count(&self) -> usize;

    /// Total number of recorded functions.
    fn function_count(&self) -> usize;

    /// Total number of recorded types.
    fn type_count(&self) -> usize;

    // ── Per-step data ───────────────────────────────────────────────

    /// Look up a single step by id.
    fn step(&self, id: StepId) -> Option<&DbStep>;

    /// Total number of recorded steps.
    fn step_count(&self) -> usize;

    /// Local variable values captured at a particular step.
    fn variables_at(&self, step_id: StepId) -> Option<&[FullValueRecord]>;

    /// Compound (aggregate) values captured at a particular step,
    /// keyed by `Place`.
    fn compound_at(&self, step_id: StepId) -> Option<&HashMap<Place, ValueRecord>>;

    /// Cell values captured at a particular step, keyed by `Place`.
    fn cells_at(&self, step_id: StepId) -> Option<&HashMap<Place, ValueRecord>>;

    /// The full cell-change history for a given `Place`.
    fn cell_changes_for(&self, place: &Place) -> Option<&Vec<CellChange>>;

    /// Variable-to-cell mapping at a particular step.
    fn variable_cells_at(&self, step_id: StepId) -> Option<&HashMap<VariableId, Place>>;

    // ── Call tree ───────────────────────────────────────────────────

    /// Look up a call by its key.
    fn call(&self, key: CallKey) -> Option<&DbCall>;

    /// Total number of recorded calls.
    fn call_count(&self) -> usize;

    // ── Events ──────────────────────────────────────────────────────

    /// All recorded events, in order.
    fn events(&self) -> &[DbRecordEvent];

    /// Total number of recorded events.
    fn event_count(&self) -> usize;

    // ── Secondary indices ───────────────────────────────────────────

    /// Reverse-lookup: find the `PathId` for a given path string.
    fn path_id_for(&self, path: &str) -> Option<PathId>;

    /// Return the step records on a given `line` within a given path.
    /// Returns `None` when the path or line has no recorded steps.
    fn steps_on_line(&self, path_id: PathId, line: usize) -> Option<&Vec<DbStep>>;

    /// Return the full line→steps map for a given path.
    fn step_map_for_path(&self, path_id: PathId) -> Option<&HashMap<usize, Vec<DbStep>>>;

    // ── Iteration helpers ────────────────────────────────────────────

    /// Iterate over all functions with their ids.
    ///
    /// Returns `(FunctionId, &FunctionRecord)` pairs in id order.
    fn functions_iter(&self) -> Box<dyn Iterator<Item = (FunctionId, &FunctionRecord)> + '_>;

    /// Iterate over all calls in order.
    fn calls_iter(&self) -> Box<dyn Iterator<Item = &DbCall> + '_>;

    /// Return a slice of steps starting from `start_id` to the end.
    ///
    /// Returns an empty slice when `start_id` is out of bounds.
    fn steps_from(&self, start_id: StepId) -> &[DbStep];

    // ── Instructions ────────────────────────────────────────────────

    /// Assembly instructions recorded at a particular step.
    fn instructions_at(&self, step_id: StepId) -> Option<&Vec<String>>;

    // ── Derived queries ─────────────────────────────────────────────

    /// Convenience: look up the `CallKey` for the call containing `step_id`.
    ///
    /// Equivalent to `self.step(step_id).map(|s| s.call_key)`.
    fn call_key_for_step(&self, step_id: StepId) -> Option<CallKey> {
        self.step(step_id).map(|s| s.call_key)
    }

    /// Return events associated with a step.
    ///
    /// When `exact` is `true`, only events at exactly `step_id` are returned.
    /// When `false`, events across the entire "line visit" (a contiguous run
    /// of steps on the same source line) are returned.
    fn load_step_events(&self, step_id: StepId, exact: bool) -> Vec<DbRecordEvent>;

    // ── Metadata ────────────────────────────────────────────────────

    /// The working directory the trace was recorded in.
    fn workdir(&self) -> &Path;

    /// How the traced program ended (normal exit vs. error).
    fn end_of_program(&self) -> &EndOfProgram;

    // ── Transitional ───────────────────────────────────────────────

    /// Direct access to the underlying `Db`.
    ///
    /// This is a **transitional** escape hatch that allows code which
    /// has not yet been migrated to the `TraceReader` API to keep
    /// working.  Once every call-site goes through trait methods, this
    /// method will be removed.
    fn as_db(&self) -> &Db;
}
