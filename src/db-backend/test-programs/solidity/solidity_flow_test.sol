// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title FlowTest — Canonical flow/omniscience test contract
///
/// Implements the standard flow-test computation used across all CodeTracer
/// language backends:
///   a = 10, b = 32, sum_val = 42, doubled = 84, final_result = 94
///
/// Local variables in `run()` are the primary targets for DAP variable
/// extraction tests. The state variables (`storedA`, `storedResult`) are
/// verified by EVM storage-read/write trace entries.
contract FlowTest {
    /// Stored input value — set once on deployment.
    uint256 public storedA;
    /// Stored result of the last `run()` call.
    uint256 public storedResult;

    /// Emitted when `run()` completes, carrying the final result.
    event Computed(uint256 indexed result);

    constructor(uint256 a) {
        storedA = a;
    }

    /// Perform the canonical flow-test computation and store the result.
    ///
    /// Expected local-variable values at line 39 (`final_result` assignment):
    ///   a           = 10
    ///   b           = 32
    ///   sum_val     = 42   (a + b)
    ///   doubled     = 84   (sum_val * 2)
    ///   final_result = 94  (doubled + 10)
    function run() public returns (uint256) {
        uint256 a = 10;
        uint256 b = 32;
        uint256 sum_val = a + b;      // 42
        uint256 doubled = sum_val * 2; // 84
        uint256 final_result = doubled + 10; // 94

        storedResult = final_result;
        emit Computed(final_result);
        return final_result;
    }
}
