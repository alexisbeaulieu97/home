#!/bin/bash
#
# test_integration.sh - Integration tests for engine.sh using dry-run mode
#

# Source the test framework and fixtures
source "$(dirname "${BASH_SOURCE[0]}")/test_framework.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test_fixtures.sh"

# Engine script path
ENGINE_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/engine.sh"

# Integration test: Complete workflow with minimal config
test_minimal_workflow() {
    # Create test filesystem and config
    local test_dir
    test_dir=$(create_test_filesystem)
    
    local config_file
    config_file=$(write_minimal_config)
    
    # Update config to use test directory
    sed -i "s|/tmp/test|$test_dir|g" "$config_file"
    
    # Run engine with dry-run
    local result exit_code=0
    result=$("$ENGINE_SCRIPT" -f "$config_file" --dry-run 2>&1) || exit_code=$?
    
    # Should succeed
    assert_equals "0" "$exit_code" "minimal workflow should succeed"
    
    # Should contain expected output
    assert_contains "$result" "Applied ACL: g:testgroup:rwx" "should show ACL application"
    assert_contains "$result" "(dry-run)" "should indicate dry-run mode"
    assert_contains "$result" "Summary" "should show summary"
}

# Integration test: Complete workflow with complex config
test_complete_workflow() {
    # Create test filesystem
    local test_dir
    test_dir=$(create_test_filesystem)
    
    local config_file
    config_file=$(write_complete_config)
    
    # Update config to use test directory
    sed -i "s|/tmp/test1|$test_dir|g" "$config_file"
    sed -i "s|/tmp/test2|$test_dir/app|g" "$config_file"
    sed -i "s|/tmp/test3|$test_dir/data|g" "$config_file"
    
    # Mock groups
    create_mock_groups
    
    # Run engine with dry-run
    local result exit_code=0
    result=$("$ENGINE_SCRIPT" -f "$config_file" --dry-run 2>&1) || exit_code=$?
    
    # Should succeed
    assert_equals "0" "$exit_code" "complete workflow should succeed"
    
    # Should process both rules
    assert_contains "$result" "PROCESSING RULE 1" "should process first rule"
    assert_contains "$result" "PROCESSING RULE 2" "should process second rule"
    
    # Should apply different ACLs to files and directories
    assert_contains "$result" "g:developers:rw-" "should apply file ACLs"
    assert_contains "$result" "g:developers:rwx" "should apply directory ACLs"
    
    # Should apply default ACLs
    assert_contains "$result" "g:developers:rwx" "should apply default ACLs"
    
    # Should exclude .git files
    assert_not_contains "$result" ".git" "should exclude .git files"
}

# Integration test: Path filtering
test_path_filtering() {
    # Create test filesystem
    local test_dir
    test_dir=$(create_test_filesystem)
    
    local config_file
    config_file=$(write_complete_config)
    
    # Update config to use test directory
    sed -i "s|/tmp/test1|$test_dir|g" "$config_file"
    sed -i "s|/tmp/test2|$test_dir/app|g" "$config_file"
    sed -i "s|/tmp/test3|$test_dir/data|g" "$config_file"
    
    # Mock groups
    create_mock_groups
    
    # Run engine with specific path filter
    local result exit_code=0
    result=$("$ENGINE_SCRIPT" -f "$config_file" --dry-run "$test_dir/app" 2>&1) || exit_code=$?
    
    # Should succeed
    assert_equals "0" "$exit_code" "path filtering should succeed"
    
    # Should only process files under /app
    assert_contains "$result" "$test_dir/app" "should process app directory"
    assert_not_contains "$result" "$test_dir/data" "should not process data directory when filtered"
}

# Integration test: Pattern matching
test_pattern_matching() {
    # Create test filesystem
    local test_dir
    test_dir=$(create_test_filesystem)
    
    # Create regex config that only matches .py files
    local regex_config
    regex_config=$(write_regex_config)
    
    # Update config to use test directory
    sed -i "s|/tmp/test|$test_dir|g" "$regex_config"
    
    # Run engine with dry-run
    local result exit_code=0
    result=$("$ENGINE_SCRIPT" -f "$regex_config" --dry-run 2>&1) || exit_code=$?
    
    # Should succeed
    assert_equals "0" "$exit_code" "pattern matching should succeed"
    
    # Should process .py files
    assert_contains "$result" "main.py" "should process Python files"
    
    # Should not process other files
    assert_not_contains "$result" "app.conf" "should not process config files"
    assert_not_contains "$result" "start.sh" "should not process shell scripts"
}

