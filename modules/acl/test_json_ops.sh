#!/bin/bash
#
# test_json_ops.sh - Unit tests for JSON operations in engine.sh
#

# Source the test framework and fixtures
source "$(dirname "${BASH_SOURCE[0]}")/test_framework.sh"
source "$(dirname "${BASH_SOURCE[0]}")/test_fixtures.sh"

# Source the engine.sh script to test its functions
ENGINE_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/engine.sh"

# Create a test version that doesn't execute main
create_test_engine() {
    local test_engine="test_engine.sh"
    if [[ ! -f "$test_engine" ]]; then
        if [[ ! -f "$ENGINE_SCRIPT" ]]; then
            echo "Error: ENGINE_SCRIPT not found at $ENGINE_SCRIPT" >&2
            return 1
        fi
        cp "$ENGINE_SCRIPT" "$test_engine"
        # Comment out the main execution
        sed -i 's/^if \[\[ "${BASH_SOURCE\[0\]}" == "${0}" \]\]; then/# &/' "$test_engine"
        sed -i 's/^    main "\$@"/# &/' "$test_engine"
        sed -i 's/^fi$/# &/' "$test_engine"
    fi
    echo "$PWD/$test_engine"
}

# Test get_json_data function
test_get_json_data() {
    local test_engine
    test_engine=$(create_test_engine)
    source "$test_engine"
    
    # Initialize cache
    declare -A json_cache=()
    
    # Create test JSON file
    local config_file
    config_file=$(write_complete_config)
    
    # Test basic data retrieval
    local result
    result=$(get_json_data "$config_file" "version" '.version // "1.0"')
    assert_equals "1.0" "$result" "should retrieve version"
    
    # Test caching - second call should use cache
    result=$(get_json_data "$config_file" "version" '.version // "1.0"')
    assert_equals "1.0" "$result" "should use cached result"
    
    # Test with jq arguments
    result=$(get_json_data "$config_file" "first_rule_id" '.rules[0].id' --raw-output)
    assert_equals "test-rule-1" "$result" "should retrieve first rule id"
    
    # Test with nonexistent file
    assert_command_fails "should fail with nonexistent file" \
        get_json_data "nonexistent.json" "test" '.test'
}

test_get_apply_order() {
    local test_engine
    test_engine=$(create_test_engine)
    source "$test_engine"
    
    # Test with explicit apply_order
    local config_file
    config_file=$(write_complete_config)
    CONFIG[definitions_file]="$config_file"
    
    local result
    result=$(get_apply_order)
    assert_equals "shallow_to_deep" "$result" "should return shallow_to_deep"
    
    # Test with deep_to_shallow
    config_file=$(write_deep_to_shallow_config)
    CONFIG[definitions_file]="$config_file"
    
    result=$(get_apply_order)
    assert_equals "deep_to_shallow" "$result" "should return deep_to_shallow"
    
    # Test with default (missing apply_order)
    config_file=$(write_minimal_config)
    CONFIG[definitions_file]="$config_file"
    
    result=$(get_apply_order)
    assert_equals "shallow_to_deep" "$result" "should default to shallow_to_deep"
}

test_get_rules_count() {
    local test_engine
    test_engine=$(create_test_engine)
    source "$test_engine"
    
    # Test with complete config (2 rules)
    local config_file
    config_file=$(write_complete_config)
    CONFIG[definitions_file]="$config_file"
    
    local result
    result=$(get_rules_count)
    assert_equals "2" "$result" "should return 2 for complete config"
    
    # Test with minimal config (1 rule)
    config_file=$(write_minimal_config)
    CONFIG[definitions_file]="$config_file"
    
    result=$(get_rules_count)
    assert_equals "1" "$result" "should return 1 for minimal config"
}

test_get_rule_roots() {
    local test_engine
    test_engine=$(create_test_engine)
    source "$test_engine"
    
    local config_file
    config_file=$(write_complete_config)
    CONFIG[definitions_file]="$config_file"
    
    # Test first rule (multiple roots)
    local result
    result=$(get_rule_roots 0)
    local expected=$'/tmp/test1\n/tmp/test2'
    assert_equals "$expected" "$result" "should return multiple roots for first rule"
    
    # Test second rule (single root)
    result=$(get_rule_roots 1)
    assert_equals "/tmp/test3" "$result" "should return single root for second rule"
    
    # Test with minimal config (single root as string)
    config_file=$(write_minimal_config)
    CONFIG[definitions_file]="$config_file"
    
    result=$(get_rule_roots 0)
    assert_equals "/tmp/test" "$result" "should return single root from minimal config"
}

test_get_rule_params_tsv() {
    local test_engine
    test_engine=$(create_test_engine)
    source "$test_engine"
    
    local config_file
    config_file=$(write_complete_config)
    CONFIG[definitions_file]="$config_file"
    
    # Test first rule parameters
    local result
    result=$(get_rule_params_tsv 0)
    local expected="true	true	file,directory	glob	true	true"
    assert_equals "$expected" "$result" "should return correct TSV for first rule"
    
    # Test second rule parameters (different defaults)
    result=$(get_rule_params_tsv 1)
    expected="false	true	file,directory	glob	true	true"
    assert_equals "$expected" "$result" "should return correct TSV for second rule"
}

test_get_rule_entry_specs() {
    local test_engine
    test_engine=$(create_test_engine)
    source "$test_engine"
    
    local config_file
    config_file=$(write_complete_config)
    CONFIG[definitions_file]="$config_file"
    
    # Test file specs for first rule
    local result
    result=$(get_rule_entry_specs 0 "files")
    local expected=$'g:developers:rw-\no::r--'
    assert_equals "$expected" "$result" "should return file specs for first rule"
    
    # Test directory specs for first rule
    result=$(get_rule_entry_specs 0 "directories")
    expected=$'g:developers:rwx\no::r-x'
    assert_equals "$expected" "$result" "should return directory specs for first rule"
    
    # Test second rule (string format)
    result=$(get_rule_entry_specs 1 "files")
    expected=$'g:testgroup:rwx\nu:testuser:rw-\no::r--'
    assert_equals "$expected" "$result" "should return specs for second rule"
}

