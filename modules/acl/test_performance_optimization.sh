#!/bin/bash
#
# test_performance_optimization.sh - Test ACL performance optimization
#

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly RESET='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

test_pass() {
    printf "%b[PASS]%b %s\n" "$GREEN" "$RESET" "$*"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

test_fail() {
    printf "%b[FAIL]%b %s\n" "$RED" "$RESET" "$*"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

test_bulk_recursive_optimization() {
    local test_dir="/tmp/test_acl_bulk_$$"
    mkdir -p "$test_dir/subdir1/subdir2"
    echo "file1" > "$test_dir/file1.txt"
    echo "file2" > "$test_dir/subdir1/file2.txt"
    echo "file3" > "$test_dir/subdir1/subdir2/file3.txt"
    
    # Test config without match filters (should use optimization)
    local config_optimized="$test_dir/config_optimized.json"
    cat > "$config_optimized" << EOF
{
  "version": "1.0",
  "rules": [
    {
      "id": "test-optimized",
      "roots": ["$test_dir"],
      "recurse": true,
      "include_self": true,
      "acl": {
        "files": [{"kind": "group", "name": "users", "mode": "rw-"}],
        "directories": [{"kind": "group", "name": "users", "mode": "rwx"}]
      }
    }
  ]
}
EOF
    
    # Test config with match filters (should use individual processing)
    local config_individual="$test_dir/config_individual.json"
    cat > "$config_individual" << EOF
{
  "version": "1.0",
  "rules": [
    {
      "id": "test-individual",
      "roots": ["$test_dir"],
      "recurse": true,
      "include_self": true,
      "match": {
        "types": ["file", "directory"],
        "pattern_syntax": "glob",
        "include": ["**/*"],
        "exclude": []
      },
      "acl": {
        "files": [{"kind": "group", "name": "users", "mode": "rw-"}],
        "directories": [{"kind": "group", "name": "users", "mode": "rwx"}]
      }
    }
  ]
}
EOF
    
    # Run both and capture output
    local output_optimized output_individual
    output_optimized=$(./engine.sh -f "$config_optimized" --dry-run 2>&1)
    output_individual=$(./engine.sh -f "$config_individual" --dry-run 2>&1)
    
    # Verify optimization message appears in optimized version
    if echo "$output_optimized" | grep -q "Using optimized recursive processing"; then
        test_pass "Optimization message detected in optimized config"
    else
        test_fail "Optimization message NOT detected in optimized config"
    fi
    
    # Verify optimization message does NOT appear in individual version
    if echo "$output_individual" | grep -q "Using optimized recursive processing"; then
        test_fail "Optimization message incorrectly detected in individual config"
    else
        test_pass "Optimization correctly avoided in individual config"
    fi
    
    # Verify both achieve success
    if echo "$output_optimized" | grep -q "paths ok=1 failed=0"; then
        test_pass "Optimized approach succeeded"
    else
        test_fail "Optimized approach failed: $output_optimized"
    fi
    
    # Count how many paths the individual approach processed
    local individual_path_count
    individual_path_count=$(echo "$output_individual" | grep -o "paths ok=[0-9]*" | grep -o "[0-9]*")
    if [[ "$individual_path_count" -ge 4 ]]; then
        test_pass "Individual approach processed $individual_path_count paths as expected"
    else
        test_fail "Individual approach processed unexpected number of paths: $individual_path_count"
    fi
    
    # Check that optimized version shows -R flag usage
    if echo "$output_optimized" | grep -q "setfacl -R"; then
        test_pass "Optimized version uses -R flag as expected"
    else
        test_fail "Optimized version does not use -R flag"
    fi
    
    # Check that individual version does NOT use -R flag
    if echo "$output_individual" | grep -q "setfacl -R"; then
        test_fail "Individual version incorrectly uses -R flag"
    else
        test_pass "Individual version correctly avoids -R flag"
    fi
    
    # Cleanup
    rm -rf "$test_dir"
}

# Main test execution
main() {
    echo "=== Testing ACL Performance Optimization ==="
    
    echo "[TEST] Testing bulk recursive optimization"
    test_bulk_recursive_optimization
    
    echo "=== Test Results ==="
    echo "Passed: $TESTS_PASSED"
    echo "Failed: $TESTS_FAILED"
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo "All tests passed!"
        exit 0
    else
        echo "$TESTS_FAILED tests failed"
        exit 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi