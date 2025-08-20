#!/bin/bash
#
# apply_acls.sh - Apply POSIX ACLs to filesystem paths based on JSON definitions
#
# This script provides a robust way to apply Access Control Lists (ACLs) to filesystem
# paths using configuration defined in a JSON file. It supports recursive application,
# mask handling, group validation, and comprehensive error reporting.
#
# Author: Alexis Beaulieu
# Dependencies: bash >=4.0, jq, setfacl
# License: MIT
#

set -euo pipefail
set -o errtrace

# =============================================================================
# CONSTANTS AND CONFIGURATION
# =============================================================================

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_ERROR=1
readonly EXIT_INVALID_ARGS=2
readonly EXIT_MISSING_DEPS=3
readonly EXIT_FILE_ERROR=4

# Configuration structure - replaces scattered globals
declare -A CONFIG=(
    [definitions_file]=""
    [color_mode]="auto"
    [mask_setting]="auto"
    [mask_explicit]=""
    [no_recalc_mask]="false"
    [dry_run]="false"
    [enable_colors]="true"
)

# Runtime state
declare -a target_paths=()
declare -A json_cache=()
declare -A color_codes=()

# Required dependencies
readonly -a REQUIRED_COMMANDS=("jq" "setfacl")

# =============================================================================
# ERROR HANDLING FRAMEWORK
# =============================================================================

# Central error trap - improved logging
on_unexpected_error() {
    local -r exit_code="$?" line_no="${BASH_LINENO[0]:-unknown}" command="${BASH_COMMAND}"
    # Ignore expected return codes from our functions
    if [[ $exit_code -eq $RETURN_SKIPPED ]]; then
        return 0
    fi
    log_error "Unexpected failure on line $line_no (exit code $exit_code)"
    log_error "Failed command: $command"
    exit 1
}
trap on_unexpected_error ERR

# Enhanced error reporting with context
fail() {
    local -r exit_code="$1"; shift
    log_error "$*"
    exit "$exit_code"
}

# Standard return codes for internal functions
readonly RETURN_SUCCESS=0
readonly RETURN_SKIPPED=5
readonly RETURN_FAILED=1

# =============================================================================
# LOGGING SYSTEM - Simplified and more maintainable
# =============================================================================

# Initialize color system based on configuration
init_colors() {
    case "${CONFIG[color_mode]}" in
        always) CONFIG[enable_colors]="true" ;;
        never)  CONFIG[enable_colors]="false" ;;
        auto|*)
            if [[ -n "${NO_COLOR:-}" ]] || ! { [[ -t 1 ]] || [[ -t 2 ]]; }; then
                CONFIG[enable_colors]="false"
            else
                CONFIG[enable_colors]="true"
            fi ;;
    esac

    if [[ "${CONFIG[enable_colors]}" == "true" ]]; then
        color_codes[red]='\033[0;31m'
        color_codes[green]='\033[0;32m'
        color_codes[yellow]='\033[1;33m'
        color_codes[blue]='\033[0;34m'
        color_codes[cyan]='\033[0;36m'
        color_codes[bold]='\033[1m'
        color_codes[reset]='\033[0m'
    else
        for key in red green yellow blue cyan bold reset; do
            color_codes[$key]=''
        done
    fi
}

# Unified logging function
_log() {
    local -r color="$1" stream="$2" prefix="$3"; shift 3
    # Use color codes if available, otherwise plain text
    local color_start="${color_codes[$color]:-}"
    local color_end="${color_codes[reset]:-}"
    printf "%b%s%s%b\n" "$color_start" "$prefix" "$*" "$color_end" >&"$stream"
}

# Logging functions
log_info()       { _log blue 2 "INFO: " "$*"; }
log_success()    { _log green 2 "SUCCESS: " "$*"; }
log_error()      { _log red 2 "ERROR: " "$*"; }
log_warning()    { _log yellow 2 "WARNING: " "$*"; }
log_processing() { _log cyan 2 "PROCESSING: " "$*"; }
log_bold()       { _log bold 2 "" "$*"; }