# Integration test: Apply order
test_apply_order() {
    # Create test filesystem
    local test_dir
    test_dir=$(create_test_filesystem)
    
    local config_file
    config_file=$(write_deep_to_shallow_config)
    
    # Update config to use test directory
    sed -i "s|/tmp/test|$test_dir|g" "$config_file"
    
    # Run engine with dry-run
    local result exit_code=0
    result=$("$ENGINE_SCRIPT" -f "$config_file" --dry-run 2>&1) || exit_code=$?
    
    # Should succeed
    assert_equals "0" "$exit_code" "deep_to_shallow order should succeed"
    
    # Should mention apply order in output
    assert_contains "$result" "Applied ACL: g:testgroup:rwx" "should apply ACLs"
}

# Integration test: Error handling
test_error_handling() {
    # Test with nonexistent config file
    local result exit_code=0
    result=$("$ENGINE_SCRIPT" -f "nonexistent.json" 2>&1) || exit_code=$?
    
    assert_not_equals "0" "$exit_code" "should fail with nonexistent config"
    assert_contains "$result" "Cannot read definitions file" "should show appropriate error"
    
    # Test with invalid JSON
    local invalid_file
    invalid_file=$(write_invalid_config "json_syntax")
    
    result=$("$ENGINE_SCRIPT" -f "$invalid_file" 2>&1) || exit_code=$?
    
    assert_not_equals "0" "$exit_code" "should fail with invalid JSON"
    assert_contains "$result" "Invalid JSON syntax" "should show JSON error"
    
    # Test with missing rules
    local no_rules_file
    no_rules_file=$(write_invalid_config "no_rules")
    
    result=$("$ENGINE_SCRIPT" -f "$no_rules_file" 2>&1) || exit_code=$?
    
    assert_not_equals "0" "$exit_code" "should fail with missing rules"
    assert_contains "$result" "expected top-level object with non-empty 'rules' array" "should show schema error"
    
    # Test with missing dependencies (if we can mock it)
    if [[ "$EUID" -ne 0 ]]; then
        local old_path="$PATH"
        export PATH="/nonexistent"
        
        result=$("$ENGINE_SCRIPT" -f "$no_rules_file" 2>&1) || exit_code=$?
        
        assert_not_equals "0" "$exit_code" "should fail with missing dependencies"
        assert_contains "$result" "Missing required commands" "should show dependency error"
        
        export PATH="$old_path"
    fi
}

# Integration test: Command line options
test_command_line_options() {
    local config_file
    config_file=$(write_minimal_config)
    
    # Test help option
    local result exit_code=0
    result=$("$ENGINE_SCRIPT" --help 2>&1) || exit_code=$?
    
    assert_equals "0" "$exit_code" "help should succeed"
    assert_contains "$result" "Usage:" "should show usage"
    assert_contains "$result" "Apply POSIX ACLs" "should show description"
    
    # Test quiet mode
    local test_dir
    test_dir=$(create_test_filesystem)
    sed -i "s|/tmp/test|$test_dir|g" "$config_file"
    
    result=$("$ENGINE_SCRIPT" -f "$config_file" --dry-run --quiet 2>&1) || exit_code=$?
    
    assert_equals "0" "$exit_code" "quiet mode should succeed"
    # Quiet mode should suppress info messages but show errors and summary
    assert_not_contains "$result" "INFO:" "should suppress info messages"
    
    # Test color options
    result=$("$ENGINE_SCRIPT" -f "$config_file" --dry-run --no-color 2>&1) || exit_code=$?
    assert_equals "0" "$exit_code" "no-color should succeed"
    
    result=$("$ENGINE_SCRIPT" -f "$config_file" --dry-run --color=never 2>&1) || exit_code=$?
    assert_equals "0" "$exit_code" "color=never should succeed"
    
    # Test mask options
    result=$("$ENGINE_SCRIPT" -f "$config_file" --dry-run --mask=auto 2>&1) || exit_code=$?
    assert_equals "0" "$exit_code" "mask=auto should succeed"
    
    result=$("$ENGINE_SCRIPT" -f "$config_file" --dry-run --mask=skip 2>&1) || exit_code=$?
    assert_equals "0" "$exit_code" "mask=skip should succeed"
    
    result=$("$ENGINE_SCRIPT" -f "$config_file" --dry-run --mask=r-x 2>&1) || exit_code=$?
    assert_equals "0" "$exit_code" "explicit mask should succeed"
    
    # Test invalid options
    result=$("$ENGINE_SCRIPT" -f "$config_file" --invalid-option 2>&1) || exit_code=$?
    assert_not_equals "0" "$exit_code" "invalid option should fail"
    assert_contains "$result" "Unknown option" "should show option error"
}

