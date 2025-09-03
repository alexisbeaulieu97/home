#!/bin/bash
#
# engine.sh - Apply POSIX ACLs to filesystem paths based on JSON definitions
# (Relocated from ACL/apply_acls.sh for repository restructuring)
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
    [quiet]="false"
    [enable_colors]="true"
    [chunk_size]="64"
)

# Runtime state
declare -a target_paths=()
declare -A json_cache=()
declare -A color_codes=()

# Performance optimization: cache parsed rule data
declare -A rule_cache=()

# Performance optimization: cache path existence and other frequently accessed data  
declare -A path_cache=()

# Performance optimization: cache group existence checks
declare -A group_cache=()

# Global counters for entry-level stats
declare -i ENTRIES_ATTEMPTED=0
declare -i ENTRIES_FAILED=0

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

# Logging function that respects quiet mode
_log_unless_quiet() {
    [[ "${CONFIG[quiet]}" == "true" ]] || _log "$@"
}

# Logging functions
log_info()       { _log_unless_quiet blue 2 "INFO: " "$*"; }
log_success()    { _log_unless_quiet green 2 "SUCCESS: " "$*"; }
log_error()      { _log red 2 "ERROR: " "$*"; }
log_warning()    { _log yellow 2 "WARNING: " "$*"; }
log_processing() { _log_unless_quiet cyan 2 "PROCESSING: " "$*"; }
log_bold()       { _log_unless_quiet bold 2 "" "$*"; }

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

    # Validate minimal structure for new schema: object with non-empty rules array
    local schema_ok
    schema_ok=$(jq -e '(type=="object") and (has("rules")) and (.rules|type=="array" and length>0)' "$file" 2>/dev/null) || 
        fail "$EXIT_FILE_ERROR" "Invalid schema in '$file': expected top-level object with non-empty 'rules' array"
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
    if result=$(jq -r "${jq_args[@]}" "$jq_filter" "$file" 2>&1); then
        json_cache[$cache_key]="$result"
        echo "$result"
    else
        fail "$EXIT_ERROR" "JSON query failed for '$file' with filter '$jq_filter': $result"
    fi
}

# Validate that all groups referenced in the configuration exist
validate_configuration_groups() {
    if ! command -v getent >/dev/null 2>&1; then
        log_warning "getent not available - skipping group existence validation"
        return 0
    fi
    
    log_info "Validating group existence..."
    local groups_output
    groups_output=$(jq -r '
        [.rules[].entries | values | 
         (.files[]?, .directories[]?, .default_entries[]? | select(.kind=="group") | .name)] | 
        unique | .[]
    ' "${CONFIG[definitions_file]}" 2>/dev/null) || {
        log_warning "Could not extract groups from configuration for validation"
        return 0
    }
    
    local -a missing_groups=()
    local group
    while IFS= read -r group; do
        [[ -n "$group" ]] || continue
        
        # Check cache first
        if [[ -n "${group_cache[$group]:-}" ]]; then
            if [[ "${group_cache[$group]}" == "missing" ]]; then
                missing_groups+=("$group")
            fi
        else
            # Check and cache result
            if ! getent group "$group" >/dev/null 2>&1; then
                group_cache[$group]="missing"
                missing_groups+=("$group")
            else
                group_cache[$group]="exists"
            fi
        fi
    done <<< "$groups_output"
    
    if [[ ${#missing_groups[@]} -gt 0 ]]; then
        log_warning "The following groups do not exist on the system:"
        printf "  %s\n" "${missing_groups[@]}" >&2
        log_warning "ACL application may fail. Create these groups or update the configuration."
    else
        log_info "All referenced groups exist on the system"
    fi
}

# =============================================================================
# RULES ACCESSORS (new schema) - Performance optimized
# =============================================================================

# Cache all rule data to minimize jq calls
cache_all_rules() {
    # Single jq pass that emits top-level info and all per-rule data as tagged lines
    local output
    output=$(jq -r '
        def specfmt(x):
            if x.kind=="user" then "u:\(x.name):\(x.mode)"
            elif x.kind=="group" then "g:\(x.name):\(x.mode)"
            elif x.kind=="owner" then "u::\(x.mode)"
            elif x.kind=="owning_group" then "g::\(x.mode)"
            elif x.kind=="other" then "o::\(x.mode)"
            elif x.kind=="mask" then "m::\(x.mode)"
            else empty end;
        "apply_order|\(.apply_order // "shallow_to_deep")",
        "rules_count|\(.rules|length)",
        (.rules | to_entries[] as $e |
            (
                "rule|\($e.key)|params|\($e.value.recurse // false)|\($e.value.include_self // true)|\(($e.value.match.types // ["file","directory"]) | join(","))|\($e.value.match.pattern_syntax // "glob")|\($e.value.match.match_base // true)|\($e.value.match.case_sensitive // true)|\($e.value.apply_defaults // false)"
            ),
            ($e.value.roots as $r | if ($r|type)=="string" then $r else ($r[]) end | "rule|\($e.key)|root|\(.)"),
            ($e.value.acl as $acl | if ($acl|type)=="array" then ($acl | .[] | specfmt(.) | select(length>0) | "rule|\($e.key)|file_spec|\(.)", "rule|\($e.key)|dir_spec|\(.)") else (($acl.files // []) | .[] | specfmt(.) | select(length>0) | "rule|\($e.key)|file_spec|\(.)", (($acl.directories // []) | .[] | specfmt(.) | select(length>0) | "rule|\($e.key)|dir_spec|\(.)")) end),
            ($e.value.default_acl // [] | .[] | specfmt(.) | select(length>0) | "rule|\($e.key)|def_spec|\(.)"),
            ($e.value.match.include // [] | .[] | "rule|\($e.key)|include|\(.)"),
            ($e.value.match.exclude // [] | .[] | "rule|\($e.key)|exclude|\(.)"),
            ("rule|\($e.key)|acl_type|\($e.value.acl | type)"),
            ("rule|\($e.key)|has_files|\((($e.value.acl.files // [])|length) > 0)"),
            ("rule|\($e.key)|has_dirs|\((($e.value.acl.directories // [])|length) > 0)")
        )
    ' "${CONFIG[definitions_file]}") || fail "$EXIT_ERROR" "Failed to parse definitions file '${CONFIG[definitions_file]}'"

    # Reset cache
    local rules_count="0" apply_order="shallow_to_deep"

    while IFS='|' read -r -a parts; do
        [[ ${#parts[@]} -gt 0 ]] || continue
        case "${parts[0]}" in
            apply_order)
                apply_order="${parts[1]}"
                ;;
            rules_count)
                rules_count="${parts[1]}"
                ;;
            rule)
                local idx="${parts[1]}"
                local kind="${parts[2]}"
                case "$kind" in
                    params)
                        # Store as TSV to preserve existing contract
                        local tsv
                        tsv="${parts[3]}"$'\t'"${parts[4]}"$'\t'"${parts[5]}"$'\t'"${parts[6]}"$'\t'"${parts[7]}"$'\t'"${parts[8]}"$'\t'"${parts[9]}"
                        rule_cache["${idx}_params"]="$tsv"
                        ;;
                    root)
                        if [[ -n "${rule_cache[${idx}_roots]:-}" ]]; then
                            rule_cache["${idx}_roots"]+=$'\n'
                        fi
                        rule_cache["${idx}_roots"]+="${parts[3]}"
                        ;;
                    file_spec)
                        if [[ -n "${rule_cache[${idx}_file_specs]:-}" ]]; then
                            rule_cache["${idx}_file_specs"]+=$'\n'
                        fi
                        rule_cache["${idx}_file_specs"]+="${parts[3]}"
                        ;;
                    dir_spec)
                        if [[ -n "${rule_cache[${idx}_dir_specs]:-}" ]]; then
                            rule_cache["${idx}_dir_specs"]+=$'\n'
                        fi
                        rule_cache["${idx}_dir_specs"]+="${parts[3]}"
                        ;;
                    def_spec)
                        if [[ -n "${rule_cache[${idx}_def_specs]:-}" ]]; then
                            rule_cache["${idx}_def_specs"]+=$'\n'
                        fi
                        rule_cache["${idx}_def_specs"]+="${parts[3]}"
                        ;;
                    include)
                        if [[ -n "${rule_cache[${idx}_includes]:-}" ]]; then
                            rule_cache["${idx}_includes"]+=$'\n'
                        fi
                        rule_cache["${idx}_includes"]+="${parts[3]}"
                        ;;
                    exclude)
                        if [[ -n "${rule_cache[${idx}_excludes]:-}" ]]; then
                            rule_cache["${idx}_excludes"]+=$'\n'
                        fi
                        rule_cache["${idx}_excludes"]+="${parts[3]}"
                        ;;
                    acl_type)
                        rule_cache["${idx}_acl_type"]="${parts[3]}"
                        ;;
                    has_files)
                        rule_cache["${idx}_has_files"]="${parts[3]}"
                        ;;
                    has_dirs)
                        rule_cache["${idx}_has_dirs"]="${parts[3]}"
                        ;;
                esac
                ;;
        esac
    done <<< "$output"

    # Store top-level values
    rule_cache[rules_count]="$rules_count"
    rule_cache[apply_order]="$apply_order"
}

