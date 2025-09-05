#!/bin/bash
#
# test_json_output.sh - Tests for JSON output functionality
#

# Source the test framework and fixtures
source "$(dirname "${BASH_SOURCE[0]}")/test_framework.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test_fixtures.sh"

# Source the engine.sh script to test its functions
ENGINE_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/engine.sh"

test_json_output_basic() {
    local config_file
    config_file=$(write_minimal_config)
    
    # Test JSON output produces valid JSON
    local output
    output=$("$ENGINE_SCRIPT" -f "$config_file" --dry-run --output-format json 2>/dev/null)
    
    # Check that it's valid JSON
    echo "$output" | jq . >/dev/null 2>&1
    assert_command_succeeds "should produce valid JSON" \
        echo "$output" | jq . >/dev/null
    
    # Check required fields exist
    assert_command_succeeds "should have run field" \
        echo "$output" | jq -e '.run' >/dev/null
    
    assert_command_succeeds "should have config field" \
        echo "$output" | jq -e '.config' >/dev/null
        
    assert_command_succeeds "should have metrics field" \
        echo "$output" | jq -e '.metrics' >/dev/null
}

test_json_output_text_suppression() {
    local config_file
    config_file=$(write_minimal_config)
    
    # Test that text output is suppressed in JSON mode
    local stderr_output
    stderr_output=$("$ENGINE_SCRIPT" -f "$config_file" --dry-run --output-format json 2>&1 >/dev/null)
    
    # Should only contain ERROR messages, no INFO/SUCCESS/etc
    if [[ -n "$stderr_output" ]]; then
        # If there's stderr output, it should only be ERROR messages
        local non_error_lines
        non_error_lines=$(echo "$stderr_output" | grep -v "^ERROR:" || true)
        assert_equals "" "$non_error_lines" "should suppress non-error output in JSON mode"
    fi
}

test_json_output_error_handling() {
    # Test with invalid output format
    assert_command_fails "should reject invalid output format" \
        "$ENGINE_SCRIPT" -f /dev/null --output-format invalid
    
    # Test with missing file
    assert_command_fails "should handle missing file in JSON mode" \
        "$ENGINE_SCRIPT" -f /nonexistent.json --output-format json
}

test_json_output_warnings() {
    # Create config with non-existent group to trigger warnings
    local config_file="/tmp/test_warnings.json"
    cat > "$config_file" << 'EOF'
{
    "rules": [
        {
            "roots": "/tmp",
            "acl": [
                "g:nonexistentgroup123:rwx"
            ]
        }
    ]
}
EOF
    
    local output
    output=$("$ENGINE_SCRIPT" -f "$config_file" --dry-run --output-format json 2>/dev/null)
    
    # Check that warnings array is present and contains the expected warning
    local warnings_count
    warnings_count=$(echo "$output" | jq -r '.warnings | length')
    
    assert_true "should capture warnings in JSON output" \
        "[[ $warnings_count -gt 0 ]]"
}

# Run all JSON output tests
run_json_output_tests() {
    start_test_suite "JSON Output"
    
    run_test "json_output_basic" test_json_output_basic
    run_test "json_output_text_suppression" test_json_output_text_suppression
    run_test "json_output_error_handling" test_json_output_error_handling
    run_test "json_output_warnings" test_json_output_warnings
    
    end_test_suite "JSON Output"
}

# Run tests if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_json_output_tests
fi