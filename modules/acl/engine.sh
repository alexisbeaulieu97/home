#!/bin/bash
#
# engine.sh - Apply POSIX ACLs to filesystem paths based on JSON definitions
# Refactored for production readiness with improved maintainability and design patterns
#

set -euo pipefail
set -o errtrace

# =============================================================================
# CONSTANTS AND EXIT CODES
# =============================================================================

readonly SCRIPT_NAME="$(basename "$0")"
readonly EXIT_SUCCESS=0
readonly EXIT_ERROR=1
readonly EXIT_INVALID_ARGS=2
readonly EXIT_MISSING_DEPS=3
readonly EXIT_FILE_ERROR=4
readonly RETURN_SUCCESS=0
readonly RETURN_SKIPPED=5
readonly RETURN_FAILED=1

readonly -a REQUIRED_COMMANDS=("jq" "setfacl")

# =============================================================================
# CONFIGURATION MANAGEMENT SERVICE
# =============================================================================

# Configuration service - encapsulates all configuration management
declare -A CONFIG=(
    [definitions_file]=""
    [color_mode]="auto"
    [mask_setting]="auto"
    [mask_explicit]=""
    [no_recalc_mask]="false"
    [dry_run]="false"
    [quiet]="false"
    [enable_colors]="true"
    [find_optimization]="true"
    [recursive_optimization]="true"
)

# Runtime state service - encapsulates all runtime state
declare -A RUNTIME_STATE=(
    [entries_attempted]="0"
    [entries_failed]="0"
    [cache_hits]="0"
    [optimized_rules]="0"
    [total_applied]="0"
    [total_failed]="0"
    [total_skipped]="0"
    [bulk_operations]="0"
    [bulk_verbose_threshold]="10"
)

declare -a target_paths=()

# =============================================================================
# CACHE SERVICE - Centralized caching with clear interface
# =============================================================================

declare -A cache_json=()
declare -A cache_rules=()
declare -A cache_paths=()
declare -A cache_groups=()
declare -A cache_types=()

# Cache service interface
cache_get() {
    local -r cache_type="$1" key="$2"
    local -n cache_ref="cache_${cache_type}"
    if [[ -n "${cache_ref[$key]:-}" ]]; then
        RUNTIME_STATE[cache_hits]=$((${RUNTIME_STATE[cache_hits]} + 1))
        echo "${cache_ref[$key]}"
        return 0
    fi
    return 1
}

cache_set() {
    local -r cache_type="$1" key="$2" value="$3"
    local -n cache_ref="cache_${cache_type}"
    cache_ref[$key]="$value"
}

cache_clear() {
    local -r cache_type="$1"
    local -n cache_ref="cache_${cache_type}"
    cache_ref=()
}

