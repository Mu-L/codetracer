use std::collections::HashMap;
use std::path::Path;

use codetracer_trace_types::{
    CallKey, FullValueRecord, FunctionId, FunctionRecord, PathId, Place, StepId, TypeId,
    TypeRecord, ValueRecord, VariableId,
};

use crate::db::{CellChange, DbCall, DbRecordEvent, DbStep, EndOfProgram};

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

    // ── Metadata ────────────────────────────────────────────────────

    /// The working directory the trace was recorded in.
    fn workdir(&self) -> &Path;

    /// How the traced program ended (normal exit vs. error).
    fn end_of_program(&self) -> &EndOfProgram;
}
