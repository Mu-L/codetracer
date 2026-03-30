use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::Value;

use crate::client::DapStdioClient;
use crate::types::flow::{FlowMode, LoadFlowArguments};
use crate::types::launch::LaunchRequestArguments;

use super::{find_ct_rr_support, prepare_trace_folder};

type BoxError = Box<dyn std::error::Error + Send + Sync>;

/// Configuration for a flow test case.
pub struct FlowTestConfig {
    pub source_file: String,
    pub breakpoint_line: usize,
    /// Variables that SHOULD be extracted (local vars, params).
    pub expected_variables: Vec<String>,
    /// Identifiers that should NOT be extracted (function calls, macros).
    pub excluded_identifiers: Vec<String>,
    /// Expected values for specific variables (name -> expected int value).
    pub expected_values: HashMap<String, i64>,
}

/// Parsed flow data from a ct/updated-flow event.
#[derive(Debug)]
pub struct FlowData {
    pub steps: Vec<FlowStep>,
    /// All variable names extracted (may contain duplicates).
    pub all_variables: Vec<String>,
    /// Map of variable name to its most recent value.
    pub values: HashMap<String, Value>,
}

/// A single step in the flow.
#[derive(Debug)]
pub struct FlowStep {
    pub line: i64,
    pub variables: Vec<String>,
    pub before_values: HashMap<String, Value>,
}

impl FlowData {
    /// Parse the ct/updated-flow event body into FlowData.
    pub fn from_event_body(body: &Value) -> Result<Self, BoxError> {
        let view_updates = body
            .get("viewUpdates")
            .and_then(|v| v.as_array())
            .ok_or("viewUpdates should exist")?;

        let first_update = view_updates
            .first()
            .ok_or("should have at least one view update")?;

        let steps_json = first_update
            .get("steps")
            .and_then(|s| s.as_array())
            .ok_or("steps should exist")?;

        let mut steps = Vec::new();
        let mut all_variables = Vec::new();
        let mut values = HashMap::new();

        for step_json in steps_json {
            let line = step_json
                .get("position")
                .and_then(|l| l.as_i64())
                .or_else(|| step_json.get("line").and_then(|l| l.as_i64()))
                .unwrap_or(0);

            let mut variables = Vec::new();
            if let Some(expr_order) = step_json.get("exprOrder").and_then(|e| e.as_array()) {
                for expr in expr_order {
                    if let Some(var_name) = expr.as_str() {
                        variables.push(var_name.to_string());
                        all_variables.push(var_name.to_string());
                    }
                }
            }

            let mut before_values = HashMap::new();
            if let Some(bv) = step_json.get("beforeValues").and_then(|v| v.as_object()) {
                for (var_name, value) in bv {
                    before_values.insert(var_name.clone(), value.clone());
                    values.insert(var_name.clone(), value.clone());
                }
            }

            steps.push(FlowStep {
                line,
                variables,
                before_values,
            });
        }

        Ok(FlowData {
            steps,
            all_variables,
            values,
        })
    }

    /// Check if a value was successfully loaded (not `<NONE>`).
    pub fn is_value_loaded(value: &Value) -> bool {
        if let Some(r_val) = value.get("r").and_then(|v| v.as_str()) {
            return r_val != "<NONE>";
        }
        false
    }

    /// Extract an integer value from a flow value structure.
    pub fn extract_int_value(value: &Value) -> Option<i64> {
        if let Some(i_val) = value.get("i").and_then(|v| v.as_str()) {
            if !i_val.is_empty() {
                if let Ok(n) = i_val.parse::<i64>() {
                    return Some(n);
                }
            }
        }
        if let Some(r_val) = value.get("r").and_then(|v| v.as_str()) {
            if r_val != "<NONE>" && !r_val.is_empty() {
                if let Ok(n) = r_val.parse::<i64>() {
                    return Some(n);
                }
            }
        }
        None
    }
}

/// High-level test runner that manages the DAP lifecycle for flow tests.
pub struct FlowTestRunner {
    client: DapStdioClient,
    _trace_wrapper: Option<PathBuf>,
}

impl FlowTestRunner {
    /// Spawn db-backend, run DAP init sequence with the given RR trace folder.
    pub fn new(db_backend_bin: &Path, rr_trace_dir: &Path) -> Result<Self, BoxError> {
        let (launch_folder, wrapper) = prepare_trace_folder(rr_trace_dir)?;
        let ct_rr_worker_exe = find_ct_rr_support()?;

        let mut client = DapStdioClient::spawn(db_backend_bin)?;

        let _caps = client.initialize()?;

        client.launch(LaunchRequestArguments {
            trace_folder: Some(launch_folder),
            ct_rr_worker_exe: Some(ct_rr_worker_exe),
            ..Default::default()
        })?;

        client.configuration_done()?;
        client.wait_for_stopped(Duration::from_secs(60))?;

        Ok(FlowTestRunner {
            client,
            _trace_wrapper: wrapper,
        })
    }

    /// Spawn db-backend, run DAP init sequence with a DB trace folder.
    ///
    /// Unlike `new()` (for RR traces), this does NOT need ct-rr-support or
    /// prepare_trace_folder. DB traces (Python, Ruby, JavaScript, Noir, WASM)
    /// are self-contained: the trace folder has trace.json/trace.bin +
    /// trace_metadata.json and db-backend auto-detects the format.
    pub fn new_db_trace(db_backend_bin: &Path, trace_dir: &Path) -> Result<Self, BoxError> {
        let mut client = DapStdioClient::spawn(db_backend_bin)?;

        let _caps = client.initialize()?;

        client.launch(LaunchRequestArguments {
            trace_folder: Some(trace_dir.to_path_buf()),
            ..Default::default()
        })?;

        client.configuration_done()?;
        client.wait_for_stopped(Duration::from_secs(60))?;

        Ok(FlowTestRunner {
            client,
            _trace_wrapper: None,
        })
    }

    /// Run the flow test: set breakpoint, continue to it, load flow, verify results.
    pub fn run_and_verify(&mut self, config: &FlowTestConfig) -> Result<(), BoxError> {
        // 1. Set breakpoint
        self.client
            .set_breakpoints(&config.source_file, &[config.breakpoint_line])?;

        // 2. Continue to breakpoint
        let move_state = self.client.dap_continue()?;
        println!(
            "Stopped at {}:{}",
            move_state.location.path, move_state.location.line
        );

        // 3. Load flow at current location
        let flow_body = self.client.load_flow(LoadFlowArguments {
            flow_mode: FlowMode::Call,
            location: move_state.location,
        })?;

        // 4. Parse flow data
        let flow = FlowData::from_event_body(&flow_body)?;

        // 5. Verify
        self.verify_flow_results(config, &flow)?;

        Ok(())
    }

    fn verify_flow_results(
        &self,
        config: &FlowTestConfig,
        flow: &FlowData,
    ) -> Result<(), BoxError> {
        verify_flow_results(config, flow)
    }

    /// Access the underlying client for additional operations.
    pub fn client(&mut self) -> &mut DapStdioClient {
        &mut self.client
    }

    /// Clean shutdown.
    pub fn finish(self) -> Result<(), BoxError> {
        self.client.disconnect()?;
        Ok(())
    }
}

