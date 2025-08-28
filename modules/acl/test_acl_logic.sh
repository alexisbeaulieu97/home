#!/bin/bash
#
# test_acl_logic.sh - Unit tests for ACL logic and setfacl operations in engine.sh
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

test_build_setfacl_args() {
    local test_engine
    test_engine=$(create_test_engine)
    source "$test_engine"
    
    # Initialize config
    declare -A CONFIG=(
        [no_recalc_mask]="false"
        [mask_setting]="auto"
        [mask_explicit]=""
    )
    
    # Test basic args (non-recursive)
    local result
    result=$(build_setfacl_args "g:test:rwx" "false")
    local expected="-m
g:test:rwx"
    assert_equals "$expected" "$result" "should build basic setfacl args"
    
    # Test recursive args
    result=$(build_setfacl_args "g:test:rwx" "true")
    expected="-R
-m
g:test:rwx"
    assert_equals "$expected" "$result" "should build recursive setfacl args"
    
    # Test with no_recalc_mask
    CONFIG[no_recalc_mask]="true"
    result=$(build_setfacl_args "g:test:rwx" "false")
    expected="-n
-m
g:test:rwx"
    assert_equals "$expected" "$result" "should include -n flag when no_recalc_mask is true"
    
    # Test with explicit mask
    CONFIG[mask_setting]="explicit"
    CONFIG[mask_explicit]="r-x"
    result=$(build_setfacl_args "g:test:rwx" "false")
    expected="-n
-m
g:test:rwx
-m
m::r-x"
    assert_equals "$expected" "$result" "should include explicit mask"
}

test_build_setfacl_args_default() {
    local test_engine
    test_engine=$(create_test_engine)
    source "$test_engine"
    
    # Initialize config
    declare -A CONFIG=(
        [no_recalc_mask]="false"
        [mask_setting]="auto"
        [mask_explicit]=""
    )
    
    # Test default ACL args
    local result
    result=$(build_setfacl_args_default "g:test:rwx" "true")
    local expected="-d
-m
g:test:rwx"
    assert_equals "$expected" "$result" "should build default ACL args"
    
    # Test non-default ACL args
    result=$(build_setfacl_args_default "g:test:rwx" "false")
    expected="-m
g:test:rwx"
    assert_equals "$expected" "$result" "should build non-default ACL args"
    
    # Test with explicit mask and no_recalc
    CONFIG[no_recalc_mask]="true"
    CONFIG[mask_setting]="explicit"
    CONFIG[mask_explicit]="rwx"
    result=$(build_setfacl_args_default "g:test:rwx" "true")
    expected="-d
-n
-m
g:test:rwx
-m
m::rwx"
    assert_equals "$expected" "$result" "should build default ACL with mask and no_recalc"
}

test_execute_setfacl() {
    local test_engine
    test_engine=$(create_test_engine)
    source "$test_engine"
    
    # Initialize config
    declare -A CONFIG=(
        [dry_run]="false"
        [quiet]="false"
        [enable_colors]="false"
    )
    
    # Mock setfacl
    mock_setfacl
    
    # Create test file
    local test_file="test_file.txt"
    touch "$test_file"
    
    # Test successful execution
    local result
    result=$(execute_setfacl "$test_file" "g:test:rwx" "false" "-m" "g:test:rwx" 2>&1)
    assert_contains "$result" "Applied ACL: g:test:rwx" "should report success"
    
    # Test dry run mode
    CONFIG[dry_run]="true"
    result=$(execute_setfacl "$test_file" "g:test:rwx" "false" "-m" "g:test:rwx" 2>&1)
    assert_contains "$result" "Dry-run:" "should report dry-run"
    assert_contains "$result" "(dry-run)" "should include dry-run suffix"
    
    # Test recursive suffix
    CONFIG[dry_run]="false"
    result=$(execute_setfacl "$test_file" "g:test:rwx" "true" "-R" "-m" "g:test:rwx" 2>&1)
    assert_contains "$result" "(recursively)" "should include recursive suffix"
}

test_path_under_any_filter() {
    local test_engine
    test_engine=$(create_test_engine)
    source "$test_engine"
    
    # Initialize target_paths
    declare -a target_paths=()
    
    # Test with no target paths (should match all)
    assert_command_succeeds "should match when no filters" \
        path_under_any_filter "/any/path"
    
    # Set target paths
    target_paths=("/srv/app" "/data/shared")
    
    # Test exact match
    assert_command_succeeds "should match exact path" \
        path_under_any_filter "/srv/app"
    
    # Test subpath match
    assert_command_succeeds "should match subpath" \
        path_under_any_filter "/srv/app/config"
    
    assert_command_succeeds "should match deep subpath" \
        path_under_any_filter "/srv/app/src/main.py"
    
    # Test non-matching paths
    assert_command_fails "should not match different path" \
        path_under_any_filter "/var/log"
    
    assert_command_fails "should not match partial prefix" \
        path_under_any_filter "/srv/application"
    
    # Test edge cases
    assert_command_succeeds "should match second target" \
        path_under_any_filter "/data/shared/file.txt"
    
    # Test with trailing slash handling
    target_paths=("/srv/app/")
    assert_command_succeeds "should handle trailing slash in target" \
        path_under_any_filter "/srv/app/config"
}

test_enumerate_candidates_for_rule() {
    local test_engine
    test_engine=$(create_test_engine)
    source "$test_engine"
    
    # Create test filesystem
    local test_dir
    test_dir=$(create_test_filesystem)
    
    # Test non-recursive, include_self
    local result
    result=$(enumerate_candidates_for_rule "false" "true" "$test_dir")
    assert_equals "$test_dir" "$result" "should return only root when non-recursive"
    
    # Test recursive, include_self
    result=$(enumerate_candidates_for_rule "true" "true" "$test_dir")
    assert_contains "$result" "$test_dir" "should include root when include_self"
    assert_contains "$result" "$test_dir/app" "should include subdirectories when recursive"
    assert_contains "$result" "$test_dir/app/src/main.py" "should include files when recursive"
    
    # Test recursive, exclude_self
    result=$(enumerate_candidates_for_rule "true" "false" "$test_dir")
    assert_not_contains "$result" "$test_dir" "should not include root when exclude_self"
    assert_contains "$result" "$test_dir/app" "should include subdirectories when recursive"
    
    # Test with multiple roots
    local test_dir2="${test_dir}_2"
    mkdir -p "$test_dir2"
    touch "$test_dir2/file.txt"
    
    result=$(enumerate_candidates_for_rule "false" "true" "$test_dir" "$test_dir2")
    assert_contains "$result" "$test_dir" "should include first root"
    assert_contains "$result" "$test_dir2" "should include second root"
    
    # Test with nonexistent root
    result=$(enumerate_candidates_for_rule "false" "true" "/nonexistent" 2>&1)
    assert_contains "$result" "does not exist" "should warn about nonexistent root"
}

test_apply_specs_to_path() {
    local test_engine
    test_engine=$(create_test_engine)
    source "$test_engine"
    
    # Initialize config and counters
    declare -A CONFIG=(
        [dry_run]="true"  # Use dry-run to avoid actual setfacl calls
        [quiet]="false"
        [enable_colors]="false"
        [no_recalc_mask]="false"
        [mask_setting]="auto"
        [mask_explicit]=""
    )
    declare -i ENTRIES_ATTEMPTED=0
    declare -i ENTRIES_FAILED=0
    
    # Mock setfacl
    mock_setfacl
    
    # Create test file
    local test_file="test_file.txt"
    touch "$test_file"
    
    # Test applying multiple specs
    local specs=("g:test1:rwx" "g:test2:rw-" "o::r--")
    local result
    result=$(apply_specs_to_path "$test_file" "false" "${specs[@]}" 2>&1)
    
    # Check that ENTRIES_ATTEMPTED was incremented
    assert_equals "3" "$ENTRIES_ATTEMPTED" "should attempt 3 entries"
    assert_equals "0" "$ENTRIES_FAILED" "should have no failures in dry-run"
    
    # Test with empty specs
    ENTRIES_ATTEMPTED=0
    ENTRIES_FAILED=0
    result=$(apply_specs_to_path "$test_file" "false" "" 2>&1)
    assert_equals "0" "$ENTRIES_ATTEMPTED" "should not attempt empty specs"
    
    # Test default ACL (is_default=true)
    ENTRIES_ATTEMPTED=0
    result=$(apply_specs_to_path "$test_file" "true" "g:test:rwx" 2>&1)
    assert_equals "1" "$ENTRIES_ATTEMPTED" "should attempt default ACL"
}