# =============================================================================
# VALIDATION FRAMEWORK - Centralized and extensible
# =============================================================================

# Dependency validation
validate_dependencies() {
    local -a missing=()
    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        local install_hint=""
        case "$(uname -s)" in
            Linux) install_hint=" Try: apt-get install acl jq (Ubuntu/Debian) or yum install acl jq (RHEL/CentOS)" ;;
            Darwin) install_hint=" Try: brew install jq" ;;
        esac
        fail "$EXIT_MISSING_DEPS" "Missing required commands: ${missing[*]}.${install_hint}"
    fi
}

# Input validation predicates - enhanced
is_readable_file() { [[ -f "$1" && -r "$1" ]]; }
is_valid_json()    { jq empty "$1" 2>/dev/null; }
is_valid_path()    { [[ -n "$1" && "$1" != *$'\0'* ]]; }
is_valid_group()   { [[ "$1" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_-]*$ ]]; }
is_valid_perms()   { [[ "$1" =~ ^[rwxX-]{1,4}$ ]]; }
is_valid_mask()    { [[ "$1" =~ ^[rwx-]{1,3}$ ]]; }

# Enhanced file validation with better error context
validate_definitions_file() {
    local -r file="${CONFIG[definitions_file]}"

    [[ -n "$file" ]] || fail "$EXIT_INVALID_ARGS" "Definitions file is required. Use: $SCRIPT_NAME -f <file>"
    is_readable_file "$file" || fail "$EXIT_FILE_ERROR" "Cannot read definitions file '$file'. Check file exists and has read permissions."
    is_valid_json "$file" || fail "$EXIT_FILE_ERROR" "Invalid JSON syntax in '$file'. Use 'jq .' to validate JSON format."

    local path_count
    path_count=$(jq 'keys | length' "$file" 2>/dev/null) || 
        fail "$EXIT_FILE_ERROR" "Cannot parse JSON structure from '$file'"
    [[ "$path_count" -gt 0 ]] || fail "$EXIT_FILE_ERROR" "Definitions file '$file' contains no path definitions"
}

# =============================================================================
# JSON OPERATIONS - Improved caching and error handling
# =============================================================================

# Enhanced JSON data retrieval with better caching and error handling
get_json_data() {
    local -r file="$1" cache_key="$2" jq_filter="$3"
    shift 3
    local -ar jq_args=("$@")

    # Return cached result if available
    if [[ -n "${json_cache[$cache_key]:-}" ]]; then
        echo "${json_cache[$cache_key]}"
        return
    fi

    # Validate file before query
    [[ -r "$file" ]] || fail "$EXIT_FILE_ERROR" "Cannot read JSON file '$file'"

    # Execute query and cache result
    local result
    if result=$(jq -r "$jq_filter" "${jq_args[@]}" "$file" 2>&1); then
        json_cache[$cache_key]="$result"
        echo "$result"
    else
        fail "$EXIT_ERROR" "JSON query failed for '$file' with filter '$jq_filter': $result"
    fi
}

# Optimized path operations
get_all_paths() {
    get_json_data "${CONFIG[definitions_file]}" "all_paths" 'keys[]'
}

path_exists_in_definitions() {
    local -r path="$1"
    jq -e --arg path "$path" 'has($path)' "${CONFIG[definitions_file]}" &>/dev/null
}

get_path_config() {
    local -r path="$1"
    local -r cache_key="${path}_config"
    local -r filter='.[$path] | [.group // null, .permissions // null, (.recursive // false)] | .[]'
    get_json_data "${CONFIG[definitions_file]}" "$cache_key" "$filter" --arg path "$path"
}

# =============================================================================
# PATH OPERATIONS - Simplified and more efficient
# =============================================================================

# Sort paths by depth (shallow to deep) for proper ACL inheritance
sort_paths_by_depth() {
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        # Count directory separators to determine depth
        local depth
        depth=$(tr -cd '/' <<< "$path" | wc -c)
        printf '%d\t%s\n' "$depth" "$path"
    done | LC_ALL=C sort -n | cut -f2-
}