/// Verify flow results against the expected configuration.
///
/// This is extracted as a free function so it can be unit-tested without
/// needing a full `FlowTestRunner` (which requires a live DAP subprocess).
/// The `FlowTestRunner::verify_flow_results` method delegates to this.
fn verify_flow_results(
    config: &FlowTestConfig,
    flow: &FlowData,
) -> Result<(), BoxError> {
    println!("\nVerifying flow data...");
    println!(
        "  Total steps: {}, all_variables: {:?}",
        flow.steps.len(),
        flow.all_variables
    );

    // Check excluded identifiers are NOT in the list
    for excluded in &config.excluded_identifiers {
        if flow.all_variables.contains(excluded) {
            return Err(format!(
                "'{}' should not be extracted as a variable (it's a function call)",
                excluded
            )
            .into());
        }
    }
    println!("  Function call filtering PASSED");

    // Check expected variables ARE in the list
    let found_expected: Vec<&String> = config
        .expected_variables
        .iter()
        .filter(|v| flow.all_variables.contains(v))
        .collect();
    println!("  Expected variables found: {:?}", found_expected);

    if found_expected.is_empty() {
        return Err(format!(
            "should find at least some of the expected variables: {:?}",
            config.expected_variables
        )
        .into());
    }
    println!("  Variable extraction PASSED");

    // Check value loading
    let mut loaded = 0;
    let mut not_loaded = 0;
    for value in flow.values.values() {
        if FlowData::is_value_loaded(value) {
            loaded += 1;
        } else {
            not_loaded += 1;
        }
    }
    println!("  Loaded: {}, Not loaded: {}", loaded, not_loaded);

    // Verify specific expected values — every entry in expected_values
    // MUST be present, loaded, parseable, and correct.
    let mut verified_count = 0;
    for (var_name, expected_value) in &config.expected_values {
        if let Some(value) = flow.values.get(var_name) {
            if FlowData::is_value_loaded(value) {
                if let Some(actual) = FlowData::extract_int_value(value) {
                    if actual != *expected_value {
                        return Err(format!(
                            "{} should be {}, got {}",
                            var_name, expected_value, actual
                        )
                        .into());
                    }
                    println!("  {} = {} (correct)", var_name, actual);
                    verified_count += 1;
                } else {
                    return Err(format!(
                        "variable '{}' has a loaded value but it could not be \
                         extracted as an integer (raw value: {:?})",
                        var_name, value
                    )
                    .into());
                }
            } else {
                println!("  {} = <NONE>", var_name);
                return Err(format!(
                    "variable '{}' is present but its value was not loaded (<NONE>)",
                    var_name
                )
                .into());
            }
        } else {
            return Err(format!(
                "expected variable '{}' is missing from flow.values (available: {:?})",
                var_name,
                flow.values.keys().collect::<Vec<_>>()
            )
            .into());
        }
    }

    if !config.expected_values.is_empty() && verified_count != config.expected_values.len() {
        return Err(format!(
            "only {}/{} expected values were verified",
            verified_count,
            config.expected_values.len()
        )
        .into());
    }

    if loaded == 0 {
        return Err("No values were loaded - local variables should be loadable".into());
    }
    println!("  Value loading PASSED for {} variables", loaded);
    println!("\nFlow test completed successfully!");

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// Build a minimal `FlowTestConfig` expecting a single variable with a
    /// specific integer value.
    fn config_expecting(var_name: &str, value: i64) -> FlowTestConfig {
        let mut expected_values = HashMap::new();
        expected_values.insert(var_name.to_string(), value);
        FlowTestConfig {
            source_file: "test.c".to_string(),
            breakpoint_line: 1,
            expected_variables: vec![var_name.to_string()],
            excluded_identifiers: vec![],
            expected_values,
        }
    }

    /// Build a `FlowData` containing one step with the given variable names
    /// and their associated flow values.
    ///
    /// Each entry in `vars` is `(name, value_json)` where `value_json` is the
    /// flow-format value object (e.g. `{"r": "42", "i": "42"}`).
    fn flow_with_vars(vars: &[(&str, Value)]) -> FlowData {
        let mut all_variables = Vec::new();
        let mut values = HashMap::new();
        let mut step_variables = Vec::new();
        let mut before_values = HashMap::new();

        for (name, val) in vars {
            let name = name.to_string();
            all_variables.push(name.clone());
            step_variables.push(name.clone());
            before_values.insert(name.clone(), val.clone());
            values.insert(name, val.clone());
        }

        FlowData {
            steps: vec![FlowStep {
                line: 1,
                variables: step_variables,
                before_values,
            }],
            all_variables,
            values,
        }
    }

    /// Helper to build the flow-format value JSON for an integer.
    /// The format stores both a representation string (`r`) and an integer
    /// string (`i`), matching what `FlowData::extract_int_value` expects.
    fn int_flow_value(n: i64) -> Value {
        json!({"r": n.to_string(), "i": n.to_string()})
    }

    #[test]
    fn test_verify_rejects_missing_variable() {
        let config = config_expecting("x", 42);
        // FlowData has variable "y" but NOT "x".
        let flow = flow_with_vars(&[("y", int_flow_value(10))]);

        let result = verify_flow_results(&config, &flow);
        assert!(
            result.is_err(),
            "verify_flow_results should return Err when expected variable is absent"
        );
        let err_msg = result.unwrap_err().to_string();
        assert!(
            err_msg.contains("x"),
            "error message should mention the missing variable 'x', got: {}",
            err_msg
        );
    }

    #[test]
    fn test_verify_rejects_wrong_value() {
        let config = config_expecting("x", 42);
        // FlowData has "x" but with value 99 instead of 42.
        let flow = flow_with_vars(&[("x", int_flow_value(99))]);

        let result = verify_flow_results(&config, &flow);
        assert!(
            result.is_err(),
            "verify_flow_results should return Err when variable has wrong value"
        );
        let err_msg = result.unwrap_err().to_string();
        assert!(
            err_msg.contains("42") && err_msg.contains("99"),
            "error message should mention both expected (42) and actual (99), got: {}",
            err_msg
        );
    }

    #[test]
    fn test_verify_accepts_correct_values() {
        let config = config_expecting("x", 42);
        let flow = flow_with_vars(&[("x", int_flow_value(42))]);

        let result = verify_flow_results(&config, &flow);
        assert!(
            result.is_ok(),
            "verify_flow_results should return Ok when values match, got: {:?}",
            result.unwrap_err()
        );
    }
}