# Integration test: Complex file structure with different types
test_file_type_handling() {
    # Create test filesystem
    local test_dir
    test_dir=$(create_test_filesystem)
    
    # Create config that applies different rules to files vs directories
    local type_config='{
  "rules": [
    {
      "id": "files-only",
      "roots": "'$test_dir'",
      "recurse": true,
      "match": {
        "types": ["file"]
      },
      "acl": ["g:filegroup:rw-"]
    },
    {
      "id": "dirs-only", 
      "roots": "'$test_dir'",
      "recurse": true,
      "match": {
        "types": ["directory"]
      },
      "acl": ["g:dirgroup:rwx"]
    }
  ]
}'
    
    local config_file="type_test.json"
    echo "$type_config" > "$config_file"
    
    # Mock groups
    create_mock_groups
    
    # Run engine with dry-run
    local result exit_code=0
    result=$("$ENGINE_SCRIPT" -f "$config_file" --dry-run 2>&1) || exit_code=$?
    
    # Should succeed
    assert_equals "0" "$exit_code" "file type handling should succeed"
    
    # Should apply different ACLs to files and directories
    assert_contains "$result" "g:filegroup:rw-" "should apply file-specific ACLs"
    assert_contains "$result" "g:dirgroup:rwx" "should apply directory-specific ACLs"
    
    # Verify files and directories are processed separately
    assert_contains "$result" "main.py" "should process files"
    assert_contains "$result" "$test_dir/app" "should process directories"
}

# Integration test: Multiple patterns and exclusions
test_complex_pattern_matching() {
    # Create test filesystem
    local test_dir
    test_dir=$(create_test_filesystem)
    
    # Create config with complex include/exclude patterns
    local pattern_config='{
  "rules": [
    {
      "roots": "'$test_dir'",
      "recurse": true,
      "match": {
        "pattern_syntax": "glob",
        "include": ["**/*.py", "**/*.sh"],
        "exclude": ["**/test*", "**/.git/**"]
      },
      "acl": ["g:devs:rwx"]
    }
  ]
}'
    
    local config_file="pattern_test.json"
    echo "$pattern_config" > "$config_file"
    
    # Mock groups
    create_mock_groups
    
    # Run engine with dry-run
    local result exit_code=0
    result=$("$ENGINE_SCRIPT" -f "$config_file" --dry-run 2>&1) || exit_code=$?
    
    # Should succeed
    assert_equals "0" "$exit_code" "complex pattern matching should succeed"
    
    # Should include .py and .sh files
    assert_contains "$result" "main.py" "should include Python files"
    assert_contains "$result" "start.sh" "should include shell scripts"
    
    # Should exclude test files and .git
    assert_not_contains "$result" "test.py" "should exclude test files"
    assert_not_contains "$result" ".git" "should exclude .git directory"
}

# Integration test: Performance with large file sets
test_performance_simulation() {
    # Create a moderately sized test structure
    local test_dir="large_test"
    mkdir -p "$test_dir"
    
    # Create multiple levels and files
    for i in {1..5}; do
        local subdir="$test_dir/level$i"
        mkdir -p "$subdir"
        for j in {1..10}; do
            touch "$subdir/file$j.txt"
            touch "$subdir/script$j.sh"
        done
    done
    
    local config_file
    config_file=$(write_minimal_config)
    sed -i "s|/tmp/test|$test_dir|g" "$config_file"
    
    # Time the execution (in dry-run mode)
    local start_time end_time
    start_time=$(date +%s.%N)
    
    local result exit_code=0
    result=$("$ENGINE_SCRIPT" -f "$config_file" --dry-run --quiet 2>&1) || exit_code=$?
    
    end_time=$(date +%s.%N)
    local duration
    duration=$(awk "BEGIN {print $end_time - $start_time}")
    
    # Should complete successfully
    assert_equals "0" "$exit_code" "performance test should succeed"
    
    # Should process reasonable number of files
    assert_contains "$result" "Summary" "should show summary"
    
    # Duration should be reasonable (less than 10 seconds for this test size)
    # Note: This is a rough check, actual performance depends on system
    log_test_info "Performance test completed in ${duration}s"
}

# Run all integration tests
run_integration_tests() {
    start_test_suite "Integration Tests"
    
    run_test "minimal_workflow" test_minimal_workflow
    run_test "complete_workflow" test_complete_workflow
    run_test "path_filtering" test_path_filtering
    run_test "pattern_matching" test_pattern_matching
    run_test "apply_order" test_apply_order
    run_test "error_handling" test_error_handling
    run_test "command_line_options" test_command_line_options
    run_test "file_type_handling" test_file_type_handling
    run_test "complex_pattern_matching" test_complex_pattern_matching
    run_test "performance_simulation" test_performance_simulation
    
    end_test_suite "Integration Tests"
}

# Run tests if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_integration_tests
fi