get_apply_order() {
    echo "${rule_cache[apply_order]}"
}

get_rules_count() {
    echo "${rule_cache[rules_count]}"
}

get_rule_roots() {
    local -r idx="$1"
    # Use cached data instead of direct jq call
    local value="${rule_cache[${idx}_roots]:-}"
    if [[ -n "$value" ]]; then
        echo "$value"
    fi
}

get_rule_params_tsv() {
    local -r idx="$1"
    # Use cached data instead of direct jq call
    local value="${rule_cache[${idx}_params]:-}"
    if [[ -n "$value" ]]; then
        echo "$value"
    fi
}

# Returns newline-separated setfacl specs for entries of a given type: files|directories
get_rule_entry_specs() {
    local -r idx="$1" type="$2"
    # Use cached data instead of direct jq call
    local value=""
    if [[ "$type" == "files" ]]; then
        value="${rule_cache[${idx}_file_specs]:-}"
    elif [[ "$type" == "directories" ]]; then
        value="${rule_cache[${idx}_dir_specs]:-}"
    fi
    if [[ -n "$value" ]]; then
        echo "$value"
    fi
}

# Returns newline-separated setfacl specs for default entries (directories only)
get_rule_default_specs() {
    local -r idx="$1"
    # Use cached data instead of direct jq call
    local value="${rule_cache[${idx}_def_specs]:-}"
    if [[ -n "$value" ]]; then
        echo "$value"
    fi
}

# Pattern lists (newline-separated) for include/exclude
get_rule_patterns() {
    local -r idx="$1" kind="$2" # kind: include|exclude
    local value=""
    if [[ "$kind" == "include" ]]; then
        value="${rule_cache[${idx}_includes]:-}"
    elif [[ "$kind" == "exclude" ]]; then
        value="${rule_cache[${idx}_excludes]:-}"
    fi
    # Only echo if value is not empty
    if [[ -n "$value" ]]; then
        echo "$value"
    fi
}

# Optimized path operations
get_all_paths() {
    get_json_data "${CONFIG[definitions_file]}" "all_paths" 'keys[]'
}

