#!/bin/bash
#
# run_tests.sh - Test runner for ACL engine unit tests
#

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# Test configuration
readonly TEST_TIMEOUT=60  # seconds
readonly PARALLEL_TESTS=false  # Set to true to run tests in parallel

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly RESET='\033[0m'

# Test results tracking
declare -i TOTAL_SUITES=0
declare -i PASSED_SUITES=0
declare -i FAILED_SUITES=0
declare -a FAILED_SUITE_NAMES=()

# Logging functions
log_info() {
    printf "%b[INFO]%b %s\n" "$CYAN" "$RESET" "$*" >&2
}

log_success() {
    printf "%b[SUCCESS]%b %s\n" "$GREEN" "$RESET" "$*" >&2
}

log_error() {
    printf "%b[ERROR]%b %s\n" "$RED" "$RESET" "$*" >&2
}

log_warning() {
    printf "%b[WARNING]%b %s\n" "$YELLOW" "$RESET" "$*" >&2
}

log_header() {
    printf "\n%b%s%b\n" "$BOLD" "$*" "$RESET" >&2
}

# Usage information
show_usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] [TEST_SUITE...]

Run unit tests for the ACL engine script.

Options:
  -h, --help        Show this help message
  -v, --verbose     Show verbose output from tests
  -q, --quiet       Suppress test output (show only results)
  -p, --parallel    Run test suites in parallel
  -t, --timeout N   Set timeout for each test suite (default: $TEST_TIMEOUT seconds)
  --list            List available test suites and exit
  --check-deps      Check test dependencies and exit

Test Suites:
  validation        Input validation and predicates
  json              JSON parsing and data retrieval
  acl               ACL building and pattern matching
  integration       Integration tests with dry-run
  all               Run all test suites (default)

Examples:
  $(basename "$0")                    # Run all tests
  $(basename "$0") validation json    # Run specific test suites
  $(basename "$0") --verbose all      # Run all tests with verbose output
  $(basename "$0") --parallel all     # Run all tests in parallel

Exit Codes:
  0   All tests passed
  1   Some tests failed
  2   Invalid arguments or missing dependencies
  3   Test execution error
EOF
}

# List available test suites
list_test_suites() {
    log_header "Available Test Suites:"
    echo "  validation    - Input validation and predicates (test_validation.sh)"
    echo "  json          - JSON parsing and data retrieval (test_json_ops.sh)"
    echo "  acl           - ACL building and pattern matching (test_acl_logic.sh)"
    echo "  integration   - Integration tests with dry-run (test_integration.sh)"
    echo "  all           - All test suites"
}