# Batch path validation for better performance
validate_target_paths() {
    local -a missing=()

    for path in "${target_paths[@]}"; do
        is_valid_path "$path" || fail "$EXIT_ERROR" "Invalid path format: '$path'"
        path_exists_in_definitions "$path" || missing+=("$path")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        fail "$EXIT_ERROR" "These paths not found in definitions file: ${missing[*]}"
    fi
}

# =============================================================================
# ACL CONFIGURATION - Enhanced validation and configuration
# =============================================================================

# Comprehensive ACL validation
validate_acl_config() {
    local -r group="$1" perms="$2" path="$3"

    [[ "$group" != "null" && -n "$group" ]] || fail "$EXIT_ERROR" "Missing 'group' field in definitions for path '$path'. Add \"group\": \"groupname\"."
    [[ "$perms" != "null" && -n "$perms" ]] || fail "$EXIT_ERROR" "Missing 'permissions' field in definitions for path '$path'. Add \"permissions\": \"rwx\"."

    is_valid_group "$group" || fail "$EXIT_ERROR" "Invalid group name '$group' for path '$path'. Use alphanumeric characters, underscores, and hyphens only."
    is_valid_perms "$perms" || log_warning "Unusual permissions format '$perms' for '$path' (expected combinations of r, w, x, X, -)."

    # Group existence check (if getent available)
    if command -v getent >/dev/null 2>&1; then
        getent group "$group" >/dev/null 2>&1 || 
            log_warning "Group '$group' does not exist on system (ensure it exists before running)"
    fi
}

# Simplified mask configuration
configure_mask() {
    local -r value="$1"

    case "$value" in
        auto)
            CONFIG[mask_setting]="auto"
            CONFIG[no_recalc_mask]="false" ;;
        skip)
            CONFIG[mask_setting]="skip"
            CONFIG[no_recalc_mask]="true" ;;
        "")
            fail "$EXIT_INVALID_ARGS" "Mask option requires a value" ;;
        *)
            if is_valid_mask "$value"; then
                CONFIG[mask_setting]="explicit"
                CONFIG[mask_explicit]="$value"
                CONFIG[no_recalc_mask]="true"
            else
                fail "$EXIT_INVALID_ARGS" "Invalid mask value '$value' (expected: auto, skip, or rwx format like r-x)"
            fi ;;
    esac
}

# =============================================================================
# SETFACL OPERATIONS - Streamlined execution
# =============================================================================

# Build setfacl arguments array
build_setfacl_args() {
    local -r acl_entry="$1" recursive="$2"
    local -a args=()

    [[ "$recursive" == "true" ]] && args+=("-R")
    [[ "${CONFIG[no_recalc_mask]}" == "true" ]] && args+=("-n")
    
    args+=("-m" "$acl_entry")
    [[ "${CONFIG[mask_setting]}" == "explicit" ]] && args+=("-m" "m::${CONFIG[mask_explicit]}")

    printf '%s\n' "${args[@]}"
}

# Execute setfacl with comprehensive error handling
execute_setfacl() {
    local -r path="$1" acl_entry="$2" recursive="$3"
    shift 3
    local -ar args=("$@")

    local suffix=""
    [[ "$recursive" == "true" ]] && suffix=" (recursively)"
    log_info "Applying ACL: $acl_entry$suffix"

    if [[ "${CONFIG[dry_run]}" == "true" ]]; then
        log_info "Dry-run: setfacl ${args[*]} -- \"$path\""
        log_success "Simulated success"
        return "$RETURN_SUCCESS"
    fi

    local output
    if output=$(setfacl "${args[@]}" -- "$path" 2>&1); then
        log_success "Applied successfully"
        return "$RETURN_SUCCESS"
    else
        log_error "Failed to apply ACL to '$path': $output"
        return "$RETURN_FAILED"
    fi
}

# =============================================================================
# CORE APPLICATION LOGIC - Improved modularity
# =============================================================================

