use serde::{Deserialize, Serialize};
use serde_repr::{Deserialize_repr, Serialize_repr};

#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq)]
pub struct RRTicks(pub i64);

#[derive(Debug, Default, Copy, Clone, Serialize_repr, Deserialize_repr, PartialEq)]
#[repr(u8)]
pub enum Action {
    #[default]
    StepIn,
    StepOut,
    Next,
    Continue,
    StepC,
    NextC,
    StepI,
    NextI,
    CoStepIn,
    CoNext,
    NonAction,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StepArg {
    pub action: Action,
    pub reverse: bool,
    pub repeat: usize,
    pub complete: bool,
    pub skip_internal: bool,
    pub skip_no_source: bool,
}

impl StepArg {
    pub fn new(action: Action, reverse: bool) -> StepArg {
        StepArg {
            action,
            reverse,
            repeat: 1,
            complete: true,
            skip_internal: false,
            skip_no_source: false,
        }
    }
}

#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Location {
    pub path: String,
    pub line: i64,
    pub function_name: String,
    pub high_level_path: String,
    pub high_level_line: i64,
    pub high_level_function_name: String,
    pub low_level_path: String,
    pub low_level_line: i64,
    pub rr_ticks: RRTicks,
    pub function_first: i64,
    pub function_last: i64,
    pub event: i64,
    pub expression: String,
    pub offset: i64,
    pub error: bool,
    pub callstack_depth: usize,
    pub originating_instruction_address: i64,
    pub key: String,
    pub global_call_key: String,
    pub expansion_parents: Vec<usize>,
    pub missing_path: bool,
}

#[derive(Debug, Default, Copy, Clone, Serialize_repr, Deserialize_repr, PartialEq)]
#[repr(u8)]
pub enum RRGDBStopSignal {
    #[default]
    NoStopSignal,
    SigsegvStopSignal,
    SigkillStopSignal,
    SighupStopSignal,
    SigintStopSignal,
    OtherStopSignal,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FrameInfo {
    pub offset: usize,
    pub has_selected: bool,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MoveState {
    pub status: String,
    pub location: Location,
    pub c_location: Location,
    pub main: bool,
    pub reset_flow: bool,
    pub stop_signal: RRGDBStopSignal,
    pub frame_info: FrameInfo,
}

/// A single stack frame returned by the DAP `stackTrace` response.
///
/// Matches the DAP `StackFrame` schema: an `id`, a display `name`
/// (typically the function name), line/column numbers, and an optional
/// `source` object containing the file path.
#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StackFrameInfo {
    pub id: i64,
    pub name: String,
    #[serde(default)]
    pub line: i64,
    #[serde(default)]
    pub column: i64,
    #[serde(default)]
    pub source: Option<StackFrameSource>,
}

/// Source reference inside a DAP `StackFrame`.
#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StackFrameSource {
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub path: Option<String>,
}

/// Parsed result of a DAP `stackTrace` response.
#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StackTraceResult {
    pub stack_frames: Vec<StackFrameInfo>,
    #[serde(default)]
    pub total_frames: Option<i64>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GoToTicksArguments {
    pub thread_id: i64,
    pub ticks: i64,
}
