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
)

# Runtime state
declare -a target_paths=()
declare -A json_cache=()
declare -A color_codes=()

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
    if result=$(jq -r -f - "${jq_args[@]}" "$file" <<<"$jq_filter" 2>&1); then
        json_cache[$cache_key]="$result"
        echo "$result"
    else
        fail "$EXIT_ERROR" "JSON query failed for '$file' with filter '$jq_filter': $result"
    fi
}

# =============================================================================
# RULES ACCESSORS (new schema)
# =============================================================================

get_apply_order() {
    jq -r '.apply_order // "shallow_to_deep"' "${CONFIG[definitions_file]}"
}

get_rules_count() {
    jq -r '.rules | length' "${CONFIG[definitions_file]}"
}

get_rule_roots() {
    local -r idx="$1"
    jq -r --argjson i "$idx" '.rules[$i].roots[]' "${CONFIG[definitions_file]}"
}

get_rule_params_tsv() {
    local -r idx="$1"
    jq -r \
      --argjson i "$idx" \
      '.rules[$i] as $r | [($r.recurse // false), ($r.include_self // true), ((($r.match.types // ["file","directory"]) | join(","))), ($r.match.pattern_syntax // "glob"), ($r.match.match_base // true), ($r.match.case_sensitive // true), ($r.apply_defaults // false)] | @tsv' \
      "${CONFIG[definitions_file]}"
}

# Returns newline-separated setfacl specs for entries of a given type: files|directories
get_rule_entry_specs() {
    local -r idx="$1" type="$2"
    jq -r \
      --argjson i "$idx" --arg type "$type" \
      '.rules[$i].entries[$type] // [] | .[] | if .kind == "user" then "u:\(.name):\(.perms)" elif .kind == "group" then "g:\(.name):\(.perms)" elif .kind == "owner" then "u::\(.perms)" elif .kind == "owning_group" then "g::\(.perms)" elif .kind == "other" then "o::\(.perms)" elif .kind == "mask" then "m::\(.perms)" else empty end' \
      "${CONFIG[definitions_file]}"
}

# Returns newline-separated setfacl specs for default entries (directories only)
get_rule_default_specs() {
    local -r idx="$1"
    jq -r \
      --argjson i "$idx" \
      '.rules[$i].default_entries // [] | .[] | if .kind == "user" then "u:\(.name):\(.perms)" elif .kind == "group" then "g:\(.name):\(.perms)" elif .kind == "owner" then "u::\(.perms)" elif .kind == "owning_group" then "g::\(.perms)" elif .kind == "other" then "o::\(.perms)" elif .kind == "mask" then "m::\(.perms)" else empty end' \
      "${CONFIG[definitions_file]}"
}

# Pattern lists (newline-separated) for include/exclude
get_rule_patterns() {
    local -r idx="$1" kind="$2" # kind: include|exclude
    jq -r --argjson i "$idx" --arg kind "$kind" '.rules[$i].match[$kind] // [] | .[]' "${CONFIG[definitions_file]}"
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

    local suffix=""
    [[ "$recursive" == "true" ]] && suffix=" (recursively)"

    if [[ "${CONFIG[dry_run]}" == "true" ]]; then
        log_info "Dry-run: setfacl ${args[*]} -- \"$path\""
        log_success "Applied ACL: $acl_entry$suffix (dry-run)"
        return "$RETURN_SUCCESS"
    fi

    local output
    if output=$(setfacl "${args[@]}" -- "$path" 2>&1); then
        log_success "Applied ACL: $acl_entry$suffix"
        return "$RETURN_SUCCESS"
    else
        log_error "Failed to apply ACL to '$path': $output"
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
    if [[ "$cs" == "false" ]]; then shopt -s nocasematch; else shopt -u nocasematch; fi
    for pat in "${patterns[@]}"; do
        [[ -z "$pat" ]] && continue
        if [[ "$str" == $pat ]]; then
            (( saved==1 )) && shopt -s nocasematch || shopt -u nocasematch
            return 0
        fi
        if [[ "$mb" == "true" ]] && [[ "$base" == $pat ]]; then
            (( saved==1 )) && shopt -s nocasematch || shopt -u nocasematch
            return 0
        fi
    done
    (( saved==1 )) && shopt -s nocasematch || shopt -u nocasematch
    return 1
}

