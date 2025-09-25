#!/bin/bash
#
# test_validation.sh - Unit tests for validation functions in engine.sh
#

# Source the test framework and fixtures
source "$(dirname "${BASH_SOURCE[0]}")/test_framework.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test_fixtures.sh"

# Source the engine.sh script to test its functions
ENGINE_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/engine.sh"

# Global test engine - created once and reused
TEST_ENGINE_SOURCED=false

# Setup test engine for all tests
setup_test_engine() {
    if [[ "$TEST_ENGINE_SOURCED" == "false" ]]; then
        if [[ ! -f "$ENGINE_SCRIPT" ]]; then
            echo "Error: ENGINE_SCRIPT not found at $ENGINE_SCRIPT" >&2
            return 1
        fi
        
        # Source the engine directly but prevent main execution
        local temp_file=$(mktemp)
        sed 's/^if \[\[ "${BASH_SOURCE\[0\]}" == "${0}" \]\]; then/# &/' "$ENGINE_SCRIPT" | \
        sed 's/^    main "\$@"/# &/' | \
        sed 's/^fi$/# &/' > "$temp_file"
        
        source "$temp_file"
        rm -f "$temp_file"
        TEST_ENGINE_SOURCED=true
    fi
}

# Test validation predicates
test_is_readable_file() {
    setup_test_engine
    
    # Create test files
    local readable_file="readable.txt"
    local nonexistent_file="nonexistent.txt"
    local unreadable_file="unreadable.txt"
    
    echo "test content" > "$readable_file"
    echo "test content" > "$unreadable_file"
    chmod 000 "$unreadable_file"
    
    # Test readable file
    assert_command_succeeds "readable file should pass" is_readable_file "$readable_file"
    
    # Test nonexistent file
    assert_command_fails "nonexistent file should fail" is_readable_file "$nonexistent_file"
    
    # Test unreadable file (if we have permission to make it unreadable)
    if [[ "$EUID" -ne 0 ]]; then
        assert_command_fails "unreadable file should fail" is_readable_file "$unreadable_file"
    fi
    
    # Cleanup
    chmod 644 "$unreadable_file" 2>/dev/null || true
}

test_is_valid_json() {
    setup_test_engine
    
    # Create test files
    local valid_json="valid.json"
    local invalid_json="invalid.json"
    
    echo '{"test": "value"}' > "$valid_json"
    echo '{"test": "value"' > "$invalid_json"  # Missing closing brace
    
    # Test valid JSON
    assert_command_succeeds "valid JSON should pass" is_valid_json "$valid_json"
    
    # Test invalid JSON
    assert_command_fails "invalid JSON should fail" is_valid_json "$invalid_json"
}

test_is_valid_path() {
    setup_test_engine
    
    # Test valid paths
    assert_command_succeeds "absolute path should be valid" is_valid_path "/tmp/test"
    assert_command_succeeds "relative path should be valid" is_valid_path "test/path"
    assert_command_succeeds "single character should be valid" is_valid_path "a"
    
    # Test invalid paths
    assert_command_fails "empty path should be invalid" is_valid_path ""
    assert_command_fails "path with newline should be invalid" is_valid_path $'multi\nline'
}

test_is_valid_group() {
    setup_test_engine
    
    # Test valid group names
    for group in "${VALID_GROUPS[@]}"; do
        assert_command_succeeds "group '$group' should be valid" is_valid_group "$group"
    done
    
    # Test invalid group names
    for group in "${INVALID_GROUPS[@]}"; do
        assert_command_fails "group '$group' should be invalid" is_valid_group "$group"
    done
}

test_is_valid_perms() {
    setup_test_engine
    
    # Test valid permission modes
    for mode in "${VALID_MODES[@]}"; do
        assert_command_succeeds "mode '$mode' should be valid" is_valid_perms "$mode"
    done
    
    # Test invalid permission modes
    for mode in "${INVALID_MODES[@]}"; do
        assert_command_fails "mode '$mode' should be invalid" is_valid_perms "$mode"
    done
}

test_is_valid_mask() {
    setup_test_engine
    
    # Test valid mask values
    local valid_masks=("rwx" "rw-" "r-x" "r--" "---")
    for mask in "${valid_masks[@]}"; do
        assert_command_succeeds "mask '$mask' should be valid" is_valid_mask "$mask"
    done
    
    # Test invalid mask values
    local invalid_masks=("rwxw" "xyz" "invalid" "" "rwX")  # X not allowed in mask
    for mask in "${invalid_masks[@]}"; do
        assert_command_fails "mask '$mask' should be invalid" is_valid_mask "$mask"
    done
}