test_get_rule_default_specs() {
    local test_engine
    test_engine=$(create_test_engine)
    source "$test_engine"
    
    local config_file
    config_file=$(write_complete_config)
    CONFIG[definitions_file]="$config_file"
    
    # Test default specs for first rule
    local result
    result=$(get_rule_default_specs 0)
    local expected=$'g:developers:rwx\nm::rwx'
    assert_equals "$expected" "$result" "should return default specs for first rule"
    
    # Test second rule (no default specs)
    result=$(get_rule_default_specs 1)
    assert_equals "" "$result" "should return empty for rule without default specs"
}

test_get_rule_patterns() {
    local test_engine
    test_engine=$(create_test_engine)
    source "$test_engine"
    
    local config_file
    config_file=$(write_complete_config)
    CONFIG[definitions_file]="$config_file"
    
    # Test include patterns
    local result
    result=$(get_rule_patterns 0 "include")
    assert_equals "**/*" "$result" "should return include patterns"
    
    # Test exclude patterns
    result=$(get_rule_patterns 0 "exclude")
    local expected=$'*.tmp\n.git/**'
    assert_equals "$expected" "$result" "should return exclude patterns"
    
    # Test rule without patterns
    result=$(get_rule_patterns 1 "include")
    assert_equals "" "$result" "should return empty for rule without include patterns"
    
    result=$(get_rule_patterns 1 "exclude")
    assert_equals "" "$result" "should return empty for rule without exclude patterns"
}

test_path_exists_in_definitions() {
    local test_engine
    test_engine=$(create_test_engine)
    source "$test_engine"
    
    # This function seems to be for legacy schema - test with simple object
    local legacy_config='{"\\"/tmp/test\\": {"group": "test", "permissions": "rwx"}}'
    local config_file="legacy.json"
    echo "$legacy_config" > "$config_file"
    CONFIG[definitions_file]="$config_file"
    
    # Test existing path
    assert_command_succeeds "should find existing path" \
        path_exists_in_definitions "/tmp/test"
    
    # Test non-existing path
    assert_command_fails "should not find non-existing path" \
        path_exists_in_definitions "/tmp/nonexistent"
}

test_sort_paths_by_depth() {
    local test_engine
    test_engine=$(create_test_engine)
    source "$test_engine"
    
    # Test path sorting
    local input="/deep/nested/path
/shallow
/medium/path
/"
    
    local expected="/ 
/shallow
/medium/path
/deep/nested/path"
    
    local result
    result=$(echo "$input" | sort_paths_by_depth)
    assert_equals "$expected" "$result" "should sort paths by depth"
    
    # Test empty input
    result=$(echo "" | sort_paths_by_depth)
    assert_equals "" "$result" "should handle empty input"
    
    # Test single path
    result=$(echo "/single/path" | sort_paths_by_depth)
    assert_equals "/single/path" "$result" "should handle single path"
}

test_json_error_handling() {
    local test_engine
    test_engine=$(create_test_engine)
    source "$test_engine"
    
    # Initialize cache
    declare -A json_cache=()
    
    # Test with invalid JSON file
    local invalid_file
    invalid_file=$(write_invalid_config "json_syntax")
    
    assert_command_fails "should fail with invalid JSON" \
        get_json_data "$invalid_file" "test" '.test'
    
    # Test with invalid jq filter
    local valid_file
    valid_file=$(write_minimal_config)
    
    assert_command_fails "should fail with invalid jq filter" \
        get_json_data "$valid_file" "test" '.invalid[[[syntax'
}

test_acl_spec_parsing() {
    local test_engine
    test_engine=$(create_test_engine)
    source "$test_engine"
    
    # Create config with mixed ACL formats
    local mixed_config='{
  "rules": [
    {
      "roots": "/tmp/test",
      "acl": [
        {"kind": "user", "name": "alice", "mode": "rwx"},
        "g:developers:rw-",
        {"kind": "other", "mode": "r--"},
        "m::rwx"
      ]
    }
  ]
}'
    
    local config_file="mixed.json"
    echo "$mixed_config" > "$config_file"
    CONFIG[definitions_file]="$config_file"
    
    # Test parsing mixed ACL formats
    local result
    result=$(get_rule_entry_specs 0 "files")
    local expected=$'u:alice:rwx\ng:developers:rw-\no::r--\nm::rwx'
    assert_equals "$expected" "$result" "should parse mixed ACL formats correctly"
}

# Run all JSON operation tests
run_json_tests() {
    start_test_suite "JSON Operations"
    
    run_test "get_json_data" test_get_json_data
    run_test "get_apply_order" test_get_apply_order
    run_test "get_rules_count" test_get_rules_count
    run_test "get_rule_roots" test_get_rule_roots
    run_test "get_rule_params_tsv" test_get_rule_params_tsv
    run_test "get_rule_entry_specs" test_get_rule_entry_specs
    run_test "get_rule_default_specs" test_get_rule_default_specs
    run_test "get_rule_patterns" test_get_rule_patterns
    run_test "path_exists_in_definitions" test_path_exists_in_definitions
    run_test "sort_paths_by_depth" test_sort_paths_by_depth
    run_test "json_error_handling" test_json_error_handling
    run_test "acl_spec_parsing" test_acl_spec_parsing
    
    end_test_suite "JSON Operations"
}

# Run tests if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_json_tests
fi