match_regex() {
    local -r str="$1" base="$2" cs="$3" mb="$4"; shift 4
    local -a patterns=("$@")
    local flags="-E"
    [[ "$cs" == "false" ]] && flags="-Ei"
    for pat in "${patterns[@]}"; do
        [[ -z "$pat" ]] && continue
        echo "$str" | grep $flags -- "$pat" >/dev/null 2>&1 && return 0
        if [[ "$mb" == "true" ]]; then
            echo "$base" | grep $flags -- "$pat" >/dev/null 2>&1 && return 0
        fi
    done
    return 1
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
    local rc=0
    for spec in "${specs[@]}"; do
        [[ -z "$spec" ]] && continue
        ENTRIES_ATTEMPTED=$((ENTRIES_ATTEMPTED+1))
        local -a args
        mapfile -t args < <(build_setfacl_args_default "$spec" "$is_default")
        set +e
        execute_setfacl "$path" "$spec" "false" "${args[@]}"
        local r=$?
        set -e
        if [[ $r -ne 0 ]]; then
            ENTRIES_FAILED=$((ENTRIES_FAILED+1))
            rc=1
        fi
    done
    [[ $rc -eq 0 ]] && return "$RETURN_SUCCESS" || return "$RETURN_FAILED"
}

apply_rules() {
    local total_applied=0 total_skipped=0 total_failed=0
    local rules_count; rules_count=$(get_rules_count)
    local apply_order; apply_order=$(get_apply_order)

    for ((i=0; i<rules_count; i++)); do
        log_bold "---------- PROCESSING RULE $((i+1)) ------------"
        local tsv recurse include_self types_csv syntax match_base case_sensitive apply_defaults
        local save_IFS="$IFS"; IFS=$'\t'; tsv=$(get_rule_params_tsv "$i"); read -r recurse include_self types_csv syntax match_base case_sensitive apply_defaults <<< "$tsv"; IFS="$save_IFS"
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
            log_info "No candidates for this rule"
            continue
        fi
        # sort by depth
        if [[ "$apply_order" == "deep_to_shallow" ]]; then
            mapfile -t candidates < <(printf '%s\n' "${candidates[@]}" | awk '{print gsub(/\//, "&"), $0}' | sort -rn | cut -d' ' -f2-)
        else
            mapfile -t candidates < <(printf '%s\n' "${candidates[@]}" | awk '{print gsub(/\//, "&"), $0}' | sort -n | cut -d' ' -f2-)
        fi

        local want_files=0 want_dirs=0
        [[ ",${types_csv}," == *,file,* ]] && want_files=1
        [[ ",${types_csv}," == *,directory,* ]] && want_dirs=1

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
            log_bold ""
            log_bold "---------- $path ----------"
            if (( is_file==1 && ${#file_specs[@]} > 0 )); then
                apply_specs_to_path "$path" "false" "${file_specs[@]}" || rc=1
            fi
            if (( is_dir==1 && ${#dir_specs[@]} > 0 )); then
                apply_specs_to_path "$path" "false" "${dir_specs[@]}" || rc=1
            fi
            if (( is_dir==1 )) && [[ "$apply_defaults" == "true" ]] && (( ${#def_specs[@]} > 0 )); then
                apply_specs_to_path "$path" "true" "${def_specs[@]}" || rc=1
            fi

            local attempted_delta=$((ENTRIES_ATTEMPTED - attempted_before))
            local failed_delta=$((ENTRIES_FAILED - failed_before))
            if [[ $rc -eq 0 ]]; then
                total_applied=$((total_applied+1))
                log_success "Applied to $path (entries: $attempted_delta, failed: $failed_delta)"
            else
                total_failed=$((total_failed+1))
                log_error "Failed on $path (entries: $attempted_delta, failed: $failed_delta)"
            fi
            log_bold ""
        done
    done

    log_bold "Summary:"
    log_bold "- Paths applied (all entries succeeded): $total_applied"
    log_bold "- Paths skipped: $total_skipped"
    log_bold "- Paths with failures: $total_failed"
    log_bold "- ACL entries attempted: $ENTRIES_ATTEMPTED"
    log_bold "- ACL entries failed: $ENTRIES_FAILED"

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
        "entries": { "files": [{"kind":"group","name":"team","perms":"rw-"}], "directories": [{"kind":"group","name":"team","perms":"rwx"}] },
        "apply_defaults": true,
        "default_entries": [{"kind":"group","name":"team","perms":"rwx"}]
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