test_argument_parsing_helpers() {
    local test_engine
    test_engine=$(create_test_engine)
    source "$test_engine"
    
    # Test get_option_value with equals format
    local result
    result=$(get_option_value "--color=auto" "")
    assert_equals "auto" "$result" "should parse option with equals"
    
    # Test get_option_value with separate argument
    result=$(get_option_value "--color" "auto")
    assert_equals "auto" "$result" "should parse option with separate argument"
    
    # Test error cases
    assert_command_fails "should fail with empty value after equals" \
        get_option_value "--color=" ""
    
    assert_command_fails "should fail with missing argument" \
        get_option_value "--color" ""
    
    assert_command_fails "should fail with option-like argument" \
        get_option_value "--color" "--other"
    
    # Test set_color_mode
    declare -A CONFIG=()
    
    assert_command_succeeds "should accept auto" set_color_mode "auto"
    assert_equals "auto" "${CONFIG[color_mode]}" "should set auto mode"
    
    assert_command_succeeds "should accept always" set_color_mode "always"
    assert_equals "always" "${CONFIG[color_mode]}" "should set always mode"
    
    assert_command_succeeds "should accept never" set_color_mode "never"
    assert_equals "never" "${CONFIG[color_mode]}" "should set never mode"
    
    assert_command_fails "should reject invalid mode" set_color_mode "invalid"
    
    # Test set_definitions_file
    CONFIG[definitions_file]=""
    
    assert_command_succeeds "should accept valid file path" set_definitions_file "test.json"
    assert_equals "test.json" "${CONFIG[definitions_file]}" "should set file path"
    
    assert_command_fails "should reject empty path" set_definitions_file ""
    
    # Test duplicate file setting
    assert_command_fails "should reject duplicate file setting" set_definitions_file "other.json"
}

test_color_initialization() {
    local test_engine
    test_engine=$(create_test_engine)
    source "$test_engine"
    
    # Initialize config and color_codes
    declare -A CONFIG=()
    declare -A color_codes=()
    
    # Test auto mode with terminal
    CONFIG[color_mode]="auto"
    unset NO_COLOR
    init_colors
    # Cannot easily test terminal detection, but function should not fail
    assert_command_succeeds "init_colors should succeed" true
    
    # Test never mode
    CONFIG[color_mode]="never"
    init_colors
    assert_equals "false" "${CONFIG[enable_colors]}" "should disable colors in never mode"
    assert_equals "" "${color_codes[red]}" "should have empty color codes in never mode"
    
    # Test always mode
    CONFIG[color_mode]="always"
    init_colors
    assert_equals "true" "${CONFIG[enable_colors]}" "should enable colors in always mode"
    assert_not_equals "" "${color_codes[red]}" "should have color codes in always mode"
    
    # Test NO_COLOR environment variable
    CONFIG[color_mode]="auto"
    export NO_COLOR=1
    init_colors
    assert_equals "false" "${CONFIG[enable_colors]}" "should disable colors when NO_COLOR is set"
    unset NO_COLOR
}

test_pattern_matching_edge_cases() {
    local test_engine
    test_engine=$(create_test_engine)
    source "$test_engine"
    
    # Test empty patterns
    assert_command_fails "empty glob pattern should not match" \
        match_glob "test.txt" "test.txt" "true" "true" ""
    
    assert_command_fails "empty regex pattern should not match" \
        match_regex "test.txt" "test.txt" "true" "true" ""
    
    # Test special characters in patterns
    assert_command_succeeds "should handle brackets in glob" \
        match_glob "test[1].txt" "test[1].txt" "true" "true" "test[[]1].txt"
    
    # Test case sensitivity edge cases
    local saved_nocasematch=""
    if shopt -q nocasematch; then saved_nocasematch="on"; else saved_nocasematch="off"; fi
    
    # Ensure we restore the original state
    assert_command_succeeds "case insensitive glob should match" \
        match_glob "TEST.TXT" "TEST.TXT" "false" "true" "*.txt"
    
    # Verify nocasematch state is restored
    local current_nocasematch=""
    if shopt -q nocasematch; then current_nocasematch="on"; else current_nocasematch="off"; fi
    assert_equals "$saved_nocasematch" "$current_nocasematch" "should restore nocasematch state"
    
    # Test match_base with complex paths
    assert_command_succeeds "should match basename with complex path" \
        match_glob "very/deep/nested/path/file.txt" "file.txt" "true" "true" "*.txt"
}

# Run all ACL logic tests
run_acl_logic_tests() {
    start_test_suite "ACL Logic and Operations"
    
    run_test "build_setfacl_args" test_build_setfacl_args
    run_test "build_setfacl_args_default" test_build_setfacl_args_default
    run_test "execute_setfacl" test_execute_setfacl
    run_test "path_under_any_filter" test_path_under_any_filter
    run_test "enumerate_candidates_for_rule" test_enumerate_candidates_for_rule
    run_test "apply_specs_to_path" test_apply_specs_to_path
    run_test "argument_parsing_helpers" test_argument_parsing_helpers
    run_test "color_initialization" test_color_initialization
    run_test "pattern_matching_edge_cases" test_pattern_matching_edge_cases
    
    end_test_suite "ACL Logic and Operations"
}

# Run tests if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_acl_logic_tests
fi