test_validate_dependencies() {
    setup_test_engine
    
    # Mock missing dependencies
    local old_path="$PATH"
    export PATH="/nonexistent"
    
    # Should fail with missing dependencies
    assert_command_fails "should fail with missing dependencies" validate_dependencies
    
    # Restore PATH and test success
    export PATH="$old_path"
    
    # Only run if jq and setfacl are available
    if command -v jq >/dev/null && command -v setfacl >/dev/null; then
        assert_command_succeeds "should succeed with available dependencies" validate_dependencies
    else
        skip_test "jq or setfacl not available"
    fi
}

test_validate_definitions_file() {
    setup_test_engine
    
    # Test with no file specified
    CONFIG[definitions_file]=""
    assert_command_fails "should fail with no file specified" validate_definitions_file
    
    # Test with nonexistent file
    CONFIG[definitions_file]="nonexistent.json"
    assert_command_fails "should fail with nonexistent file" validate_definitions_file
    
    # Test with invalid JSON
    local invalid_file
    invalid_file=$(write_invalid_config "json_syntax")
    CONFIG[definitions_file]="$invalid_file"
    assert_command_fails "should fail with invalid JSON" validate_definitions_file
    
    # Test with missing rules
    local no_rules_file
    no_rules_file=$(write_invalid_config "no_rules")
    CONFIG[definitions_file]="$no_rules_file"
    assert_command_fails "should fail with missing rules" validate_definitions_file
    
    # Test with empty rules array
    local empty_rules_file
    empty_rules_file=$(write_invalid_config "empty_rules")
    CONFIG[definitions_file]="$empty_rules_file"
    assert_command_fails "should fail with empty rules array" validate_definitions_file
    
    # Test with valid file
    local valid_file
    valid_file=$(write_minimal_config)
    CONFIG[definitions_file]="$valid_file"
    assert_command_succeeds "should succeed with valid file" validate_definitions_file
}

test_validate_acl_config() {
    setup_test_engine
    
    # Mock getent for group validation
    create_mock_groups
    
    # Test valid configuration
    assert_command_succeeds "should succeed with valid config" \
        validate_acl_config "developers" "rwx" "/tmp/test"
    
    # Test missing group
    assert_command_fails "should fail with null group" \
        validate_acl_config "null" "rwx" "/tmp/test"
    
    # Test empty group
    assert_command_fails "should fail with empty group" \
        validate_acl_config "" "rwx" "/tmp/test"
    
    # Test missing permissions
    assert_command_fails "should fail with null permissions" \
        validate_acl_config "developers" "null" "/tmp/test"
    
    # Test empty permissions
    assert_command_fails "should fail with empty permissions" \
        validate_acl_config "developers" "" "/tmp/test"
    
    # Test invalid group name
    assert_command_fails "should fail with invalid group name" \
        validate_acl_config "123invalid" "rwx" "/tmp/test"
    
    # Test nonexistent group (should warn, not fail)
    assert_command_succeeds "should warn but not fail with nonexistent group" \
        validate_acl_config "nonexistent" "rwx" "/tmp/test"
}

test_configure_mask() {
    setup_test_engine
    
    # Initialize config
    declare -A CONFIG=(
        [mask_setting]=""
        [mask_explicit]=""
        [no_recalc_mask]=""
    )
    
    # Test auto mode
    assert_command_succeeds "should succeed with auto" configure_mask "auto"
    assert_equals "auto" "${CONFIG[mask_setting]}" "mask_setting should be auto"
    assert_equals "false" "${CONFIG[no_recalc_mask]}" "no_recalc_mask should be false"
    
    # Test skip mode
    assert_command_succeeds "should succeed with skip" configure_mask "skip"
    assert_equals "skip" "${CONFIG[mask_setting]}" "mask_setting should be skip"
    assert_equals "true" "${CONFIG[no_recalc_mask]}" "no_recalc_mask should be true"
    
    # Test explicit mask
    assert_command_succeeds "should succeed with explicit mask" configure_mask "r-x"
    assert_equals "explicit" "${CONFIG[mask_setting]}" "mask_setting should be explicit"
    assert_equals "r-x" "${CONFIG[mask_explicit]}" "mask_explicit should be r-x"
    assert_equals "true" "${CONFIG[no_recalc_mask]}" "no_recalc_mask should be true"
    
    # Test empty value
    assert_command_fails "should fail with empty value" configure_mask ""
    
    # Test invalid mask
    assert_command_fails "should fail with invalid mask" configure_mask "invalid"
}

# Pattern matching tests
test_match_glob() {
    setup_test_engine
    
    # Test basic glob patterns
    assert_command_succeeds "*.txt should match test.txt" \
        match_glob "test.txt" "test.txt" "true" "true" "*.txt"
    
    assert_command_fails "*.txt should not match test.py" \
        match_glob "test.py" "test.py" "true" "true" "*.txt"
    
    # Test case sensitivity
    assert_command_succeeds "case insensitive should match different case" \
        match_glob "TEST.TXT" "TEST.TXT" "false" "true" "*.txt"
    
    assert_command_fails "case sensitive should not match different case" \
        match_glob "TEST.TXT" "TEST.TXT" "true" "true" "*.txt"
    
    # Test match_base functionality
    assert_command_succeeds "match_base should match basename" \
        match_glob "path/to/test.txt" "test.txt" "true" "true" "*.txt"
    
    # Test multiple patterns
    assert_command_succeeds "should match first pattern" \
        match_glob "test.txt" "test.txt" "true" "true" "*.txt" "*.py"
    
    assert_command_succeeds "should match second pattern" \
        match_glob "test.py" "test.py" "true" "true" "*.txt" "*.py"
}

test_match_regex() {
    setup_test_engine
    
    # Test basic regex patterns
    assert_command_succeeds "txt$ should match test.txt" \
        match_regex "test.txt" "test.txt" "true" "true" "txt$"
    
    assert_command_fails "txt$ should not match test.py" \
        match_regex "test.py" "test.py" "true" "true" "txt$"
    
    # Test case sensitivity
    assert_command_succeeds "case insensitive should match different case" \
        match_regex "TEST.TXT" "TEST.TXT" "false" "true" "txt$"
    
    assert_command_fails "case sensitive should not match different case" \
        match_regex "TEST.TXT" "TEST.TXT" "true" "true" "txt$"
    
    # Test complex regex
    assert_command_succeeds "complex regex should match" \
        match_regex "config_prod.json" "config_prod.json" "true" "true" "^config_.*\.json$"
}

test_filter_by_patterns() {
    setup_test_engine
    
    # Test include only
    assert_command_succeeds "should match include pattern" \
        filter_by_patterns "test.txt" "test.txt" "glob" "true" "true" "*.txt" "--"
    
    assert_command_fails "should not match when not in include" \
        filter_by_patterns "test.py" "test.py" "glob" "true" "true" "*.txt" "--"
    
    # Test exclude pattern
    assert_command_fails "should not match exclude pattern" \
        filter_by_patterns "test.tmp" "test.tmp" "glob" "true" "true" "*" "--" "*.tmp"
    
    # Test include and exclude together
    assert_command_succeeds "should match include but not exclude" \
        filter_by_patterns "test.txt" "test.txt" "glob" "true" "true" "*.txt" "--" "*.log"
    
    assert_command_fails "should match include but be excluded" \
        filter_by_patterns "test.txt" "test.txt" "glob" "true" "true" "*.txt" "--" "*.txt"
    
    # Test empty include (should match all)
    assert_command_succeeds "empty include should match all" \
        filter_by_patterns "anything" "anything" "glob" "true" "true" "--"
}

# Run all validation tests
run_validation_tests() {
    start_test_suite "Validation Functions"
    
    run_test "is_readable_file" test_is_readable_file
    run_test "is_valid_json" test_is_valid_json
    run_test "is_valid_path" test_is_valid_path
    run_test "is_valid_group" test_is_valid_group
    run_test "is_valid_perms" test_is_valid_perms
    run_test "is_valid_mask" test_is_valid_mask
    run_test "validate_dependencies" test_validate_dependencies
    run_test "validate_definitions_file" test_validate_definitions_file
    run_test "validate_acl_config" test_validate_acl_config
    run_test "configure_mask" test_configure_mask
    run_test "match_glob" test_match_glob
    run_test "match_regex" test_match_regex
    run_test "filter_by_patterns" test_filter_by_patterns
    
    end_test_suite "Validation Functions"
}

# Run tests if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_validation_tests
fi