# Get and validate ACL configuration for a path
get_acl_config() {
    local -r path="$1"
    local -a config
    
    mapfile -t config < <(get_path_config "$path")
    local -r group="${config[0]}" perms="${config[1]}" recursive="${config[2]}"
    
    validate_acl_config "$group" "$perms" "$path"
    printf '%s\n%s\n%s\n' "$group" "$perms" "$recursive"
}


# Apply ACL to a single path with comprehensive error handling
apply_acl_to_path() {
    local -r path="$1"

    log_processing "$path"
    is_valid_path "$path" || fail "$EXIT_ERROR" "Invalid path format: '$path'"

    # Get and validate configuration
    local -a config
    mapfile -t config < <(get_acl_config "$path")
    local -r group="${config[0]}" perms="${config[1]}" recursive="${config[2]}"

    # Validate path existence and determine recursion
    if [[ ! -e "$path" ]]; then
        log_info "Path does not exist - skipping"
        return "$RETURN_SKIPPED"
    fi
    
    local should_recurse="$recursive"
    # Adjust recursion for non-directories
    if [[ "$recursive" == "true" && ! -d "$path" ]]; then
        log_warning "Not a directory - applying non-recursively"
        should_recurse="false"
    fi

    # Build and execute setfacl command
    local -r acl_entry="g:${group}:${perms}"
    local -a setfacl_args
    mapfile -t setfacl_args < <(build_setfacl_args "$acl_entry" "$should_recurse")

    execute_setfacl "$path" "$acl_entry" "$should_recurse" "${setfacl_args[@]}"
}

# Main ACL application orchestrator
apply_acls() {
    local -ar paths=("$@")
    local success=0 failed=0 skipped=0

    while IFS= read -r path; do
        [[ -n "$path" ]] || continue

        set +e
        apply_acl_to_path "$path"
        local result=$?
        set -e
        
        case $result in
            "$RETURN_SUCCESS") ((success++)) || true ;;
            "$RETURN_SKIPPED") ((skipped++)) || true ;;
            "$RETURN_SUCCESS") ((success++)) ;;
            "$RETURN_SKIPPED") ((skipped++)) ;;
            *) ((failed++)) ;;
        esac
        echo
    done < <(printf '%s\n' "${paths[@]}" | sort_paths_by_depth)

    # Summary report
    log_bold "Summary:"
    log_bold "- Applied: $success"
    log_bold "- Skipped: $skipped" 
    log_bold "- Failed: $failed"

    if [[ $failed -eq 0 ]]; then
        return 0
    else
        return 1
    fi
}

# =============================================================================
# ARGUMENT PARSING - Modular and extensible
# =============================================================================

# Option value extraction helper with better validation
get_option_value() {
    local -r option="$1" next_arg="${2:-}"
    if [[ "$option" == *=* ]]; then
        local value="${option#*=}"
        [[ -n "$value" ]] || fail "$EXIT_INVALID_ARGS" "Option '${option%%=*}' requires a non-empty value"
        echo "$value"
    else
        [[ -n "$next_arg" && "$next_arg" != -* ]] || fail "$EXIT_INVALID_ARGS" "Option '$option' requires an argument"
        echo "$next_arg"
    fi
}

# Color mode validation and setting
set_color_mode() {
    local -r value="$1"
    case "$value" in
        auto|always|never) CONFIG[color_mode]="$value" ;;
        *) fail "$EXIT_INVALID_ARGS" "Invalid color mode '$value' (use: auto/always/never)" ;;
    esac
}

# Definitions file validation and setting
set_definitions_file() {
    local -r file="$1"
    [[ -n "${CONFIG[definitions_file]}" ]] && fail "$EXIT_INVALID_ARGS" "Definitions file can only be specified once"
    [[ -n "$file" ]] || fail "$EXIT_INVALID_ARGS" "Definitions file path cannot be empty"
    CONFIG[definitions_file]="$file"
}

# Main argument parser - simplified and more maintainable
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--file)
                [[ -n "${2:-}" ]] || fail "$EXIT_INVALID_ARGS" "Option '$1' requires an argument"
                set_definitions_file "$2"
                shift 2 ;;
            --color|--color=*)
                local value
                value="$(get_option_value "$1" "${2:-}")"
                set_color_mode "$value"
                if [[ "$1" == *=* ]]; then
                    shift
                else
                    shift 2
                fi ;;
            --mask|--mask=*)
                local value
                value="$(get_option_value "$1" "${2:-}")"
                configure_mask "$value"
                if [[ "$1" == *=* ]]; then
                    shift
                else
                    shift 2
                fi ;;
            --no-color)
                CONFIG[color_mode]="never"
                shift ;;
            --dry-run)
                CONFIG[dry_run]="true"
                shift ;;
            -h|--help)
                show_usage
                exit "$EXIT_SUCCESS" ;;
            --)
                shift; break ;;
            -*)
                fail "$EXIT_INVALID_ARGS" "Unknown option: '$1'. See --help for usage." ;;
            *)
                break ;;
        esac
    done

    target_paths=("$@")
}

# =============================================================================
# USAGE DOCUMENTATION - Enhanced clarity
# =============================================================================

show_usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} -f FILE [OPTIONS] [PATH...]

Apply POSIX ACLs to filesystem paths based on JSON definitions.
If no PATHs are provided, ACLs are applied to all paths defined in the file.

Required:
  -f, --file FILE     JSON file with ACL definitions

Options:
  --color MODE        Output colors: auto|always|never (default: auto)
  --no-color          Disable colors (equivalent to --color never)
  --mask VALUE        Mask handling: auto|skip|<rwx> (default: auto)
  --dry-run           Simulate without making changes
  -h, --help          Show this help message

Examples:
  # Apply ACLs for all paths in definitions file
  ${SCRIPT_NAME} -f acl_definitions.json

  # Apply ACLs only for specific paths
  ${SCRIPT_NAME} -f acl_definitions.json /path/one /path/two

  # Simulate applying with a specific mask
  ${SCRIPT_NAME} -f acl_definitions.json --mask r-x --dry-run /path/one

JSON Schema:
  {
    "/path/to/directory": {
      "group": "some_group",
      "permissions": "rwx",
      "recursive": true|false  // optional, default false
    }
  }

Notes:
  - Paths are processed from shallowest to deepest to ensure correct ACL inheritance
  - Skips paths that do not exist on filesystem (with informational message)
  - Validates group existence if 'getent' command is available on the system
  - Respects the NO_COLOR environment variable for color output control
  - Operations continue on individual failures, final exit code reflects overall success

Exit Codes:
  0 Success (may include skipped paths)
  1 General Error
  2 Invalid Arguments  
  3 Missing Dependencies
  4 File Error
  5 (Internal) Skipped Path
EOF
}

# =============================================================================
# MAIN ORCHESTRATION - Simplified and clear
# =============================================================================

# Initialize runtime environment
initialize() {
    validate_dependencies
    init_colors
    validate_definitions_file
}

# Determine paths to process
determine_target_paths() {
    if [[ ${#target_paths[@]} -gt 0 ]]; then
        log_info "Targets specified:"
        printf "  %s\n" "${target_paths[@]}" >&2  # Send logging to stderr
        validate_target_paths
        printf '%s\n' "${target_paths[@]}"  # Send actual output to stdout
    else
        log_info "No specific targets specified, applying to all defined paths."
        get_all_paths
    fi
}

# Main execution function
main() {
    parse_arguments "$@"
    initialize

    log_bold "ACL definitions from: ${CONFIG[definitions_file]}"

    local -a paths_to_process
    mapfile -t paths_to_process < <(determine_target_paths)

    if [[ ${#paths_to_process[@]} -eq 0 ]]; then
        log_warning "No paths to process."
        exit "$EXIT_SUCCESS"
    fi

    apply_acls "${paths_to_process[@]}"
}

# Entry point - only execute if run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi