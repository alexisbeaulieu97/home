#!/bin/bash
#
# test_framework.sh - Simple bash unit testing framework for engine.sh
#

# Prevent multiple sourcing
if [[ "${TEST_FRAMEWORK_LOADED:-}" == "true" ]]; then
    return 0
fi
readonly TEST_FRAMEWORK_LOADED="true"

set -euo pipefail

# Test framework globals
declare -i TESTS_RUN=0
declare -i TESTS_PASSED=0
declare -i TESTS_FAILED=0
declare -a FAILED_TESTS=()

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly RESET='\033[0m'

# Test framework functions
log_test_info() {
    printf "%b[TEST]%b %s\n" "$CYAN" "$RESET" "$*" >&2
}

log_test_pass() {
    printf "%b[PASS]%b %s\n" "$GREEN" "$RESET" "$*" >&2
}

log_test_fail() {
    printf "%b[FAIL]%b %s\n" "$RED" "$RESET" "$*" >&2
}

log_test_skip() {
    printf "%b[SKIP]%b %s\n" "$YELLOW" "$RESET" "$*" >&2
}

# Assert functions
assert_equals() {
    local expected="$1" actual="$2" message="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        return 0
    else
        echo "Expected: '$expected', Got: '$actual'. $message" >&2
        return 1
    fi
}

assert_not_equals() {
    local expected="$1" actual="$2" message="${3:-}"
    if [[ "$expected" != "$actual" ]]; then
        return 0
    else
        echo "Expected different values, but both were: '$expected'. $message" >&2
        return 1
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" message="${3:-}"
    if [[ "$haystack" == *"$needle"* ]]; then
        return 0
    else
        echo "Expected '$haystack' to contain '$needle'. $message" >&2
        return 1
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" message="${3:-}"
    if [[ "$haystack" != *"$needle"* ]]; then
        return 0
    else
        echo "Expected '$haystack' to NOT contain '$needle'. $message" >&2
        return 1
    fi
}

assert_file_exists() {
    local file="$1" message="${2:-}"
    if [[ -f "$file" ]]; then
        return 0
    else
        echo "Expected file '$file' to exist. $message" >&2
        return 1
    fi
}

assert_file_not_exists() {
    local file="$1" message="${2:-}"
    if [[ ! -f "$file" ]]; then
        return 0
    else
        echo "Expected file '$file' to NOT exist. $message" >&2
        return 1
    fi
}

assert_exit_code() {
    local expected_code="$1" message="${2:-}"
    shift 2
    local actual_code=0
    "$@" &>/dev/null || actual_code=$?
    assert_equals "$expected_code" "$actual_code" "$message"
}

assert_command_succeeds() {
    local message="${1:-}"
    shift
    if "$@" &>/dev/null; then
        return 0
    else
        echo "Expected command to succeed: $*. $message" >&2
        return 1
    fi
}

assert_command_fails() {
    local message="${1:-}"
    shift
    if ! "$@" &>/dev/null; then
        return 0
    else
        echo "Expected command to fail: $*. $message" >&2
        return 1
    fi
}

# Test execution framework
run_test() {
    local test_name="$1"
    shift
    local test_function="$1"
    shift
    
    TESTS_RUN=$((TESTS_RUN + 1))
    log_test_info "Running: $test_name"
    
    # Create isolated environment for each test
    local test_dir
    test_dir=$(mktemp -d "/tmp/acl_test_${test_name}.XXXXXX")
    local original_dir="$PWD"
    
    # Setup test environment
    cd "$test_dir"
    
    # Run the test
    if "$test_function" "$@" 2>/dev/null; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        log_test_pass "$test_name"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_TESTS+=("$test_name")
        log_test_fail "$test_name"
        # Show test output on failure
        echo "  Test output:" >&2
        "$test_function" "$@" 2>&1 | sed 's/^/    /' >&2
    fi
    
    # Cleanup
    cd "$original_dir"
    rm -rf "$test_dir"
}

# Test suite management
start_test_suite() {
    local suite_name="$1"
    printf "%b=== Starting Test Suite: %s ===%b\n" "$BOLD" "$suite_name" "$RESET" >&2
    TESTS_RUN=0
    TESTS_PASSED=0
    TESTS_FAILED=0
    FAILED_TESTS=()
}

end_test_suite() {
    local suite_name="$1"
    printf "\n%b=== Test Suite Results: %s ===%b\n" "$BOLD" "$suite_name" "$RESET" >&2
    printf "Tests run: %d\n" "$TESTS_RUN" >&2
    printf "%bPassed: %d%b\n" "$GREEN" "$TESTS_PASSED" "$RESET" >&2
    
    if [[ $TESTS_FAILED -gt 0 ]]; then
        printf "%bFailed: %d%b\n" "$RED" "$TESTS_FAILED" "$RESET" >&2
        printf "Failed tests:\n" >&2
        for failed_test in "${FAILED_TESTS[@]}"; do
            printf "  - %s\n" "$failed_test" >&2
        done
        return 1
    else
        printf "%bAll tests passed!%b\n" "$GREEN" "$RESET" >&2
        return 0
    fi
}

# Test utilities
create_temp_json() {
    local content="$1"
    local filename="${2:-test.json}"
    echo "$content" > "$filename"
    echo "$PWD/$filename"
}

create_temp_dir() {
    local dirname="${1:-testdir}"
    mkdir -p "$dirname"
    echo "$PWD/$dirname"
}

create_temp_file() {
    local filename="$1"
    local content="${2:-}"
    touch "$filename"
    [[ -n "$content" ]] && echo "$content" > "$filename"
    echo "$PWD/$filename"
}

# Mock setfacl for testing
mock_setfacl() {
    local mock_script="setfacl"
    cat > "$mock_script" << 'EOF'
#!/bin/bash
# Mock setfacl for testing
echo "MOCK: setfacl $*" >&2
exit 0
EOF
    chmod +x "$mock_script"
    export PATH="$PWD:$PATH"
}

# Skip test utility
skip_test() {
    local reason="$1"
    log_test_skip "$reason"
    return 0
}
