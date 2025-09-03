#!/bin/bash
#
# test_simple.sh - Simple test to verify the framework works
#

# Source the test framework
source "$(dirname "${BASH_SOURCE[0]}")/test_framework.sh"

# Simple test function
test_basic_assertions() {
    assert_equals "hello" "hello" "strings should match"
    assert_not_equals "hello" "world" "strings should not match"
    assert_contains "hello world" "world" "should contain substring"
    assert_command_succeeds "true should succeed" true
    assert_command_fails "false should fail" false
}

# Run tests
run_simple_tests() {
    start_test_suite "Simple Tests"
    
    run_test "basic_assertions" test_basic_assertions
    
    end_test_suite "Simple Tests"
}

# Run tests if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_simple_tests
fi
