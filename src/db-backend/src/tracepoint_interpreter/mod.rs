#[cfg(feature = "syntax-highlight")]
mod compiler;
#[cfg(feature = "syntax-highlight")]
mod executor;
#[cfg(feature = "syntax-highlight")]
mod interpreter;
mod operator_functions;

#[cfg(test)]
mod tests;

use std::collections::HashMap;

#[cfg(feature = "syntax-highlight")]
pub use interpreter::TracepointInterpreter;

use crate::value::{Type, Value, ValueRecordWithType};

#[cfg(feature = "syntax-highlight")]
#[derive(Debug, Clone)]
enum Instruction {
    Log,                     // pops and logs stack[^1]
    PushVariable(String),    // adds its arg to top of stack
    PushInt(i64),            // adds its arg to top of stack
    PushFloat(f64),          // adds its arg to top of stack
    PushBool(bool),          // adds its arg to top of stack
    PushString(String),      // adds its arg to top of stack
    CallExpression(String),  // evaluates the call expression in the replay engine
    Index,                   // pops ^2, ^1 before pushing ^2[^1]
    Field(String),           // pops ^1 brefore pushing ^1.<arg>
    UnaryOperation(String),  // pops ^1 before pushing <op> ^1
    BinaryOperation(String), // pops ^2, ^1 before pushing ^2 <op> ^1
    JumpIfFalse(i64),        // pops ^1 and if ^1 is false, adds its arg to the program counter
}

#[cfg(feature = "syntax-highlight")]
#[derive(Debug, Clone)]
struct Opcode {
    instruction: Instruction,
    position: tree_sitter::Range,
}

#[cfg(feature = "syntax-highlight")]
impl Opcode {
    fn new(instruction: Instruction, position: tree_sitter::Range) -> Opcode {
        Opcode { instruction, position }
    }
}

#[cfg(feature = "syntax-highlight")]
#[derive(Debug, Clone, Default)]
struct Bytecode {
    opcodes: Vec<Opcode>,
}

// op(operand, error_value_type)
type UnaryOperatorFunction = fn(ValueRecordWithType, &Type) -> Result<ValueRecordWithType, Value>;
type UnaryOperatorFunctions = HashMap<String, UnaryOperatorFunction>;

// op(left_operand, right_operand, error_value_type)
type BinaryOperatorFunction = fn(ValueRecordWithType, ValueRecordWithType, &Type) -> Result<ValueRecordWithType, Value>;
type BinaryOperatorFunctions = HashMap<String, BinaryOperatorFunction>;

// Stub implementation when tree-sitter is not available.  Tracepoint
// compilation and evaluation require tree-sitter grammars, so the stub
// simply returns empty results / no-ops.
#[cfg(not(feature = "syntax-highlight"))]
#[derive(Debug)]
pub struct TracepointInterpreter {
    _tracepoint_count: usize,
}

#[cfg(not(feature = "syntax-highlight"))]
impl TracepointInterpreter {
    pub fn new(tracepoint_count: usize) -> Self {
        Self {
            _tracepoint_count: tracepoint_count,
        }
    }

    pub fn register_tracepoint(
        &mut self,
        _tracepoint_index: usize,
        _source: &str,
    ) -> Result<(), Box<dyn std::error::Error>> {
        // Without tree-sitter we cannot compile tracepoint expressions.
        Err("tracepoint compilation requires the syntax-highlight feature".into())
    }

    pub fn evaluate(
        &self,
        _tracepoint_index: usize,
        _step_id: codetracer_trace_types::StepId,
        _replay: &mut dyn crate::replay::ReplaySession,
        _lang: crate::lang::Lang,
    ) -> Vec<crate::task::StringAndValueTuple> {
        // No bytecode to execute — return empty results.
        vec![]
    }
}