path_exists_in_definitions() {
    local -r path="$1"
    local cache_key="path_exists_${path}"
    
    # Return cached result if available
    if [[ -n "${path_cache[$cache_key]:-}" ]]; then
        return "${path_cache[$cache_key]}"
    fi
    
    # Check path existence and cache result
    if jq -e --arg path "$path" 'has($path)' "${CONFIG[definitions_file]}" &>/dev/null; then
        path_cache[$cache_key]=0
        return 0
    else
        path_cache[$cache_key]=1
        return 1
    fi
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

# Sort paths by depth (shallow to deep) for proper ACL inheritance - optimized
sort_paths_by_depth() {
    local reverse="false"
    if [[ "${1:-}" == "--reverse" ]]; then
        reverse="true"; shift
    fi
    local -a paths_with_depth=()
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        # Count directory separators to determine depth using bash parameter expansion
        local path_without_slashes="${path//\//}"
        local depth=$(( ${#path} - ${#path_without_slashes} ))
        paths_with_depth+=("$depth|$path")
    done
    if [[ "$reverse" == "true" ]]; then
        LC_ALL=C printf '%s\n' "${paths_with_depth[@]}" | sort -t'|' -rn | cut -d'|' -f2-
    else
        LC_ALL=C printf '%s\n' "${paths_with_depth[@]}" | sort -t'|' -n | cut -d'|' -f2-
    fi
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

    # Group existence check (if getent available) - with caching
    if command -v getent >/dev/null 2>&1; then
        # Check cache first
        if [[ -n "${group_cache[$group]:-}" ]]; then
            if [[ "${group_cache[$group]}" == "missing" ]]; then
                log_warning "Group '$group' does not exist on system (ensure it exists before running)"
            fi
        else
            # Check and cache result
            if getent group "$group" >/dev/null 2>&1; then
                group_cache[$group]="exists"
            else
                group_cache[$group]="missing"
                log_warning "Group '$group' does not exist on system (ensure it exists before running)"
            fi
        fi
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

# Build setfacl args for a single entry; optionally as default (-d)
build_setfacl_args_default() {
    local -r acl_entry="$1" is_default="$2"
    local -a args=()

    [[ "$is_default" == "true" ]] && args+=("-d")
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

    if [[ "${CONFIG[dry_run]}" == "true" ]]; then
        return "$RETURN_SUCCESS"
    fi

    local output
    if output=$(setfacl "${args[@]}" -- "$path" 2>&1); then
        return "$RETURN_SUCCESS"
    else
        local error_msg="setfacl failed for $path: $output"
        log_error "$error_msg"
        
        # Provide helpful hints for common issues
        if [[ "$output" =~ "Operation not supported" ]]; then
            local fs_source
            fs_source=$(df --output=source "$path" | tail -1)
            # Safely quote the filesystem source for shell usage
            local fs_source_quoted
            fs_source_quoted=$(printf '%q' "$fs_source")
            log_error "HINT: Filesystem may not support ACLs. Try: mount | grep $fs_source_quoted"
        elif [[ "$output" =~ "Invalid argument" ]]; then
            log_error "HINT: Group may not exist. Check with: getent group <groupname>"
        elif [[ "$output" =~ "Operation not permitted" ]]; then
            log_error "HINT: Insufficient permissions. Try running with sudo or check file ownership"
        fi
        
        return "$RETURN_FAILED"
    fi
}

# =============================================================================
# CORE APPLICATION LOGIC - Rule-based engine
# =============================================================================

path_under_any_filter() {
    local -r path="$1"
    if [[ ${#target_paths[@]} -eq 0 ]]; then
        return 0
    fi
    for base in "${target_paths[@]}"; do
        if [[ "$path" == "$base" ]]; then
            return 0
        fi
        # Safe string prefix check without glob interpretation
        local base_no_trailing="${base%/}"
        if (( ${#path} > ${#base_no_trailing} )) \
           && [[ "${path:0:${#base_no_trailing}}" == "$base_no_trailing" ]] \
           && [[ "${path:${#base_no_trailing}:1}" == "/" ]]; then
            return 0
        fi
    done
    return 1
}

match_glob() {
    local -r str="$1" base="$2" cs="$3" mb="$4"; shift 4
    local -a patterns=("$@")
    local saved=0
    if shopt -q nocasematch; then saved=1; fi
    local globstar_saved=0
    if shopt -q globstar; then globstar_saved=1; fi
    
    # Enable globstar for ** patterns and set case sensitivity
    shopt -s globstar
    if [[ "$cs" == "false" ]]; then shopt -s nocasematch; else shopt -u nocasematch; fi
    
    for pat in "${patterns[@]}"; do
        [[ -z "$pat" ]] && continue
        # For patterns starting with **, also try matching without the **/ prefix
        if [[ "$pat" == "**/"* ]]; then
            local simple_pat="${pat#**/}"
            if [[ "$str" == $simple_pat ]] || [[ "$str" == $pat ]]; then
                # Restore settings
                (( saved==1 )) && shopt -s nocasematch || shopt -u nocasematch
                (( globstar_saved==1 )) && shopt -s globstar || shopt -u globstar
                return 0
            fi
            if [[ "$mb" == "true" ]] && ([[ "$base" == $simple_pat ]] || [[ "$base" == $pat ]]); then
                # Restore settings
                (( saved==1 )) && shopt -s nocasematch || shopt -u nocasematch
                (( globstar_saved==1 )) && shopt -s globstar || shopt -u globstar
                return 0
            fi
        else
            if [[ "$str" == $pat ]]; then
                # Restore settings
                (( saved==1 )) && shopt -s nocasematch || shopt -u nocasematch
                (( globstar_saved==1 )) && shopt -s globstar || shopt -u globstar
                return 0
            fi
            if [[ "$mb" == "true" ]] && [[ "$base" == $pat ]]; then
                # Restore settings
                (( saved==1 )) && shopt -s nocasematch || shopt -u nocasematch
                (( globstar_saved==1 )) && shopt -s globstar || shopt -u globstar
                return 0
            fi
        fi
    done
    # Restore settings
    (( saved==1 )) && shopt -s nocasematch || shopt -u nocasematch
    (( globstar_saved==1 )) && shopt -s globstar || shopt -u globstar
    return 1
}

match_regex() {
    local -r str="$1" base="$2" cs="$3" mb="$4"; shift 4
    local -a patterns=("$@")
    if [[ "$cs" == "true" ]]; then
        for pat in "${patterns[@]}"; do
            [[ -z "$pat" ]] && continue
            if [[ "$str" =~ $pat ]]; then
                return 0
            fi
            if [[ "$mb" == "true" ]] && [[ "$base" =~ $pat ]]; then
                return 0
            fi
        done
        return 1
    else
        local flags="-Ei"
        for pat in "${patterns[@]}"; do
            [[ -z "$pat" ]] && continue
            echo "$str" | grep $flags -- "$pat" >/dev/null 2>&1 && return 0
            if [[ "$mb" == "true" ]]; then
                echo "$base" | grep $flags -- "$pat" >/dev/null 2>&1 && return 0
            fi
        done
        return 1
    fi
}

filter_by_patterns() {
    local -r rel="$1" base="$2" syntax="$3" cs="$4" mb="$5"; shift 5
    local -a includes=() excludes=()
    local mode="include"
    for token in "$@"; do
        if [[ "$token" == "--" ]]; then mode="exclude"; continue; fi
        if [[ "$mode" == "include" ]]; then includes+=("$token"); else excludes+=("$token"); fi
    done
    local ok=1
    if [[ ${#includes[@]} -eq 0 ]]; then
        ok=0
    else
        if [[ "$syntax" == "glob" ]]; then
            match_glob "$rel" "$base" "$cs" "$mb" "${includes[@]}" && ok=0
        else
            match_regex "$rel" "$base" "$cs" "$mb" "${includes[@]}" && ok=0
        fi
    fi
    [[ $ok -ne 0 ]] && return 1
    if [[ ${#excludes[@]} -gt 0 ]]; then
        if [[ "$syntax" == "glob" ]]; then
            match_glob "$rel" "$base" "$cs" "$mb" "${excludes[@]}" && return 1
        else
            match_regex "$rel" "$base" "$cs" "$mb" "${excludes[@]}" && return 1
        fi
    fi
    return 0
}

enumerate_candidates_for_rule() {
    local -r recurse="$1" include_self="$2"; shift 2
    local -a roots=("$@")
    for root in "${roots[@]}"; do
        if [[ ! -e "$root" ]]; then
            log_warning "Root '$root' does not exist - skipping"
            continue
        fi
        if [[ "$include_self" == "true" ]]; then
            printf '%s\n' "$root"
        fi
        if [[ "$recurse" == "true" && -d "$root" ]]; then
            find "$root" -mindepth 1 -print
        fi
    done
}

apply_specs_to_path() {
    local -r path="$1" is_default="$2"; shift 2
    local -a specs=("$@")
    [[ ${#specs[@]} -eq 0 ]] && return "$RETURN_SUCCESS"

    # Deduplicate specs while preserving order
    local -A seen=()
    local -a unique_specs=()
    local spec
    for spec in "${specs[@]}"; do
        [[ -z "$spec" ]] && continue
        if [[ -z "${seen[$spec]:-}" ]]; then
            seen[$spec]=1
            unique_specs+=("$spec")
        fi
    done
    [[ ${#unique_specs[@]} -eq 0 ]] && return "$RETURN_SUCCESS"

    # Build shared flags once
    local -a shared_flags=()
    [[ "$is_default" == "true" ]] && shared_flags+=("-d")
    [[ "${CONFIG[no_recalc_mask]}" == "true" ]] && shared_flags+=("-n")
    if [[ "${CONFIG[mask_setting]}" == "explicit" ]]; then
        shared_flags+=("-m" "m::${CONFIG[mask_explicit]}")
    fi

    # Chunk to avoid exceeding system arg limits.
    # The chunk size is configurable via CONFIG[chunk_size]. Default is 64, chosen to stay well below typical ARG_MAX limits.
    local chunk_size="${CONFIG[chunk_size]}"
    local total=${#unique_specs[@]}
    local start=0
    local rc_total=0

    while (( start < total )); do
        local end=$(( start + chunk_size ))
        (( end > total )) && end=$total
        local -a args=("${shared_flags[@]}")
        local i
        for (( i=start; i<end; i++ )); do
            args+=("-m" "${unique_specs[i]}")
        done

        local batch_count=$(( end - start ))
        ENTRIES_ATTEMPTED=$((ENTRIES_ATTEMPTED + batch_count))

        set +e
        execute_setfacl "$path" "batch:$batch_count" "false" "${args[@]}"
        local rc=$?
        set -e
        if [[ $rc -ne 0 ]]; then
            ENTRIES_FAILED=$((ENTRIES_FAILED + batch_count))
            rc_total=1
            # continue to try remaining batches
        fi
        start=$end
    done

    if [[ $rc_total -ne 0 ]]; then
        return "$RETURN_FAILED"
    fi
    return "$RETURN_SUCCESS"
}

apply_rules() {
    local total_applied=0 total_skipped=0 total_failed=0
    local rules_count; rules_count=$(get_rules_count)
    local apply_order; apply_order=$(get_apply_order)

    for ((i=0; i<rules_count; i++)); do
        log_bold "---------- PROCESSING RULE $((i+1)) ------------"
        local tsv recurse include_self types_csv syntax match_base case_sensitive
        local save_IFS="$IFS"; IFS=$'\t'; tsv=$(get_rule_params_tsv "$i"); read -r recurse include_self types_csv syntax match_base case_sensitive <<< "$tsv"; IFS="$save_IFS"
        local -a roots; mapfile -t roots < <(get_rule_roots "$i")
        local -a file_specs dir_specs def_specs
        mapfile -t file_specs < <(get_rule_entry_specs "$i" files)
        mapfile -t dir_specs  < <(get_rule_entry_specs "$i" directories)
        mapfile -t def_specs  < <(get_rule_default_specs "$i")
        local -a includes excludes
        mapfile -t includes < <(get_rule_patterns "$i" include)
        mapfile -t excludes < <(get_rule_patterns "$i" exclude)

        local -a candidates
        mapfile -t candidates < <(enumerate_candidates_for_rule "$recurse" "$include_self" "${roots[@]}")
        if [[ ${#candidates[@]} -eq 0 ]]; then
            continue
        fi
        # sort by depth using optimized bash-native function
        if [[ "$apply_order" == "deep_to_shallow" ]]; then
            mapfile -t candidates < <(printf '%s\n' "${candidates[@]}" | sort_paths_by_depth --reverse)
        else
            mapfile -t candidates < <(printf '%s\n' "${candidates[@]}" | sort_paths_by_depth)
        fi

        local want_files=0 want_dirs=0
        if [[ -z "$types_csv" || "$types_csv" == "," ]]; then
            # Infer from ACL shape when types not provided - use cached data
            local acl_type="${rule_cache[${i}_acl_type]:-}"
            if [[ "$acl_type" == "array" ]]; then
                want_files=1; want_dirs=1
            else
                local has_files="${rule_cache[${i}_has_files]:-false}"
                local has_dirs="${rule_cache[${i}_has_dirs]:-false}"
                [[ "$has_files" == "true" ]] && want_files=1
                [[ "$has_dirs" == "true" ]] && want_dirs=1
                if (( want_files==0 && want_dirs==0 )); then want_files=1; want_dirs=1; fi
            fi
        else
            [[ ",${types_csv}," == *,file,* ]] && want_files=1
            [[ ",${types_csv}," == *,directory,* ]] && want_dirs=1
        fi

        for path in "${candidates[@]}"; do
            path_under_any_filter "$path" || { total_skipped=$((total_skipped+1)); continue; }
            local is_file=0 is_dir=0
            [[ -f "$path" ]] && is_file=1
            [[ -d "$path" ]] && is_dir=1
            if (( is_file==1 && want_files==0 )); then total_skipped=$((total_skipped+1)); continue; fi
            if (( is_dir==1 && want_dirs==0 )); then total_skipped=$((total_skipped+1)); continue; fi

            local base rel root_for_rel=""
            base="$(basename -- "$path")"
            for r in "${roots[@]}"; do
                if [[ "$path" == "$r" || "$path" == $r/* ]]; then root_for_rel="$r"; break; fi
            done
            if [[ -n "$root_for_rel" ]]; then rel="${path#$root_for_rel/}"; else rel="$path"; fi

            local pass=0
            if [[ ${#includes[@]} -eq 0 && ${#excludes[@]} -eq 0 ]]; then
                pass=1
            else
                if filter_by_patterns "$rel" "$base" "$syntax" "$case_sensitive" "$match_base" "${includes[@]}" -- "${excludes[@]}"; then pass=1; fi
            fi
            if [[ $pass -ne 1 ]]; then total_skipped=$((total_skipped+1)); continue; fi

            local rc=0
            local attempted_before=$ENTRIES_ATTEMPTED
            local failed_before=$ENTRIES_FAILED

            if (( is_file==1 && ${#file_specs[@]} > 0 )); then
                apply_specs_to_path "$path" "false" "${file_specs[@]}" || rc=1
            fi
            if (( is_dir==1 && ${#dir_specs[@]} > 0 )); then
                apply_specs_to_path "$path" "false" "${dir_specs[@]}" || rc=1
            fi
            if (( is_dir==1 )) && (( ${#def_specs[@]} > 0 )); then
                apply_specs_to_path "$path" "true" "${def_specs[@]}" || rc=1
            fi

            local attempted_delta=$((ENTRIES_ATTEMPTED - attempted_before))
            local failed_delta=$((ENTRIES_FAILED - failed_before))
            if [[ $rc -eq 0 ]]; then
                total_applied=$((total_applied+1))
                # Single line per path for successful ACL application
                log_success "$path"
            else
                total_failed=$((total_failed+1))
                log_error "$path"
            fi
        done
    done

    # Summary
    local entries_ok=$((ENTRIES_ATTEMPTED - ENTRIES_FAILED))
    local success_pct=100
    if [[ $ENTRIES_ATTEMPTED -gt 0 ]]; then
        success_pct=$(( entries_ok * 100 / ENTRIES_ATTEMPTED ))
    fi
    local summary_suffix=""
    if [[ "${CONFIG[dry_run]}" == "true" ]]; then
        summary_suffix=" (dry-run)"
    fi
    log_bold "Summary${summary_suffix}: paths ok=$total_applied failed=$total_failed skipped=$total_skipped"
    log_bold "           entries ok=$entries_ok failed=$ENTRIES_FAILED attempted=$ENTRIES_ATTEMPTED (${success_pct}% ok)"

    if [[ $total_failed -eq 0 ]]; then return 0; else return 1; fi
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
            -q|--quiet)
                CONFIG[quiet]="true"
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

Apply POSIX ACLs to filesystem paths based on rule-based JSON configuration.
If PATHs are provided, only candidates under these paths are processed.

Required:
  -f, --file FILE     JSON file with ACL definitions

Options:
  --color MODE        Output colors: auto|always|never (default: auto)
  --no-color          Disable colors (equivalent to --color never)
  --mask VALUE        Mask handling: auto|skip|<rwx> (default: auto)
  --dry-run           Simulate without making changes
  -q, --quiet         Suppress informational output (errors still shown)
  -h, --help          Show this help message

Examples:
  # Apply all rules in config
  ${SCRIPT_NAME} -f rules.json

  # Apply only under specific paths
  ${SCRIPT_NAME} -f rules.json /srv/app /data/share

  # Simulate applying with a specific mask
  ${SCRIPT_NAME} -f rules.json --mask r-x --dry-run /opt/scripts

Config (excerpt):
  {
    "version": "1.0",
    "apply_order": "shallow_to_deep",
    "rules": [
      {
        "id": "example",
        "roots": ["/path"],
        "recurse": true,
        "include_self": true,
        "match": { "types": ["file","directory"], "pattern_syntax": "glob", "include": ["**/*"], "exclude": [] },
        "acl": { "files": [{"kind":"group","name":"team","mode":"rw-"}], "directories": [{"kind":"group","name":"team","mode":"rwx"}] },
        "apply_defaults": true,
        "default_acl": [{"kind":"group","name":"team","mode":"rwx"}]
      }
    ]
  }

Notes:
  - Paths within each rule are processed shallow-to-deep (or deep-to-shallow) per apply_order
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
    validate_configuration_groups  # Check that all groups exist
    cache_all_rules  # Performance optimization: cache all rule data upfront
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

    apply_rules
}

# Entry point - only execute if run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