# Check test dependencies
check_dependencies() {
    log_info "Checking test dependencies..."
    
    local -a missing=()
    local -a commands=("bash" "jq" "timeout" "mktemp" "find")
    
    for cmd in "${commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    
    # Check bash version (need 4.0+ for associative arrays)
    if [[ ${BASH_VERSION%%.*} -lt 4 ]]; then
        missing+=("bash-4.0+")
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing[*]}"
        log_info "Required for testing:"
        log_info "  bash 4.0+   - Associative arrays support"
        log_info "  jq          - JSON processing"
        log_info "  timeout     - Test timeouts"
        log_info "  mktemp      - Temporary directories"
        log_info "  find        - File enumeration"
        return 1
    fi
    
    log_success "All test dependencies are available"
    
    # Check optional dependencies for actual ACL operations
    log_info "Checking optional dependencies for ACL operations..."
    local -a optional=("setfacl" "getfacl" "getent")
    local -a missing_optional=()
    
    for cmd in "${optional[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_optional+=("$cmd")
        fi
    done
    
    if [[ ${#missing_optional[@]} -gt 0 ]]; then
        log_warning "Missing optional dependencies: ${missing_optional[*]}"
        log_info "These are not required for unit tests but are needed for actual ACL operations"
    else
        log_success "All optional dependencies are available"
    fi
    
    return 0
}

# Run a single test suite
run_test_suite() {
    local suite_name="$1"
    local test_script="$2"
    local verbose="${3:-false}"
    local timeout="${4:-$TEST_TIMEOUT}"
    
    TOTAL_SUITES=$((TOTAL_SUITES + 1))
    
    if [[ ! -f "$test_script" ]]; then
        log_error "Test script not found: $test_script"
        FAILED_SUITES=$((FAILED_SUITES + 1))
        FAILED_SUITE_NAMES+=("$suite_name (script not found)")
        return 1
    fi
    
    if [[ ! -x "$test_script" ]]; then
        log_warning "Making test script executable: $test_script"
        chmod +x "$test_script"
    fi
    
    local output_file
    output_file=$(mktemp "/tmp/test_${suite_name}_output.XXXXXX")
    
    local start_time end_time duration
    start_time=$(date +%s.%N)
    
    local exit_code=0
    if timeout "$timeout" "$test_script" >"$output_file" 2>&1; then
        exit_code=0
    else
        exit_code=$?
    fi
    
    end_time=$(date +%s.%N)
    duration=$(awk "BEGIN {printf \"%.2f\", $end_time - $start_time}")
    
    if [[ $exit_code -eq 0 ]]; then
        PASSED_SUITES=$((PASSED_SUITES + 1))
        log_success "Test suite '$suite_name' passed (${duration}s)"
        
        if [[ "$verbose" == "true" ]]; then
            cat "$output_file"
        fi
    else
        FAILED_SUITES=$((FAILED_SUITES + 1))
        FAILED_SUITE_NAMES+=("$suite_name")
        
        if [[ $exit_code -eq 124 ]]; then
            log_error "Test suite '$suite_name' timed out after ${timeout}s"
        else
            log_error "Test suite '$suite_name' failed with exit code $exit_code (${duration}s)"
        fi
        
        # Always show output for failed tests
        echo "--- Test Output ---" >&2
        cat "$output_file" >&2
        echo "--- End Output ---" >&2
    fi
    
    rm -f "$output_file"
    return $exit_code
}

# Get test script path for a suite name
get_test_script() {
    local suite_name="$1"
    case "$suite_name" in
        validation) echo "$SCRIPT_DIR/test_validation.sh" ;;
        json) echo "$SCRIPT_DIR/test_json_ops.sh" ;;
        acl) echo "$SCRIPT_DIR/test_acl_logic.sh" ;;
        integration) echo "$SCRIPT_DIR/test_integration.sh" ;;
        *) echo "" ;;
    esac
}

# Run test suites sequentially
run_tests_sequential() {
    local verbose="$1"
    local timeout="$2"
    shift 2
    local -a suites=("$@")
    
    for suite in "${suites[@]}"; do
        local test_script
        test_script=$(get_test_script "$suite")
        
        if [[ -z "$test_script" ]]; then
            log_error "Unknown test suite: $suite"
            TOTAL_SUITES=$((TOTAL_SUITES + 1))
            FAILED_SUITES=$((FAILED_SUITES + 1))
            FAILED_SUITE_NAMES+=("$suite (unknown)")
            continue
        fi
        
        log_header "Running test suite: $suite"
        run_test_suite "$suite" "$test_script" "$verbose" "$timeout"
    done
}

# Run test suites in parallel
run_tests_parallel() {
    local verbose="$1"
    local timeout="$2"
    shift 2
    local -a suites=("$@")
    
    log_header "Running test suites in parallel..."
    
    local -a pids=()
    local -A suite_pids=()
    
    # Start all test suites in background
    for suite in "${suites[@]}"; do
        local test_script
        test_script=$(get_test_script "$suite")
        
        if [[ -z "$test_script" ]]; then
            log_error "Unknown test suite: $suite"
            TOTAL_SUITES=$((TOTAL_SUITES + 1))
            FAILED_SUITES=$((FAILED_SUITES + 1))
            FAILED_SUITE_NAMES+=("$suite (unknown)")
            continue
        fi
        
        log_info "Starting test suite: $suite"
        run_test_suite "$suite" "$test_script" "$verbose" "$timeout" &
        local pid=$!
        pids+=("$pid")
        suite_pids[$pid]="$suite"
    done
    
    # Wait for all test suites to complete
    for pid in "${pids[@]}"; do
        local suite_name="${suite_pids[$pid]}"
        if wait "$pid"; then
            log_info "Test suite '$suite_name' completed successfully"
        else
            log_warning "Test suite '$suite_name' completed with errors"
        fi
    done
}

