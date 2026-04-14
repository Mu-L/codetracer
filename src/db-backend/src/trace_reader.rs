use std::collections::HashMap;
use std::path::{Path, PathBuf};

use log::warn;
use num_bigint::BigInt;

use codetracer_trace_types::{
    CallKey, FullValueRecord, FunctionId, FunctionRecord, PathId, Place, StepId, TypeId, TypeKind, TypeRecord,
    TypeSpecificInfo, ValueRecord, VariableId, NO_KEY,
};

use crate::db::{CellChange, Db, DbCall, DbRecordEvent, DbStep, EndOfProgram};
use crate::expr_loader::ExprLoader;
use crate::task::{Call, CallArg, Location, RRTicks};
use crate::value::{Type, Value};

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

    // ── Value / call conversion helpers ─────────────────────────────
    //
    // These default methods replace `Db::to_ct_value`, `Db::to_call`,
    // `Db::to_call_arg`, and `Db::load_location`.  They depend only on
    // other `TraceReader` methods (interning tables, steps, calls) so
    // any implementation of the trait gets them for free.

    /// Convert a `TypeId` to the frontend `Type` representation.
    #[allow(clippy::expect_used)]
    fn to_ct_type(&self, type_id: &TypeId) -> Type {
        if self.type_count() == 0 {
            // Probably an rr trace case — no type information available.
            warn!("to_ct_type: returning placeholder type (assuming rr trace)");
            return Type::new(TypeKind::None, "<None>");
        }
        let type_record = self.type_record(*type_id).expect("to_ct_type: invalid TypeId");
        match type_record.kind {
            TypeKind::Struct => {
                let mut t = Type::new(type_record.kind, &type_record.lang_type);
                t.labels = self.get_field_names(type_id);
                t
            }
            _ => Type::new(type_record.kind, &type_record.lang_type),
        }
    }

    /// Return the field names for a struct type, or an empty vec for
    /// non-struct types.
    #[allow(clippy::expect_used)]
    fn get_field_names(&self, type_id: &TypeId) -> Vec<String> {
        match &self
            .type_record(*type_id)
            .expect("get_field_names: invalid TypeId")
            .specific_info
        {
            TypeSpecificInfo::Struct { fields } => fields.iter().map(|field| field.name.clone()).collect(),
            _ => Vec::new(),
        }
    }

    /// Convert a `ValueRecord` to the frontend `Value` representation.
    ///
    /// This is recursive: compound value records (sequences, structs,
    /// tuples, variants, references) recurse into their children.
    #[allow(clippy::expect_used)]
    fn to_ct_value(&self, record: &ValueRecord) -> Value {
        match record {
            ValueRecord::Int { i, type_id } => {
                let mut res = Value::new(TypeKind::Int, self.to_ct_type(type_id));
                res.i = i.to_string();
                res
            }
            ValueRecord::Float { f, type_id } => {
                let mut res = Value::new(TypeKind::Float, self.to_ct_type(type_id));
                res.f = f.to_string();
                res
            }
            ValueRecord::String { text, type_id } => {
                let mut res = Value::new(TypeKind::String, self.to_ct_type(type_id));
                res.text = text.clone();
                res
            }
            ValueRecord::Bool { b, type_id } => {
                let mut res = Value::new(TypeKind::Bool, self.to_ct_type(type_id));
                res.b = *b;
                res
            }
            ValueRecord::Sequence {
                elements,
                type_id,
                is_slice,
            } => {
                let typ = if !is_slice {
                    self.to_ct_type(type_id)
                } else {
                    let type_record = self
                        .type_record(*type_id)
                        .expect("to_ct_value: invalid TypeId for slice");
                    Type::new(TypeKind::Slice, &type_record.lang_type)
                };
                let mut res = Value::new(TypeKind::Seq, typ);
                res.elements = elements.iter().map(|e| self.to_ct_value(e)).collect();
                res
            }
            ValueRecord::Struct { field_values, type_id } => {
                let mut res = Value::new(TypeKind::Struct, self.to_ct_type(type_id));
                res.elements = field_values.iter().map(|value| self.to_ct_value(value)).collect();
                res
            }
            ValueRecord::Tuple { elements, type_id } => {
                let mut res = Value::new(TypeKind::Tuple, self.to_ct_type(type_id));
                res.elements = elements.iter().map(|value| self.to_ct_value(value)).collect();
                res.typ.labels = elements
                    .iter()
                    .enumerate()
                    .map(|(index, _)| format!("{index}"))
                    .collect();
                res.typ.member_types = res.elements.iter().map(|value| value.typ.clone()).collect();
                res
            }
            ValueRecord::Variant {
                discriminator,
                contents,
                type_id,
            } => {
                let mut res = Value::new(TypeKind::Variant, self.to_ct_type(type_id));
                res.active_variant = discriminator.to_string();
                res.active_variant_value = Some(Box::new(self.to_ct_value(contents)));
                res
            }
            ValueRecord::Reference {
                dereferenced,
                address,
                mutable,
                type_id,
            } => {
                let mut res = Value::new(TypeKind::Pointer, self.to_ct_type(type_id));
                let dereferenced_value = self.to_ct_value(dereferenced);
                res.typ.element_type = Some(Box::new(dereferenced_value.typ.clone()));
                res.address = (*address).to_string();
                res.ref_value = Some(Box::new(dereferenced_value));
                res.is_mutable = *mutable;
                res
            }
            ValueRecord::Raw { r, type_id } => {
                let mut res = Value::new(TypeKind::Raw, self.to_ct_type(type_id));
                res.r = r.clone();
                res
            }
            ValueRecord::Error { msg, type_id } => {
                let mut res = Value::new(TypeKind::Error, self.to_ct_type(type_id));
                res.msg = msg.clone();
                res
            }
            ValueRecord::None { type_id } => Value::new(TypeKind::None, self.to_ct_type(type_id)),
            ValueRecord::Cell { .. } => {
                // Supposed to map to place in value graph — not yet implemented.
                unimplemented!()
            }
            ValueRecord::BigInt { b, negative, type_id } => {
                let sign = if *negative {
                    num_bigint::Sign::Minus
                } else {
                    num_bigint::Sign::Plus
                };
                let num = BigInt::from_bytes_be(sign, b);
                let mut res = Value::new(TypeKind::Int, self.to_ct_type(type_id));
                res.i = num.to_string();
                res
            }
            ValueRecord::Char { c, type_id } => {
                let mut res = Value::new(TypeKind::Char, self.to_ct_type(type_id));
                res.c = c.to_string();
                res
            }
        }
    }

    /// Convert a `FullValueRecord` (variable name + value) to a `CallArg`.
    #[allow(clippy::expect_used)]
    fn to_call_arg(&self, arg_record: &FullValueRecord) -> CallArg {
        CallArg {
            name: self
                .variable_name(arg_record.variable_id)
                .unwrap_or("<unknown>")
                .to_string(),
            text: "".to_string(),
            value: self.to_ct_value(&arg_record.value),
        }
    }

    /// Convert a `DbCall` to the frontend `Call` representation.
    ///
    /// Uses `load_location` for the call's source location and
    /// `to_ct_value` / `to_call_arg` for arguments and return value.
    #[allow(clippy::expect_used)]
    fn to_call(&self, call_record: &DbCall, expr_loader: &mut ExprLoader) -> Call {
        Call {
            key: format!("{}", call_record.key.0),
            children: vec![],
            depth: call_record.depth,
            location: self.load_location(call_record.step_id, call_record.key, expr_loader),
            parent: None,
            raw_name: self
                .function(call_record.function_id)
                .expect("to_call: invalid function_id")
                .name
                .clone(),
            args: call_record.args.iter().map(|arg| self.to_call_arg(arg)).collect(),
            return_value: self.to_ct_value(&call_record.return_value),
            with_args_and_return: true,
        }
    }

    /// Build a `Location` for the given step and call key.
    ///
    /// If `call_key_arg` has a negative value, the step's own call key is
    /// used instead.  The returned location includes function boundary
    /// lines when tree-sitter data is available via `expr_loader`.
    #[allow(clippy::expect_used)]
    fn load_location(&self, step_id: StepId, call_key_arg: CallKey, expr_loader: &mut ExprLoader) -> Location {
        let step_id_int = step_id.0;
        let step_record = self.step(step_id).expect("load_location: invalid step_id");
        let path = format!(
            "{}",
            self.workdir()
                .join(self.path(step_record.path_id).unwrap_or(""))
                .display()
        );
        let line = step_record.line.0;
        let call_key = if call_key_arg.0 >= 0 {
            call_key_arg
        } else {
            step_record.call_key
        };
        let call_key_int = call_key.0;

        assert!(call_key_int >= 0);

        let (function_name, callstack_depth) = if call_key != NO_KEY {
            let call = self.call(call_key).expect("load_location: invalid call_key");
            let function = self
                .function(call.function_id)
                .expect("load_location: invalid function_id");
            (function.name.clone(), call.depth)
        } else {
            ("<unknown>".to_string(), 0)
        };
        let call_key_text = format!("{call_key_int}");
        let global_call_key_text = format!("{}", step_record.global_call_key.0);

        let mut location = Location::new(
            &path,
            line,
            RRTicks(step_id_int),
            &function_name,
            &call_key_text,
            &global_call_key_text,
            callstack_depth,
        );
        if function_name != "<top-level>" {
            let raw_path = self.path(step_record.path_id).unwrap_or("");
            match expr_loader.load_file(&PathBuf::from(raw_path)) {
                Ok(_) => {
                    let (fn_start, fn_last) = expr_loader.get_first_last_fn_lines(&location);
                    location.function_first = fn_start;
                    location.function_last = fn_last;
                }
                Err(e) => {
                    // No tree-sitter grammar for this language (Cairo, Circom, etc.).
                    // Fall back to the trace's own function line data.
                    warn!("expr loader load file error: {e:?} — using trace function boundaries");
                    if call_key != NO_KEY {
                        let call = self
                            .call(CallKey(call_key_int))
                            .expect("load_location: invalid call_key (fallback)");
                        let function_record = self
                            .function(call.function_id)
                            .expect("load_location: invalid function_id (fallback)");
                        location.function_first = function_record.line.0;
                        // Estimate function_last from the last step in this call.
                        let mut last_line = function_record.line.0;
                        let steps_len = self.step_count() as i64;
                        for i in step_id_int..steps_len {
                            let step = self.step(StepId(i)).expect("load_location: invalid step in range");
                            if step.call_key == CallKey(call_key_int) {
                                if step.line.0 > last_line {
                                    last_line = step.line.0;
                                }
                            } else {
                                break;
                            }
                        }
                        location.function_last = last_line;
                    }
                }
            }
        }
        location
    }

    // ── Transitional ───────────────────────────────────────────────

    /// Direct access to the underlying `Db`.
    ///
    /// This is a **transitional** escape hatch that allows code which
    /// has not yet been migrated to the `TraceReader` API to keep
    /// working.  Once every call-site goes through trait methods, this
    /// method will be removed.
    fn as_db(&self) -> &Db;
}
