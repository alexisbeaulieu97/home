#!/bin/bash

# Test to validate the fixes for issue #20:
# 1. Bug fix: directory files not included when recurse is set to false
# 2. Enhancement: add depth control when recurse is true

set -euo pipefail

cd /home/runner/work/home/home/modules/acl

source "test_framework.sh"

# Create a test version of the engine that doesn't run main
ENGINE_SCRIPT="engine.sh"
TEST_ENGINE="test_engine_issue20.sh"
if [[ ! -f "$TEST_ENGINE" ]]; then
    cp "$ENGINE_SCRIPT" "$TEST_ENGINE"
    # Comment out the main execution
    sed -i 's/^if \[\[ "${BASH_SOURCE\[0\]}" == "${0}" \]\]; then/# &/' "$TEST_ENGINE"
    sed -i 's/^    main "\$@"/# &/' "$TEST_ENGINE"
    sed -i 's/^fi$/# &/' "$TEST_ENGINE"
fi

# Source the test engine once
source "$TEST_ENGINE"

# Initialize config once
declare -A CONFIG=(
    [find_optimization]="true"
    [max_depth]=""
)

test_enumerate_paths_simple_non_recursive() {
    # Create test directory structure  
    local test_dir
    test_dir=$(mktemp -d)
    touch "$test_dir/file1.txt"
    touch "$test_dir/file2.log" 
    mkdir -p "$test_dir/subdir"
    touch "$test_dir/subdir/nested.txt"
    
    # Test non-recursive mode (the bug fix)
    local result
    result=$(enumerate_paths_simple "false" "true" "$test_dir")
    
    assert_contains "$result" "$test_dir" "should include root directory"
    assert_contains "$result" "$test_dir/file1.txt" "should include file1.txt when recurse=false"
    assert_contains "$result" "$test_dir/file2.log" "should include file2.log when recurse=false" 
    assert_contains "$result" "$test_dir/subdir" "should include subdir when recurse=false"
    assert_not_contains "$result" "$test_dir/subdir/nested.txt" "should not include nested file when recurse=false"
    
    rm -rf "$test_dir"
}

test_enumerate_paths_simple_depth_control() {
    # Create deeper test directory structure
    local test_dir
    test_dir=$(mktemp -d)
    mkdir -p "$test_dir/level1/level2/level3"
    touch "$test_dir/root.txt"
    touch "$test_dir/level1/file1.txt"
    touch "$test_dir/level1/level2/file2.txt"
    touch "$test_dir/level1/level2/level3/file3.txt"
    
    # Test depth limit = 1
    CONFIG[max_depth]="1"
    local result
    result=$(enumerate_paths_simple "true" "true" "$test_dir")
    
    assert_contains "$result" "$test_dir" "should include root"
    assert_contains "$result" "$test_dir/root.txt" "should include root file with depth=1"
    assert_contains "$result" "$test_dir/level1" "should include level1 with depth=1"
    assert_not_contains "$result" "$test_dir/level1/file1.txt" "should not include level1 file with depth=1"
    assert_not_contains "$result" "$test_dir/level1/level2" "should not include level2 with depth=1"
    
    # Test depth limit = 2 
    CONFIG[max_depth]="2"
    result=$(enumerate_paths_simple "true" "true" "$test_dir")
    
    assert_contains "$result" "$test_dir" "should include root"
    assert_contains "$result" "$test_dir/level1/file1.txt" "should include level1 file with depth=2"
    assert_contains "$result" "$test_dir/level1/level2" "should include level2 with depth=2"
    assert_not_contains "$result" "$test_dir/level1/level2/file2.txt" "should not include level2 file with depth=2"
    
    # Test no depth limit (unlimited)
    CONFIG[max_depth]=""
    result=$(enumerate_paths_simple "true" "true" "$test_dir")
    
    assert_contains "$result" "$test_dir/level1/level2/level3/file3.txt" "should include deepest file with no depth limit"
    
    rm -rf "$test_dir"
}

test_set_max_depth_validation() {
    # Test valid depths
    assert_command_succeeds "should accept depth 1" set_max_depth "1"
    assert_command_succeeds "should accept depth 10" set_max_depth "10"
    assert_command_succeeds "should accept depth 100" set_max_depth "100"
    
    # Test invalid depths
    assert_command_fails "should reject depth 0" set_max_depth "0"
    assert_command_fails "should reject negative depth" set_max_depth "-1"
    assert_command_fails "should reject non-numeric depth" set_max_depth "abc"
    assert_command_fails "should reject empty depth" set_max_depth ""
    assert_command_fails "should reject decimal depth" set_max_depth "1.5"
}

# Run tests
echo "=== Testing enumerate_paths_simple non-recursive (bug fix) ==="
test_enumerate_paths_simple_non_recursive

echo "=== Testing depth control feature ==="
test_enumerate_paths_simple_depth_control  

echo "=== Testing max depth validation ==="
test_set_max_depth_validation

echo "All tests passed!"

# Clean up
rm -f "$TEST_ENGINE"