# Efficient rule data caching - consolidates all jq calls into one pass
cache_all_rules() {
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
            ($e.value.acl as $acl | 
                if ($acl|type)=="array" then 
                    ($acl | .[] | if type == "string" then . else specfmt(.) end | select(length>0) | "rule|\($e.key)|file_spec|\(.)", "rule|\($e.key)|dir_spec|\(.)")
                else 
                    (($acl.files // []) | .[] | if type == "string" then . else specfmt(.) end | select(length>0) | "rule|\($e.key)|file_spec|\(.)")?,
                    (($acl.directories // []) | .[] | if type == "string" then . else specfmt(.) end | select(length>0) | "rule|\($e.key)|dir_spec|\(.)")?
                end
            ),
            ($e.value.default_acl // [] | .[] | if type == "string" then . else specfmt(.) end | select(length>0) | "rule|\($e.key)|def_spec|\(.)"),
            ($e.value.match.include // [] | .[] | "rule|\($e.key)|include|\(.)"),
            ($e.value.match.exclude // [] | .[] | "rule|\($e.key)|exclude|\(.)")
        )
    ' "${CONFIG[definitions_file]}") || fail "$EXIT_ERROR" "Failed to parse definitions file"

    # Parse and cache the structured data
    local rules_count="0" apply_order="shallow_to_deep"
    while IFS='|' read -r -a parts; do
        [[ ${#parts[@]} -gt 0 ]] || continue
        case "${parts[0]}" in
            apply_order) apply_order="${parts[1]}" ;;
            rules_count) rules_count="${parts[1]}" ;;
            rule)
                local idx="${parts[1]}" kind="${parts[2]}"
                case "$kind" in
                    params)
                        local tsv="${parts[3]}"
                        for ((j=4; j<${#parts[@]}; j++)); do
                            tsv+=$'\t'"${parts[j]}"
                        done
                        cache_set rules "${idx}_params" "$tsv"
                        ;;
                    root)
                        local key="${idx}_roots"
                        local current_val
                        if current_val=$(cache_get rules "$key" 2>/dev/null); then
                            cache_set rules "$key" "${current_val}"$'\n'"${parts[3]}"
                        else
                            cache_set rules "$key" "${parts[3]}"
                        fi
                        ;;
                    file_spec)
                        local key="${idx}_file_specs"
                        local current_val
                        if current_val=$(cache_get rules "$key" 2>/dev/null); then
                            cache_set rules "$key" "${current_val}"$'\n'"${parts[3]}"
                        else
                            cache_set rules "$key" "${parts[3]}"
                        fi
                        ;;
                    dir_spec)
                        local key="${idx}_dir_specs"
                        local current_val
                        if current_val=$(cache_get rules "$key" 2>/dev/null); then
                            cache_set rules "$key" "${current_val}"$'\n'"${parts[3]}"
                        else
                            cache_set rules "$key" "${parts[3]}"
                        fi
                        ;;
                    def_spec)
                        local key="${idx}_def_specs"
                        local current_val
                        if current_val=$(cache_get rules "$key" 2>/dev/null); then
                            cache_set rules "$key" "${current_val}"$'\n'"${parts[3]}"
                        else
                            cache_set rules "$key" "${parts[3]}"
                        fi
                        ;;
                    include)
                        local key="${idx}_includes"
                        local current_val
                        if current_val=$(cache_get rules "$key" 2>/dev/null); then
                            cache_set rules "$key" "${current_val}"$'\n'"${parts[3]}"
                        else
                            cache_set rules "$key" "${parts[3]}"
                        fi
                        ;;
                    exclude)
                        local key="${idx}_excludes"
                        local current_val
                        if current_val=$(cache_get rules "$key" 2>/dev/null); then
                            cache_set rules "$key" "${current_val}"$'\n'"${parts[3]}"
                        else
                            cache_set rules "$key" "${parts[3]}"
                        fi
                        ;;
                esac
                ;;
        esac
    done <<< "$output"

    cache_set rules "rules_count" "$rules_count"
    cache_set rules "apply_order" "$apply_order"
}

# =============================================================================
# LOGGING SERVICE - Clean separation of concerns
# =============================================================================

declare -A color_codes=()

# Color service initialization
color_service_init() {
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

# Logging service interface
_log() {
    local -r color="$1" stream="$2" prefix="$3"; shift 3
    local color_start="${color_codes[$color]:-}"
    local color_end="${color_codes[reset]:-}"
    printf "%b%s%s%b\n" "$color_start" "$prefix" "$*" "$color_end" >&"$stream"
}

_log_unless_quiet() {
    [[ "${CONFIG[quiet]}" == "true" ]] || _log "$@"
}

# Public logging interface
log_info()       { _log_unless_quiet blue 2 "INFO: " "$*"; }
log_success()    { _log_unless_quiet green 2 "SUCCESS: " "$*"; }
log_error()      { _log red 2 "ERROR: " "$*"; }
log_warning()    { _log yellow 2 "WARNING: " "$*"; }
log_processing() { _log_unless_quiet cyan 2 "PROCESSING: " "$*"; }
log_bold()       { _log_unless_quiet bold 2 "" "$*"; }
log_progress()   { _log_unless_quiet blue 2 "PROGRESS: " "$*"; }

# =============================================================================
# ERROR HANDLING SERVICE
# =============================================================================

on_unexpected_error() {
    local -r exit_code="$?" line_no="${BASH_LINENO[0]:-unknown}" command="${BASH_COMMAND}"
    if [[ $exit_code -eq $RETURN_SKIPPED ]]; then
        return 0
    fi
    log_error "Unexpected failure on line $line_no (exit code $exit_code)"
    log_error "Failed command: $command"
    exit 1
}
trap on_unexpected_error ERR

fail() {
    local -r exit_code="$1"; shift
    log_error "$*"
    exit "$exit_code"
}

# =============================================================================
# VALIDATION SERVICE - Clean interface for all validations
# =============================================================================

# Dependency validation
validate_dependencies() {
    local missing_deps=()
    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        fail "$EXIT_MISSING_DEPS" "Missing required dependencies: ${missing_deps[*]}"
    fi
}

# Simple validation functions
is_readable_file() { [[ -f "$1" && -r "$1" ]]; }
is_valid_json()    { jq empty "$1" 2>/dev/null; }
is_valid_path()    { [[ -n "$1" ]]; }
is_valid_group()   { [[ "$1" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_-]*$ ]]; }
is_valid_perms()   { [[ "$1" =~ ^[rwxX-]{1,4}$ ]]; }
is_valid_mask()    { [[ "$1" =~ ^[rwx-]{1,3}$ ]]; }

# Complex validation functions
validate_definitions_file() {
    local -r file="${CONFIG[definitions_file]}"
    [[ -n "$file" ]] || fail "$EXIT_INVALID_ARGS" "No definitions file specified (use -f)"
    
    is_readable_file "$file" || fail "$EXIT_FILE_ERROR" "Cannot read definitions file '$file'"
    is_valid_json "$file" || fail "$EXIT_FILE_ERROR" "Invalid JSON in definitions file '$file'"
    
    local version
    version="$(jq -r '.version // "unknown"' "$file" 2>/dev/null)" || \
        fail "$EXIT_FILE_ERROR" "Cannot read version from definitions file"
    [[ "$version" != "null" ]] || fail "$EXIT_FILE_ERROR" "Definitions file missing version field"
    log_info "Using definitions version: $version"
}

validate_target_paths() {
    # Target paths are user-specified directories to limit processing scope
    # They don't need to exist in the definitions file - they filter the processing
    for path in "${target_paths[@]}"; do
        is_valid_path "$path" || fail "$EXIT_INVALID_ARGS" "Invalid path format: '$path'"
    done
}

validate_groups() {
    # Skip if getent not available
    command -v getent >/dev/null 2>&1 || return 0
    
    local rules_count
    rules_count=$(cache_get rules "rules_count")
    
    local -A groups_to_check=()
    for ((i=0; i<rules_count; i++)); do
        local file_specs dir_specs def_specs
        if file_specs=$(cache_get rules "${i}_file_specs" 2>/dev/null); then
            while IFS= read -r spec; do
                [[ "$spec" =~ ^g:([^:]+): ]] && groups_to_check["${BASH_REMATCH[1]}"]=1
            done <<< "$file_specs"
        fi
        if dir_specs=$(cache_get rules "${i}_dir_specs" 2>/dev/null); then
            while IFS= read -r spec; do
                [[ "$spec" =~ ^g:([^:]+): ]] && groups_to_check["${BASH_REMATCH[1]}"]=1
            done <<< "$dir_specs"
        fi
        if def_specs=$(cache_get rules "${i}_def_specs" 2>/dev/null); then
            while IFS= read -r spec; do
                [[ "$spec" =~ ^g:([^:]+): ]] && groups_to_check["${BASH_REMATCH[1]}"]=1
            done <<< "$def_specs"
        fi
    done
    
    local missing_groups=()
    for group in "${!groups_to_check[@]}"; do
        [[ -n "$group" ]] || continue
        if cache_get groups "$group" >/dev/null 2>&1; then
            continue
        fi
        if getent group "$group" >/dev/null 2>&1; then
            cache_set groups "$group" "exists"
        else
            missing_groups+=("$group")
            cache_set groups "$group" "missing"
        fi
    done
    
    if [[ ${#missing_groups[@]} -gt 0 ]]; then
        log_warning "Groups not found on system: ${missing_groups[*]}"
    fi
}

# =============================================================================
# UTILITY SERVICES
# =============================================================================

# Path utility service
get_path_type() {
    local -r path="$1"
    
    if cache_get types "$path"; then
        return 0
    fi
    
    local path_type=""
    if [[ -f "$path" ]]; then
        path_type="file"
    elif [[ -d "$path" ]]; then
        path_type="directory"
    else
        path_type="unknown"
    fi
    
    cache_set types "$path" "$path_type"
    echo "$path_type"
}

# Path filtering utility
path_under_any_filter() {
    local -r path="$1"
    [[ ${#target_paths[@]} -eq 0 ]] && return 0
    
    for filter in "${target_paths[@]}"; do
        if [[ "$path" == "$filter" || "$path" == "$filter"/* ]]; then
            return 0
        fi
    done
    return 1
}

# Pattern matching utilities
match_glob() {
    local -r text="$1" pattern="$2" case_sensitive="$3"
    if [[ "$case_sensitive" == "true" ]]; then
        [[ "$text" == $pattern ]]
    else
        shopt -s nocasematch
        [[ "$text" == $pattern ]]
        local result=$?
        shopt -u nocasematch
        return $result
    fi
}

match_regex() {
    local -r text="$1" pattern="$2" case_sensitive="$3"
    if [[ "$case_sensitive" == "true" ]]; then
        [[ "$text" =~ $pattern ]]
    else
        shopt -s nocasematch
        [[ "$text" =~ $pattern ]]
        local result=$?
        shopt -u nocasematch
        return $result
    fi
}

# Rule data accessors
get_rule_data() {
    local -r rule_idx="$1" data_type="$2"
    cache_get rules "${rule_idx}_${data_type}" 2>/dev/null || true
}

get_rule_params() {
    local -r rule_idx="$1"
    cache_get rules "${rule_idx}_params" 2>/dev/null || true
}

# =============================================================================
# ACL APPLICATION STRATEGY SERVICE
# =============================================================================

# setfacl command builder service
build_setfacl_command() {
    local -r path="$1" is_default="$2"; shift 2
    local -a specs=("$@")
    
    local -a args=("setfacl")
    [[ "${CONFIG[no_recalc_mask]}" == "true" ]] && args+=("-n")
    [[ "$is_default" == "true" ]] && args+=("-d")
    
    for spec in "${specs[@]}"; do
        args+=("-m" "$spec")
    done
    
    [[ "${CONFIG[mask_setting]}" == "explicit" ]] && \
        args+=("-m" "m::${CONFIG[mask_explicit]}")
    
    args+=("--" "$path")
    printf '%s\n' "${args[@]}"
}

# Execute setfacl with error handling and metrics
execute_setfacl() {
    local -r path="$1" is_default="$2"; shift 2
    local -a specs=("$@")
    
    [[ ${#specs[@]} -gt 0 ]] || return 0
    
    local -a cmd_args
    mapfile -t cmd_args < <(build_setfacl_command "$path" "$is_default" "${specs[@]}")
    
    # Track bulk operations for progress reporting
    RUNTIME_STATE[bulk_operations]=$((${RUNTIME_STATE[bulk_operations]} + 1))
    local bulk_ops=${RUNTIME_STATE[bulk_operations]}
    local verbose_threshold=${RUNTIME_STATE[bulk_verbose_threshold]}
    
    if [[ "${CONFIG[dry_run]}" == "true" ]]; then
        # Only log individual operations if under threshold or at specific intervals
        if [[ $bulk_ops -le $verbose_threshold ]] || [[ $((bulk_ops % 50)) -eq 0 ]]; then
            if [[ $bulk_ops -gt $verbose_threshold ]]; then
                log_progress "Processed $bulk_ops individual paths..."
            else
                log_info "DRY-RUN: ${cmd_args[*]}"
            fi
        fi
        RUNTIME_STATE[entries_attempted]=$((${RUNTIME_STATE[entries_attempted]} + ${#specs[@]}))
        return 0
    fi
    
    # Show progress for real operations too
    if [[ $bulk_ops -le $verbose_threshold ]] || [[ $((bulk_ops % 50)) -eq 0 ]]; then
        if [[ $bulk_ops -gt $verbose_threshold ]]; then
            log_progress "Applied ACLs to $bulk_ops individual paths..."
        fi
    fi
    
    if "${cmd_args[@]}" 2>&1; then
        RUNTIME_STATE[entries_attempted]=$((${RUNTIME_STATE[entries_attempted]} + ${#specs[@]}))
        return 0
    else
        RUNTIME_STATE[entries_failed]=$((${RUNTIME_STATE[entries_failed]} + ${#specs[@]}))
        return 1
    fi
}

# Strategy interface for different ACL application methods
apply_acl_strategy() {
    local -r strategy="$1"; shift
    case "$strategy" in
        "direct_recursive")  apply_strategy_direct_recursive "$@" ;;
        "individual")        apply_strategy_individual "$@" ;;
        *)                   fail "$EXIT_ERROR" "Unknown ACL strategy: $strategy" ;;
    esac
}

# Direct recursive strategy - uses setfacl -R
apply_strategy_direct_recursive() {
    local -r path="$1" is_default="$2"; shift 2
    local -a specs=("$@")
    
    [[ ${#specs[@]} -gt 0 ]] || return 0
    
    local -a cmd_args
    mapfile -t cmd_args < <(build_setfacl_command "$path" "$is_default" "${specs[@]}")
    
    # Add recursive flag  
    local -a final_args=()
    for arg in "${cmd_args[@]}"; do
        if [[ "$arg" == "setfacl" ]]; then
            final_args+=("$arg" "-R")
        else
            final_args+=("$arg")
        fi
    done
    
    if [[ "${CONFIG[dry_run]}" == "true" ]]; then
        log_info "DRY-RUN: ${final_args[*]}"
        RUNTIME_STATE[entries_attempted]=$((${RUNTIME_STATE[entries_attempted]} + ${#specs[@]}))
        return 0
    fi
    
    if "${final_args[@]}" 2>&1; then
        RUNTIME_STATE[entries_attempted]=$((${RUNTIME_STATE[entries_attempted]} + ${#specs[@]}))
        return 0
    else
        RUNTIME_STATE[entries_failed]=$((${RUNTIME_STATE[entries_failed]} + ${#specs[@]}))
        return 1
    fi
}

# Individual path strategy - applies to single paths
apply_strategy_individual() {
    local -r path="$1" is_default="$2"; shift 2
    execute_setfacl "$path" "$is_default" "$@"
}

# =============================================================================
# RULE PROCESSING SERVICE
# =============================================================================

# Rule analysis service
can_use_recursive_optimization() {
    local -r rule_idx="$1"
    
    # Disabled by configuration
    [[ "${CONFIG[recursive_optimization]}" == "true" ]] || return 1
    
    # Get rule parameters
    local params
    params=$(get_rule_params "$rule_idx")
    [[ -n "$params" ]] || return 1
    
    local recurse include_self
    IFS=$'\t' read -r recurse include_self _ _ _ _ _ <<< "$params"
    
    # Check if rule is recursive and includes self
    [[ "$recurse" == "true" ]] || return 1
    [[ "$include_self" == "true" ]] || return 1
    
    # Check for include/exclude patterns  
    local includes excludes
    includes=$(get_rule_data "$rule_idx" "includes")
    excludes=$(get_rule_data "$rule_idx" "excludes")
    
    # If we have any patterns, can't use optimization
    [[ -z "$includes" && -z "$excludes" ]] || return 1
    
    return 0
}

# Simplified path enumeration for recursive rules
enumerate_paths_simple() {
    local -r recurse="$1" include_self="$2"; shift 2
    local -a roots=("$@")
    
    for root in "${roots[@]}"; do
        [[ -e "$root" ]] || continue
        
        if [[ "$include_self" == "true" ]]; then
            echo "$root"
        fi
        
        if [[ "$recurse" == "true" && -d "$root" ]]; then
            if [[ "${CONFIG[find_optimization]}" == "true" ]]; then
                find "$root" -mindepth 1 -type f -o -type d 2>/dev/null || true
            else
                find "$root" -mindepth 1 2>/dev/null || true
            fi
        fi
    done
}

# Main rule execution service - simplified and focused
execute_rule() {
    local -r rule_idx="$1"
    
    log_processing "Rule $((rule_idx + 1))"
    
    # Get rule data
    local params
    params=$(get_rule_params "$rule_idx")
    [[ -n "$params" ]] || {
        log_warning "No parameters for rule $rule_idx"
        return 0
    }
    
    local recurse include_self types_csv
    IFS=$'\t' read -r recurse include_self types_csv _ _ _ _ <<< "$params"
    
    local -a roots=() file_specs=() dir_specs=() def_specs=()
    local roots_data file_specs_data dir_specs_data def_specs_data
    roots_data=$(get_rule_data "$rule_idx" "roots")
    file_specs_data=$(get_rule_data "$rule_idx" "file_specs")
    dir_specs_data=$(get_rule_data "$rule_idx" "dir_specs")
    def_specs_data=$(get_rule_data "$rule_idx" "def_specs")
    
    if [[ -n "$roots_data" ]]; then
        mapfile -t roots <<< "$roots_data"
    fi
    if [[ -n "$file_specs_data" ]]; then
        mapfile -t file_specs <<< "$file_specs_data"
    fi
    if [[ -n "$dir_specs_data" ]]; then
        mapfile -t dir_specs <<< "$dir_specs_data"
    fi
    if [[ -n "$def_specs_data" ]]; then
        mapfile -t def_specs <<< "$def_specs_data"
    fi
    
    # Filter valid roots
    local -a valid_roots=()
    for root in "${roots[@]}"; do
        [[ -n "$root" && -e "$root" ]] || continue
        path_under_any_filter "$root" && valid_roots+=("$root")
    done
    
    [[ ${#valid_roots[@]} -gt 0 ]] || {
        log_info "No valid roots for rule $((rule_idx + 1))"
        return 0
    }
    
    # Determine file/directory wants
    local want_files=0 want_dirs=0
    if [[ -z "$types_csv" || "$types_csv" == "," ]]; then
        # Infer from specs
        [[ ${#file_specs[@]} -gt 0 ]] && want_files=1
        [[ ${#dir_specs[@]} -gt 0 || ${#def_specs[@]} -gt 0 ]] && want_dirs=1
        # Default to both if nothing specified
        [[ $want_files -eq 0 && $want_dirs -eq 0 ]] && { want_files=1; want_dirs=1; }
    else
        [[ ",${types_csv}," == *,file,* ]] && want_files=1
        [[ ",${types_csv}," == *,directory,* ]] && want_dirs=1
    fi
    
    # Choose strategy
    local strategy="individual"
    if can_use_recursive_optimization "$rule_idx"; then
        strategy="direct_recursive"
        RUNTIME_STATE[optimized_rules]=$((${RUNTIME_STATE[optimized_rules]} + 1))
        log_info "Using direct recursive optimization"
    fi
    
    local rule_failed=0
    
    # Apply strategy to roots
    for root in "${valid_roots[@]}"; do
        local root_failed=0
        
        # Apply file specs
        if [[ $want_files -eq 1 && ${#file_specs[@]} -gt 0 ]]; then
            if [[ "$strategy" == "direct_recursive" ]]; then
                if ! apply_acl_strategy "$strategy" "$root" "false" "${file_specs[@]}"; then
                    root_failed=1
                fi
            else
                # For individual strategy, enumerate paths and filter files
                local -a paths
                log_progress "Enumerating paths for individual file processing..."
                mapfile -t paths < <(enumerate_paths_simple "$recurse" "$include_self" "$root")
                local file_count=0
                for path in "${paths[@]}"; do
                    path_under_any_filter "$path" || continue
                    local path_type
                    path_type=$(get_path_type "$path")
                    [[ "$path_type" == "file" ]] || continue
                    ((file_count++))
                done
                if [[ $file_count -gt 0 ]]; then
                    log_progress "Processing $file_count files individually..."
                fi
                
                # Reset bulk operations counter for this section
                RUNTIME_STATE[bulk_operations]=0
                for path in "${paths[@]}"; do
                    path_under_any_filter "$path" || continue
                    local path_type
                    path_type=$(get_path_type "$path")
                    [[ "$path_type" == "file" ]] || continue
                    if ! apply_acl_strategy "individual" "$path" "false" "${file_specs[@]}"; then
                        root_failed=1
                    fi
                done
            fi
        fi
        
        # Apply directory specs
        if [[ $want_dirs -eq 1 && ${#dir_specs[@]} -gt 0 ]]; then
            if [[ "$strategy" == "direct_recursive" ]]; then
                if ! apply_acl_strategy "$strategy" "$root" "false" "${dir_specs[@]}"; then
                    root_failed=1
                fi
            else
                local -a paths
                log_progress "Enumerating paths for individual directory processing..."
                mapfile -t paths < <(enumerate_paths_simple "$recurse" "$include_self" "$root")
                local dir_count=0
                for path in "${paths[@]}"; do
                    path_under_any_filter "$path" || continue
                    local path_type
                    path_type=$(get_path_type "$path")
                    [[ "$path_type" == "directory" ]] || continue
                    ((dir_count++))
                done
                if [[ $dir_count -gt 0 ]]; then
                    log_progress "Processing $dir_count directories individually..."
                fi
                
                # Reset bulk operations counter for this section  
                RUNTIME_STATE[bulk_operations]=0
                for path in "${paths[@]}"; do
                    path_under_any_filter "$path" || continue
                    local path_type
                    path_type=$(get_path_type "$path")
                    [[ "$path_type" == "directory" ]] || continue
                    if ! apply_acl_strategy "individual" "$path" "false" "${dir_specs[@]}"; then
                        root_failed=1
                    fi
                done
            fi
        fi
        
        # Apply default specs to directories
        if [[ ${#def_specs[@]} -gt 0 ]]; then
            if [[ "$strategy" == "direct_recursive" && -d "$root" ]]; then
                if ! apply_acl_strategy "$strategy" "$root" "true" "${def_specs[@]}"; then
                    root_failed=1
                fi
            else
                local -a paths
                log_progress "Enumerating paths for default ACL processing..."
                mapfile -t paths < <(enumerate_paths_simple "$recurse" "$include_self" "$root")
                local default_dir_count=0
                for path in "${paths[@]}"; do
                    path_under_any_filter "$path" || continue
                    [[ -d "$path" ]] || continue
                    ((default_dir_count++))
                done
                if [[ $default_dir_count -gt 0 ]]; then
                    log_progress "Processing default ACLs for $default_dir_count directories individually..."
                fi
                
                # Reset bulk operations counter for this section
                RUNTIME_STATE[bulk_operations]=0
                for path in "${paths[@]}"; do
                    path_under_any_filter "$path" || continue
                    [[ -d "$path" ]] || continue
                    if ! apply_acl_strategy "individual" "$path" "true" "${def_specs[@]}"; then
                        root_failed=1
                    fi
                done
            fi
        fi
        
        if [[ $root_failed -eq 0 ]]; then
            RUNTIME_STATE[total_applied]=$((${RUNTIME_STATE[total_applied]} + 1))
            if [[ "$strategy" == "direct_recursive" ]]; then
                log_success "$root (recursive optimization)"
            else
                log_success "$root"
            fi
        else
            RUNTIME_STATE[total_failed]=$((${RUNTIME_STATE[total_failed]} + 1))
            log_error "$root"
            rule_failed=1
        fi
    done
    
    return $rule_failed
}

# =============================================================================
# COMMAND LINE PARSING SERVICE
# =============================================================================

get_option_value() {
    local -r opt="$1" next_arg="${2:-}"
    if [[ "$opt" == *=* ]]; then
        echo "${opt#*=}"
    else
        [[ -n "$next_arg" ]] || fail "$EXIT_INVALID_ARGS" "Option '$opt' requires an argument"
        echo "$next_arg"
    fi
}

set_color_mode() {
    local -r mode="$1"
    case "$mode" in
        auto|always|never) CONFIG[color_mode]="$mode" ;;
        *) fail "$EXIT_INVALID_ARGS" "Invalid color mode '$mode' (must be auto, always, or never)" ;;
    esac
}

set_definitions_file() {
    local -r file="$1"
    [[ -n "${CONFIG[definitions_file]}" ]] && fail "$EXIT_INVALID_ARGS" "Definitions file can only be specified once"
    [[ -n "$file" ]] || fail "$EXIT_INVALID_ARGS" "Definitions file path cannot be empty"
    CONFIG[definitions_file]="$file"
}

configure_mask() {
    local -r value="$1"
    case "$value" in
        auto)
            CONFIG[mask_setting]="auto"
            CONFIG[no_recalc_mask]="false"
            ;;
        skip)
            CONFIG[mask_setting]="skip"
            CONFIG[no_recalc_mask]="true"
            ;;
        *)
            if is_valid_mask "$value"; then
                CONFIG[mask_setting]="explicit"
                CONFIG[mask_explicit]="$value"
                CONFIG[no_recalc_mask]="true"
            else
                fail "$EXIT_INVALID_ARGS" "Invalid mask '$value' (use auto, skip, or rwx pattern)"
            fi
            ;;
    esac
}

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
                if [[ "$1" == *=* ]]; then shift; else shift 2; fi ;;
            --mask|--mask=*)
                local value
                value="$(get_option_value "$1" "${2:-}")"
                configure_mask "$value"
                if [[ "$1" == *=* ]]; then shift; else shift 2; fi ;;
            --no-color)
                CONFIG[color_mode]="never"
                shift ;;
            --dry-run)
                CONFIG[dry_run]="true"
                shift ;;
            --no-find-optimization)
                CONFIG[find_optimization]="false"
                shift ;;
            --no-recursive-optimization)
                CONFIG[recursive_optimization]="false"
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
# USAGE DOCUMENTATION
# =============================================================================

show_usage() {
    cat << 'EOF'
Usage: engine.sh -f FILE [OPTIONS] [PATH...]

Apply POSIX ACLs to filesystem paths based on rule-based JSON configuration.

Required:
  -f, --file FILE     JSON file with ACL definitions

Options:
  --color MODE        Output colors: auto|always|never (default: auto)
  --no-color          Disable colors (equivalent to --color never)
  --mask VALUE        Mask handling: auto|skip|<rwx> (default: auto)
  --dry-run           Simulate without making changes
  -q, --quiet         Suppress informational output (errors still shown)

Performance Options:
  --no-find-optimization     Disable find command optimizations
  --no-recursive-optimization Disable direct setfacl -R optimization

  -h, --help          Show this help message

Examples:
  # Apply all rules in config
  engine.sh -f rules.json

  # Disable recursive optimization
  engine.sh -f rules.json --no-recursive-optimization /srv/app

Exit Codes:
  0 Success  1 Error  2 Invalid Arguments  3 Missing Dependencies  4 File Error
EOF
}

# =============================================================================
# MAIN ORCHESTRATION
# =============================================================================

initialize() {
    validate_dependencies
    color_service_init
    validate_definitions_file
    cache_all_rules
    validate_groups
}

determine_target_paths() {
    if [[ ${#target_paths[@]} -gt 0 ]]; then
        log_info "Targets specified:"
        printf "  %s\n" "${target_paths[@]}" >&2
        validate_target_paths
    else
        log_info "No specific targets specified, applying to all defined paths."
    fi
}

apply_all_rules() {
    local rules_count
    rules_count=$(cache_get rules "rules_count")
    
    local apply_order
    apply_order=$(cache_get rules "apply_order")
    log_info "Apply order: $apply_order"
    
    local total_rule_failures=0
    for ((i=0; i<rules_count; i++)); do
        log_bold "---------- PROCESSING RULE $((i+1)) ------------"
        if ! execute_rule "$i"; then
            ((total_rule_failures++))
        fi
    done
    
    # Summary
    local entries_ok=$((${RUNTIME_STATE[entries_attempted]} - ${RUNTIME_STATE[entries_failed]}))
    local success_pct=100
    if [[ ${RUNTIME_STATE[entries_attempted]} -gt 0 ]]; then
        success_pct=$(( entries_ok * 100 / ${RUNTIME_STATE[entries_attempted]} ))
    fi
    
    local summary_suffix=""
    [[ "${CONFIG[dry_run]}" == "true" ]] && summary_suffix=" (dry-run)"
    
    log_bold "Summary${summary_suffix}: paths ok=${RUNTIME_STATE[total_applied]} failed=${RUNTIME_STATE[total_failed]} skipped=${RUNTIME_STATE[total_skipped]} optimized=${RUNTIME_STATE[optimized_rules]}"
    log_bold "           entries ok=$entries_ok failed=${RUNTIME_STATE[entries_failed]} attempted=${RUNTIME_STATE[entries_attempted]} (${success_pct}% ok)"
    
    # Performance metrics
    log_info "Performance: cache_hits=${RUNTIME_STATE[cache_hits]} optimized_rules=${RUNTIME_STATE[optimized_rules]}"
    
    return $total_rule_failures
}

main() {
    parse_arguments "$@"
    initialize
    determine_target_paths
    
    log_bold "ACL definitions from: ${CONFIG[definitions_file]}"
    
    if apply_all_rules; then
        exit "$EXIT_SUCCESS"
    else
        exit "$EXIT_ERROR"
    fi
}

# Entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi