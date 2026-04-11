module flow_test::flow_test {
    const E_INVALID_VALUE: u64 = 1;

    /// Helper: add two u64 values (exercises calltrace).
    fun add(a: u64, b: u64): u64 {
        a + b
    }

    /// Helper: double a value via multiplication.
    fun double(n: u64): u64 {
        n * 2
    }

    #[test]
    fun test_computation() {
        let a: u64 = 10;
        let b: u64 = 32;
        let sum_val: u64 = add(a, b);
        assert!(sum_val == 42, E_INVALID_VALUE);
        let doubled: u64 = double(sum_val);
        assert!(doubled == 84, E_INVALID_VALUE);
        let final_result: u64 = add(doubled, a);
        assert!(final_result == 94, E_INVALID_VALUE);

        // Conditional branch for branch-coverage testing.
        let label: u64 = if (final_result > 50) { 1 } else { 0 };
        assert!(label == 1, E_INVALID_VALUE);
    }
}