# Show test summary
show_summary() {
    log_header "Test Summary"
    
    printf "Total test suites: %d\n" "$TOTAL_SUITES" >&2
    printf "%bPassed: %d%b\n" "$GREEN" "$PASSED_SUITES" "$RESET" >&2
    printf "%bFailed: %d%b\n" "$RED" "$FAILED_SUITES" "$RESET" >&2
    
    if [[ $FAILED_SUITES -gt 0 ]]; then
        printf "\n%bFailed test suites:%b\n" "$RED" "$RESET" >&2
        for failed_suite in "${FAILED_SUITE_NAMES[@]}"; do
            printf "  - %s\n" "$failed_suite" >&2
        done
        return 1
    else
        printf "\n%bAll test suites passed!%b\n" "$GREEN" "$RESET" >&2
        return 0
    fi
}

# Main function
main() {
    local verbose="false"
    local quiet="false"
    local parallel="$PARALLEL_TESTS"
    local timeout="$TEST_TIMEOUT"
    local -a test_suites=()
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_usage
                exit 0
                ;;
            -v|--verbose)
                verbose="true"
                shift
                ;;
            -q|--quiet)
                quiet="true"
                shift
                ;;
            -p|--parallel)
                parallel="true"
                shift
                ;;
            -t|--timeout)
                if [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]]; then
                    timeout="$2"
                    shift 2
                else
                    log_error "Timeout must be a positive integer"
                    exit 2
                fi
                ;;
            --list)
                list_test_suites
                exit 0
                ;;
            --check-deps)
                check_dependencies
                exit $?
                ;;
            all)
                test_suites=("validation" "json" "acl" "integration")
                shift
                ;;
            validation|json|acl|integration)
                test_suites+=("$1")
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                show_usage >&2
                exit 2
                ;;
            *)
                log_error "Unknown test suite: $1"
                show_usage >&2
                exit 2
                ;;
        esac
    done
    
    # Default to all tests if none specified
    if [[ ${#test_suites[@]} -eq 0 ]]; then
        test_suites=("validation" "json" "acl" "integration")
    fi
    
    # Check dependencies first
    if ! check_dependencies >/dev/null 2>&1; then
        log_error "Dependency check failed. Use --check-deps for details."
        exit 2
    fi
    
    # Suppress output in quiet mode
    if [[ "$quiet" == "true" ]]; then
        exec 2>/dev/null
    fi
    
    # Show configuration
    log_header "ACL Engine Test Runner"
    log_info "Test suites: ${test_suites[*]}"
    log_info "Parallel execution: $parallel"
    log_info "Timeout per suite: ${timeout}s"
    log_info "Verbose output: $verbose"
    
    # Run tests
    local start_time end_time total_duration
    start_time=$(date +%s.%N)
    
    if [[ "$parallel" == "true" ]]; then
        run_tests_parallel "$verbose" "$timeout" "${test_suites[@]}"
    else
        run_tests_sequential "$verbose" "$timeout" "${test_suites[@]}"
    fi
    
    end_time=$(date +%s.%N)
    total_duration=$(awk "BEGIN {printf \"%.2f\", $end_time - $start_time}")
    
    # Show summary
    if [[ "$quiet" != "true" ]]; then
        exec 2>&1  # Restore stderr for summary
    fi
    
    log_info "Total execution time: ${total_duration}s"
    
    if show_summary; then
        exit 0
    else
        exit 1
    fi
}

# Make test scripts executable
chmod +x "$SCRIPT_DIR"/test_*.sh 2>/dev/null || true

# Run main function
main "$@"
