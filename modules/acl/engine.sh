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
    [output_format]="text"
    
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
    [start_time]=""
    [end_time]=""
)

declare -a target_paths=()

# JSON output data collection
declare -A JSON_OUTPUT=(
    [warnings]=""
    [errors]=""
    [rule_summaries]=""
)

# Function to add rule summary to JSON output
json_escape_string() {
    # Robust JSON escaper using jq. Reads stdin and outputs a fully quoted JSON string.
    jq -R -s @json 2>/dev/null
}

add_rule_summary() {
    local rule_idx="$1"
    local status="$2"  # "success", "failed", "skipped"
    local message="$3"

    # Get rule information
    local roots_data file_specs_data dir_specs_data def_specs_data
    roots_data=$(get_rule_data "$rule_idx" "roots")
    file_specs_data=$(get_rule_data "$rule_idx" "file_specs")
    dir_specs_data=$(get_rule_data "$rule_idx" "dir_specs")
    def_specs_data=$(get_rule_data "$rule_idx" "def_specs")

    # Build ACL specs array - collect unique specs to avoid duplication
    local -A unique_specs=()
    local acl_specs=""
    local separator=""

    # Collect from all spec types
    if [[ -n "$file_specs_data" ]]; then
        while IFS= read -r spec; do
            [[ -n "$spec" ]] && unique_specs["$spec"]=1
        done <<< "$file_specs_data"
    fi
    if [[ -n "$dir_specs_data" ]]; then
        while IFS= read -r spec; do
            [[ -n "$spec" ]] && unique_specs["$spec"]=1
        done <<< "$dir_specs_data"
    fi
    if [[ -n "$def_specs_data" ]]; then
        while IFS= read -r spec; do
            [[ -n "$spec" ]] && unique_specs["$spec"]=1
        done <<< "$def_specs_data"
    fi

    # Build JSON array from unique specs
    for spec in "${!unique_specs[@]}"; do
        local esc
        esc=$(printf '%s' "$spec" | json_escape_string)
        acl_specs+="${separator}${esc}" && separator=","
    done

    # Build roots array
    local roots_array=""
    local root_separator=""
    if [[ -n "$roots_data" ]]; then
        while IFS= read -r root; do
            [[ -n "$root" ]] || continue
            local esc
            esc=$(printf '%s' "$root" | json_escape_string)
            roots_array+="${root_separator}${esc}" && root_separator=","
        done <<< "$roots_data"
    fi

    # Escape message
    local esc_message
    esc_message=$(printf '%s' "$message" | json_escape_string)

    local rule_json=$(cat << EOF
    {
      "index": $rule_idx,
      "roots": [$roots_array],
      "acl_specs": [$acl_specs],
      "status": "$status",
      "message": $esc_message
    }
EOF
)

    # Add to rule summaries
    if [[ -n "${JSON_OUTPUT[rule_summaries]}" ]]; then
        JSON_OUTPUT[rule_summaries]="${JSON_OUTPUT[rule_summaries]},$rule_json"
    else
        JSON_OUTPUT[rule_summaries]="$rule_json"
    fi
}

# =============================================================================
# CACHE SERVICE - Centralized caching with clear interface
# =============================================================================

declare -A cache_rules=()
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
                ( $e.value.include_root // true ) as $inc_root
                | ( $e.value.depth // "infinite" ) as $depth
                | "rule|\($e.key)|params|\($inc_root)|\($depth)|\(($e.value.match.types // ["file","directory"]) | join(","))|\($e.value.match.pattern_syntax // "glob")|\($e.value.match.match_base // true)|\($e.value.match.case_sensitive // true)"
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

# JSON output data collection
_collect_for_json() {
    local -r type="$1"; shift
    local message="$*"

    if [[ "${CONFIG[output_format]}" == "json" || "${CONFIG[output_format]}" == "jsonl" ]]; then
        # Escape message for JSON as a fully quoted JSON string
        message=$(printf '%s' "$message" | json_escape_string)

        case "$type" in
            error)
                if [[ -n "${JSON_OUTPUT[errors]}" ]]; then
                    JSON_OUTPUT[errors]="${JSON_OUTPUT[errors]},"
                fi
                JSON_OUTPUT[errors]="${JSON_OUTPUT[errors]}$message"
                ;;
            warning)
                if [[ -n "${JSON_OUTPUT[warnings]}" ]]; then
                    JSON_OUTPUT[warnings]="${JSON_OUTPUT[warnings]},"
                fi
                JSON_OUTPUT[warnings]="${JSON_OUTPUT[warnings]}$message"
                ;;
        esac
    fi
}

# Public logging interface - modified to suppress output in JSON modes
log_info() {
    if [[ "${CONFIG[output_format]}" == "text" ]]; then
        _log_unless_quiet blue 2 "INFO: " "$*"
    fi
}

log_success() {
    if [[ "${CONFIG[output_format]}" == "text" ]]; then
        _log_unless_quiet green 2 "SUCCESS: " "$*"
    fi
}

log_error() {
    _collect_for_json "error" "$*"
    # Always show errors on stderr, even in JSON mode, for debugging
    _log red 2 "ERROR: " "$*"
}

log_warning() {
    _collect_for_json "warning" "$*"
    if [[ "${CONFIG[output_format]}" == "text" ]]; then
        _log yellow 2 "WARNING: " "$*"
    fi
}

log_processing() {
    if [[ "${CONFIG[output_format]}" == "text" ]]; then
        _log_unless_quiet cyan 2 "PROCESSING: " "$*"
    fi
}

log_bold() {
    if [[ "${CONFIG[output_format]}" == "text" ]]; then
        _log_unless_quiet bold 2 "" "$*"
    fi
}

log_progress() {
    if [[ "${CONFIG[output_format]}" == "text" ]]; then
        _log_unless_quiet blue 2 "PROGRESS: " "$*"
    fi
}

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

fail() {
    local -r exit_code="$1"; shift
    log_error "$*"
    exit "$exit_code"
}

# =============================================================================
# VALIDATION SERVICE - Clean interface for all validations
# =============================================================================

# Dependency validation (test-friendly: returns non-zero instead of exiting)
validate_dependencies() {
    # Ensure PATH changes are respected even if commands were hashed earlier
    hash -r 2>/dev/null || true
    local missing_deps=()
    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        if ! is_command_resolvable "$cmd"; then
            missing_deps+=("$cmd")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        return 1
    fi
    return 0
}

# Simple validation functions
is_readable_file() { [[ -f "$1" && -r "$1" ]]; }
is_valid_json()    { jq empty "$1" 2>/dev/null; }
is_valid_path()    { [[ -n "$1" && "$1" != *$'\0'* ]]; }
is_valid_group()   { [[ "$1" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_-]*$ ]]; }
is_valid_perms()   { [[ "$1" =~ ^[rwxX-]{1,4}$ ]]; }
is_valid_mask()    { [[ "$1" =~ ^[rwx-]{1,3}$ ]]; }

# Complex validation functions
validate_definitions_file() {
    local -r file="${CONFIG[definitions_file]}"
    if [[ -z "$file" ]]; then
        log_error "No definitions file specified (use -f)"
        return 1
    fi

    if ! is_readable_file "$file"; then
        log_error "Cannot read definitions file '$file'"
        return 1
    fi
    if ! is_valid_json "$file"; then
        log_error "Invalid JSON in definitions file '$file'"
        return 1
    fi

    # Enforce presence of non-empty rules array (schema parity)
    if ! jq -e 'has("rules") and (.rules|type=="array") and ((.rules|length) > 0)' "$file" >/dev/null 2>&1; then
        log_error "Definitions file must contain non-empty 'rules' array"
        return 1
    fi

    # Version is optional; log if present
    local version
    version="$(jq -r '.version // "unknown"' "$file" 2>/dev/null || echo "unknown")"
    [[ "$version" != "null" ]] || version="unknown"
    log_info "Using definitions version: $version"
    return 0
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

# Portable PATH search that ignores shell hash/aliases/functions
program_in_path() {
    local -r cmd="$1"
    # Absolute or relative path with slash
    if [[ "$cmd" == */* ]]; then
        [[ -x "$cmd" ]] && return 0 || return 1
    fi
    local old_ifs="$IFS"
    IFS=':'
    local dir
    for dir in ${PATH:-}; do
        [[ -n "$dir" ]] || dir="."
        if [[ -x "$dir/$cmd" ]]; then
            IFS="$old_ifs"
            return 0
        fi
    done
    IFS="$old_ifs"
    return 1
}

# Robust command availability check that ignores current shell hash/aliases
is_command_resolvable() {
    local -r cmd="$1"
    # Use a clean environment with the current PATH only (non-login shell to avoid banners/MOTD)
    env -i PATH="$PATH" bash -c "command -v \"$cmd\" >/dev/null 2>&1"
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

# Returns success (0) if the given path either contains any target filter
# or is contained by any target filter. This ensures we don't skip a rule
# whose root is an ancestor of a requested target subtree.
path_intersects_any_filter() {
    local -r path="$1"
    [[ ${#target_paths[@]} -eq 0 ]] && return 0
    local filter
    for filter in "${target_paths[@]}"; do
        # path contains filter
        if [[ "$filter" == "$path" || "$filter" == "$path"/* ]]; then
            return 0
        fi
        # path is contained by filter
        if [[ "$path" == "$filter" || "$path" == "$filter"/* ]]; then
            return 0
        fi
    done
    return 1
}

# Pattern matching utilities
match_glob() {
    # Usage for internal engine: match_glob TEXT PATTERN CASE_SENSITIVE
    # Tests may call with extra args (match_base and multiple patterns). Support both forms.
    local text="$1" pattern="$2" case_sensitive="${3:-true}"
    local match_base="${4:-false}"
    shift 4 || true
    local additional_patterns=("$@")

    _glob_match_one() {
        local t="$1" p="$2" cs="$3"
        if [[ "$cs" == "true" ]]; then
            [[ "$t" == $p ]]
        else
            # Portable case-insensitive glob: downcase both using awk if available, else fallback
            if command -v awk >/dev/null 2>&1; then
                local lt lp
                lt=$(printf '%s' "$t" | awk '{print tolower($0)}')
                lp=$(printf '%s' "$p" | awk '{print tolower($0)}')
                shopt -s nocasematch
                [[ "$lt" == $lp ]]
                local r=$?
                shopt -u nocasematch
                return $r
            else
                shopt -s nocasematch
                [[ "$t" == $p ]]
                local r=$?
                shopt -u nocasematch
                return $r
            fi
        fi
    }

    local base
    base="$(basename -- "$text")"

    # Try primary pattern
    if [[ "$match_base" == "true" ]]; then
        _glob_match_one "$base" "$pattern" "$case_sensitive" || _glob_match_one "$text" "$pattern" "$case_sensitive" || {
            # try additional patterns
            for p in "${additional_patterns[@]}"; do
                _glob_match_one "$base" "$p" "$case_sensitive" || _glob_match_one "$text" "$p" "$case_sensitive" && return 0
            done
            return 1
        }
        return 0
    else
        _glob_match_one "$text" "$pattern" "$case_sensitive" || {
            for p in "${additional_patterns[@]}"; do
                _glob_match_one "$text" "$p" "$case_sensitive" && return 0
            done
            return 1
        }
        return 0
    fi
}

match_regex() {
    # Usage for internal engine: match_regex TEXT PATTERN CASE_SENSITIVE
    # Tests may call with extra args (match_base). Support both forms.
    local text="$1" pattern="$2" case_sensitive="${3:-true}" match_base="${4:-false}"

    local target="$text"
    if [[ "$match_base" == "true" ]]; then
        target="$(basename -- "$text")"
    fi

    if [[ "$case_sensitive" == "true" ]]; then
        [[ "$target" =~ $pattern ]]
        return $?
    else
        # Robust case-insensitive regex using awk IGNORECASE if available,
        # else fallback to grep -Ei, else best-effort lowercase target.
        if command -v awk >/dev/null 2>&1; then
            echo "$target" | awk -v pat="$pattern" 'BEGIN{IGNORECASE=1} $0 ~ pat {exit 0} {exit 1}'
            return $?
        elif command -v grep >/dev/null 2>&1; then
            echo "$target" | grep -Eiq -- "$pattern"
            return $?
        else
            local lower
            lower=$(printf '%s' "$target" | tr '[:upper:]' '[:lower:]')
            [[ "$lower" =~ $pattern ]]
            return $?
        fi
    fi
}

# Public helper used in tests: determine if a path matches include/exclude sets
filter_by_patterns() {
    # Args: full_path base_name pattern_syntax case_sensitive match_base [includes..] -- [excludes..]
    local full_path="$1"; shift
    local base_name="$1"; shift
    local syntax="$1"; shift
    local case_sensitive="$1"; shift
    local match_base="$1"; shift
    local includes=()
    local excludes=()
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--" ]]; then
            shift; break
        fi
        includes+=("$1"); shift
    done
    while [[ $# -gt 0 ]]; do
        excludes+=("$1"); shift
    done

    _matches_any() {
        local t_full="$1" t_base="$2"
        shift 2
        local -a patterns=("$@")
        local patt
        for patt in "${patterns[@]}"; do
            [[ -z "$patt" ]] && continue
            if [[ "$syntax" == "regex" ]]; then
                if [[ "$match_base" == "true" ]]; then
                    match_regex "$t_base" "$patt" "$case_sensitive" "true" || match_regex "$t_full" "$patt" "$case_sensitive" "false"
                else
                    match_regex "$t_full" "$patt" "$case_sensitive" "false"
                fi
            else
                if [[ "$match_base" == "true" ]]; then
                    match_glob "$t_base" "$patt" "$case_sensitive" "true" || match_glob "$t_full" "$patt" "$case_sensitive" "false"
                else
                    match_glob "$t_full" "$patt" "$case_sensitive" "false"
                fi
            fi
            [[ $? -eq 0 ]] && return 0
        done
        return 1
    }

    # Include default: match-all if none provided
    local include_ok=1
    if [[ ${#includes[@]} -gt 0 ]]; then
        include_ok=0
        if _matches_any "$full_path" "$base_name" "${includes[@]}"; then
            include_ok=1
        fi
    fi
    [[ $include_ok -eq 1 ]] || return 1

    # Exclude: any match rejects
    if [[ ${#excludes[@]} -gt 0 ]]; then
        if _matches_any "$full_path" "$base_name" "${excludes[@]}"; then
            return 1
        fi
    fi

    return 0
}

# Public helper used in tests: validate single ACL config tuple
validate_acl_config() {
    local group_name="$1" perms="$2" target_path="$3"
    # Validate group name and permissions presence
    [[ -n "$group_name" && "$group_name" != "null" ]] || return 1
    [[ -n "$perms" && "$perms" != "null" ]] || return 1
    is_valid_group "$group_name" || return 1
    is_valid_perms "$perms" || return 1
    # Warn if group does not exist (non-fatal)
    if command -v getent >/dev/null 2>&1; then
        if ! getent group "$group_name" >/dev/null 2>&1; then
            log_warning "Group not found on system: $group_name"
        fi
    fi
    # Path is optional in this unit check
    return 0
}

# Depth and ordering utilities
compute_relative_depth() {
    local -r root="$1" path="$2"
    local rel="${path#$root}"
    [[ "$rel" == "$path" ]] && rel="$path"
    rel="${rel#/}"
    local depth=0
    if [[ -n "$rel" ]]; then
        local only_slashes="${rel//[^\//]/}"
        depth=$(( ${#only_slashes} + 1 ))
    fi
    echo "$depth"
}

sort_paths_by_apply_order() {
    local -r order="$1" root="$2"; shift 2
    local -a arr=("$@")
    if [[ ${#arr[@]} -eq 0 ]]; then
        return 0
    fi
    local tmp
    while IFS= read -r line; do
        echo "$line"
    done < <(
        for p in "${arr[@]}"; do
            local d
            d=$(compute_relative_depth "$root" "$p")
            printf '%06d\t%s\n' "$d" "$p"
        done | {
            if [[ "$order" == "deep_to_shallow" ]]; then
                sort -t $'\t' -k1,1nr
            else
                sort -t $'\t' -k1,1n
            fi
        } | cut -f2-
    )
}

# Rule path matching against include/exclude according to schema
path_matches_rule_filters() {
    local -r rule_idx="$1" path="$2"
    local params includes excludes
    params=$(get_rule_params "$rule_idx")
    includes=$(get_rule_data "$rule_idx" "includes")
    excludes=$(get_rule_data "$rule_idx" "excludes")

    # Parse params fields: include_root, depth, types_csv, pattern_syntax, match_base, case_sensitive
    local _include_root _depth _types_csv pattern_syntax match_base case_sensitive
    IFS=$'\t' read -r _include_root _depth _types_csv pattern_syntax match_base case_sensitive <<< "$params"

    # Defaults
    [[ -n "$pattern_syntax" ]] || pattern_syntax="glob"
    [[ -n "$match_base" ]] || match_base="true"
    [[ -n "$case_sensitive" ]] || case_sensitive="true"

    local target_full="$path"
    local target_base
    target_base="$(basename -- "$path")"

    # Helper: check one pattern against target based on syntax and flags
    _pattern_matches() {
        local -r patt="$1"
        if [[ "$pattern_syntax" == "regex" ]]; then
            if [[ "$match_base" == "true" ]]; then
                match_regex "$target_base" "$patt" "$case_sensitive" || match_regex "$target_full" "$patt" "$case_sensitive"
            else
                match_regex "$target_full" "$patt" "$case_sensitive"
            fi
        else
            if [[ "$match_base" == "true" ]]; then
                match_glob "$target_base" "$patt" "$case_sensitive" || match_glob "$target_full" "$patt" "$case_sensitive"
            else
                match_glob "$target_full" "$patt" "$case_sensitive"
            fi
        fi
    }

    # Includes: if none provided, default to match-all (schema default **/*)
    local include_ok=0
    if [[ -z "$includes" ]]; then
        include_ok=1
    else
        while IFS= read -r inc; do
            [[ -z "$inc" ]] && continue
            if _pattern_matches "$inc"; then
                include_ok=1
                break
            fi
        done <<< "$includes"
    fi
    [[ $include_ok -eq 1 ]] || return 1

    # Excludes: any match rejects
    if [[ -n "$excludes" ]]; then
        while IFS= read -r exc; do
            [[ -z "$exc" ]] && continue
            if _pattern_matches "$exc"; then
                return 1
            fi
        done <<< "$excludes"
    fi

    return 0
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

    # Run command without leaking output to stdout. Capture stderr for logging.
    local cmd_stderr=""
    if cmd_stderr=$("${cmd_args[@]}" 2>&1 1>/dev/null); then
        RUNTIME_STATE[entries_attempted]=$((${RUNTIME_STATE[entries_attempted]} + ${#specs[@]}))
        return 0
    else
        RUNTIME_STATE[entries_failed]=$((${RUNTIME_STATE[entries_failed]} + ${#specs[@]}))
        [[ -n "$cmd_stderr" ]] && log_error "setfacl failed for $path: $cmd_stderr"
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

    # Run command without leaking output to stdout. Capture stderr for logging.
    local cmd_stderr=""
    if cmd_stderr=$("${final_args[@]}" 2>&1 1>/dev/null); then
        RUNTIME_STATE[entries_attempted]=$((${RUNTIME_STATE[entries_attempted]} + ${#specs[@]}))
        return 0
    else
        RUNTIME_STATE[entries_failed]=$((${RUNTIME_STATE[entries_failed]} + ${#specs[@]}))
        [[ -n "$cmd_stderr" ]] && log_error "setfacl -R failed for $path: $cmd_stderr"
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

    # If user provided target path filters, avoid -R; we need per-path filtering
    if [[ ${#target_paths[@]} -gt 0 ]]; then
        return 1
    fi

    # Get rule parameters
    local params
    params=$(get_rule_params "$rule_idx")
    [[ -n "$params" ]] || return 1

    # New params layout: include_root, depth, types_csv, pattern_syntax, match_base, case_sensitive
    local include_root depth types_csv pattern_syntax match_base case_sensitive
    IFS=$'\t' read -r include_root depth types_csv pattern_syntax match_base case_sensitive <<< "$params"

    # New semantics: can use -R only if depth is infinite and include_root is true
    # include_root and depth were parsed above into variables
    [[ "$include_root" == "true" ]] || return 1
    [[ "$depth" == "infinite" ]] || return 1

    # Must target both files and directories; -R cannot filter by type
    local want_files=0 want_dirs=0
    if [[ -z "$types_csv" || "$types_csv" == "," ]]; then
        want_files=1; want_dirs=1
    else
        [[ ",${types_csv}," == *,file,* ]] && want_files=1
        [[ ",${types_csv}," == *,directory,* ]] && want_dirs=1
    fi
    [[ $want_files -eq 1 && $want_dirs -eq 1 ]] || return 1

    # Check for include/exclude patterns
    local includes excludes
    includes=$(get_rule_data "$rule_idx" "includes")
    excludes=$(get_rule_data "$rule_idx" "excludes")

    # If we have any patterns, can't use optimization
    [[ -z "$includes" && -z "$excludes" ]] || return 1

    # No global depth overrides anymore

    # Require identical file and directory specs to safely use -R
    local file_specs_data dir_specs_data
    file_specs_data=$(get_rule_data "$rule_idx" "file_specs")
    dir_specs_data=$(get_rule_data "$rule_idx" "dir_specs")
    # If either list is empty or they differ, avoid -R
    if [[ -z "$file_specs_data" || -z "$dir_specs_data" ]]; then
        return 1
    fi
    local f_hash d_hash
    f_hash=$(printf '%s\n' "$file_specs_data" | sort -u | tr -d '\n' | sha1sum 2>/dev/null | awk '{print $1}')
    d_hash=$(printf '%s\n' "$dir_specs_data" | sort -u | tr -d '\n' | sha1sum 2>/dev/null | awk '{print $1}')
    [[ -n "$f_hash" && -n "$d_hash" && "$f_hash" == "$d_hash" ]] || return 1

    return 0
}

# Simplified path enumeration for recursive rules
enumerate_paths_simple() {
    # Args (new semantics): include_root depth types_csv pattern_syntax match_base case_sensitive  -- roots...
    # We only need include_root and depth here; other params are parsed elsewhere for filtering.
    local -r include_root="$1" depth_raw="$2"; shift 2
    local -a roots=("$@")

    for root in "${roots[@]}"; do
        [[ -e "$root" ]] || continue

        if [[ "$include_root" == "true" ]]; then
            echo "$root"
        fi

        if [[ -d "$root" ]]; then
            # Determine effective numeric depth
            local -a find_args=("$root")
            local eff_depth=""
            if [[ "$depth_raw" == "infinite" ]]; then
                eff_depth=""
            elif [[ "$depth_raw" =~ ^[0-9]+$ ]]; then
                if [[ "$depth_raw" -eq 0 ]]; then
                    eff_depth="0"
                else
                    eff_depth="$depth_raw"
                fi
            else
                eff_depth=""
            fi

            if [[ "$eff_depth" == "0" ]]; then
                : # root already emitted if include_root=true; no descendants
            else
                # mindepth 1 to skip the root; maxdepth only when finite
                find_args+=( -mindepth 1 )
                if [[ -n "$eff_depth" ]]; then
                    find_args+=( -maxdepth "$eff_depth" )
                fi
                if [[ "${CONFIG[find_optimization]}" == "true" ]]; then
                    find_args+=( \( -type f -o -type d \) )
                fi
                find "${find_args[@]}" 2>/dev/null || true
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

    # New params layout: include_root, depth, types_csv, pattern_syntax, match_base, case_sensitive
    local include_root depth types_csv pattern_syntax match_base case_sensitive
    IFS=$'\t' read -r include_root depth types_csv pattern_syntax match_base case_sensitive <<< "$params"

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
        RUNTIME_STATE[total_skipped]=$((${RUNTIME_STATE[total_skipped]} + 1))
        # Collect rule summary for JSON output
        if [[ "${CONFIG[output_format]}" == "json" ]]; then
            add_rule_summary "$rule_idx" "skipped" "No valid roots found"
        fi
        return $RETURN_SKIPPED
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

        # Short-circuit root if it doesn't intersect requested targets
        if ! path_intersects_any_filter "$root"; then
            RUNTIME_STATE[total_skipped]=$((${RUNTIME_STATE[total_skipped]} + 1))
            continue
        fi

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
                mapfile -t paths < <(enumerate_paths_simple "$include_root" "$depth" "$root")
                # Order paths by apply_order for deterministic override behavior
                local -a ordered_paths=()
                while IFS= read -r p; do ordered_paths+=("$p"); done < <(sort_paths_by_apply_order "$(cache_get rules "apply_order")" "$root" "${paths[@]}")
                local file_count=0
                for path in "${ordered_paths[@]}"; do
                    # Ensure root is excluded when include_root is false
                    if [[ "$include_root" != "true" && "$path" == "$root" ]]; then
                        continue
                    fi
                    if ! path_under_any_filter "$path"; then
                        RUNTIME_STATE[total_skipped]=$((${RUNTIME_STATE[total_skipped]} + 1))
                        continue
                    fi
                    if ! path_matches_rule_filters "$rule_idx" "$path"; then
                        RUNTIME_STATE[total_skipped]=$((${RUNTIME_STATE[total_skipped]} + 1))
                        continue
                    fi
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
                for path in "${ordered_paths[@]}"; do
                    # Ensure root is excluded when include_root is false
                    if [[ "$include_root" != "true" && "$path" == "$root" ]]; then
                        continue
                    fi
                    if ! path_under_any_filter "$path"; then
                        RUNTIME_STATE[total_skipped]=$((${RUNTIME_STATE[total_skipped]} + 1))
                        continue
                    fi
                    if ! path_matches_rule_filters "$rule_idx" "$path"; then
                        RUNTIME_STATE[total_skipped]=$((${RUNTIME_STATE[total_skipped]} + 1))
                        continue
                    fi
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
                mapfile -t paths < <(enumerate_paths_simple "$include_root" "$depth" "$root")
                local -a ordered_paths=()
                while IFS= read -r p; do ordered_paths+=("$p"); done < <(sort_paths_by_apply_order "$(cache_get rules "apply_order")" "$root" "${paths[@]}")
                local dir_count=0
                for path in "${ordered_paths[@]}"; do
                    if ! path_under_any_filter "$path"; then
                        RUNTIME_STATE[total_skipped]=$((${RUNTIME_STATE[total_skipped]} + 1))
                        continue
                    fi
                    if ! path_matches_rule_filters "$rule_idx" "$path"; then
                        RUNTIME_STATE[total_skipped]=$((${RUNTIME_STATE[total_skipped]} + 1))
                        continue
                    fi
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
                for path in "${ordered_paths[@]}"; do
                    if ! path_under_any_filter "$path"; then
                        RUNTIME_STATE[total_skipped]=$((${RUNTIME_STATE[total_skipped]} + 1))
                        continue
                    fi
                    if ! path_matches_rule_filters "$rule_idx" "$path"; then
                        RUNTIME_STATE[total_skipped]=$((${RUNTIME_STATE[total_skipped]} + 1))
                        continue
                    fi
                    local path_type
                    path_type=$(get_path_type "$path")
                    [[ "$path_type" == "directory" ]] || continue
                    if ! apply_acl_strategy "individual" "$path" "false" "${dir_specs[@]}"; then
                        root_failed=1
                    fi
                done
            fi
        fi

        # Apply default specs to directories, but only if directories are targeted by types
        if [[ ${#def_specs[@]} -gt 0 && $want_dirs -eq 1 ]]; then
            local -a paths
            log_progress "Enumerating paths for default ACL processing..."
            mapfile -t paths < <(enumerate_paths_simple "$include_root" "$depth" "$root")
            local -a ordered_paths=()
            while IFS= read -r p; do ordered_paths+=("$p"); done < <(sort_paths_by_apply_order "$(cache_get rules "apply_order")" "$root" "${paths[@]}")
            local default_dir_count=0
            for path in "${ordered_paths[@]}"; do
                # Ensure root is excluded when include_root is false
                if [[ "$include_root" != "true" && "$path" == "$root" ]]; then
                    continue
                fi
                if ! path_under_any_filter "$path"; then
                    RUNTIME_STATE[total_skipped]=$((${RUNTIME_STATE[total_skipped]} + 1))
                    continue
                fi
                if ! path_matches_rule_filters "$rule_idx" "$path"; then
                    RUNTIME_STATE[total_skipped]=$((${RUNTIME_STATE[total_skipped]} + 1))
                    continue
                fi
                [[ -d "$path" ]] || continue
                ((default_dir_count++))
            done
            if [[ $default_dir_count -gt 0 ]]; then
                log_progress "Processing default ACLs for $default_dir_count directories individually..."
            fi

            # Reset bulk operations counter for this section
            RUNTIME_STATE[bulk_operations]=0
            for path in "${ordered_paths[@]}"; do
                if ! path_under_any_filter "$path"; then
                    RUNTIME_STATE[total_skipped]=$((${RUNTIME_STATE[total_skipped]} + 1))
                    continue
                fi
                if ! path_matches_rule_filters "$rule_idx" "$path"; then
                    RUNTIME_STATE[total_skipped]=$((${RUNTIME_STATE[total_skipped]} + 1))
                    continue
                fi
                [[ -d "$path" ]] || continue
                if ! apply_acl_strategy "individual" "$path" "true" "${def_specs[@]}"; then
                    root_failed=1
                fi
            done
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

    # Collect rule summary for JSON output
    if [[ "${CONFIG[output_format]}" == "json" ]]; then
        if [[ $rule_failed -eq 0 ]]; then
            add_rule_summary "$rule_idx" "success" "Rule applied successfully to ${#valid_roots[@]} root(s)"
        else
            add_rule_summary "$rule_idx" "failed" "Rule failed for some paths"
        fi
    fi

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

set_output_format() {
    local -r format="$1"
    case "$format" in
        text|json|jsonl)
            CONFIG[output_format]="$format"
            ;;
        *)
            fail "$EXIT_INVALID_ARGS" "Invalid output format '$format' (use text, json, or jsonl)"
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
            -o|--output-format|--output-format=*)
                local value
                value="$(get_option_value "$1" "${2:-}")"
                set_output_format "$value"
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
  -o, --output-format FORMAT  Output format: text|json|jsonl (default: text)
  
  --dry-run           Simulate without making changes
  -q, --quiet         Suppress informational output (errors still shown)

Performance Options:
  --no-find-optimization     Disable find command optimizations
  --no-recursive-optimization Disable direct setfacl -R optimization

  -h, --help          Show this help message

Examples:
  # Apply all rules in config
  engine.sh -f rules.json

  # Get JSON output summary
  engine.sh -f rules.json --output-format json

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

# =============================================================================
# JSON OUTPUT GENERATION
# =============================================================================

generate_json_config() {
    cat << EOF
  "config": {
    "definitions_file": "${CONFIG[definitions_file]}",
    "color_mode": "${CONFIG[color_mode]}",
    "mask_setting": "${CONFIG[mask_setting]}",
    "mask_explicit": "${CONFIG[mask_explicit]}",
    "dry_run": ${CONFIG[dry_run]},
    "quiet": ${CONFIG[quiet]},
    "find_optimization": ${CONFIG[find_optimization]},
    "recursive_optimization": ${CONFIG[recursive_optimization]},
    "output_format": "${CONFIG[output_format]}"
  }
EOF
}

# Format a Unix timestamp as ISO 8601, with fallbacks for portability
format_timestamp() {
    local ts="$1"
    if [[ -z "$ts" ]]; then
        echo ""
        return
    fi
    date -d "@$ts" -Iseconds 2>/dev/null || date -r "$ts" -Iseconds 2>/dev/null || echo "$ts"
}

generate_json_run_metadata() {
    local exit_code="$1"
    local duration_ms=""
    local timestamp_iso=""

    if [[ -n "${RUNTIME_STATE[start_time]}" ]]; then
        timestamp_iso=$(format_timestamp $((${RUNTIME_STATE[start_time]} / 1000)))
    fi

    if [[ -n "${RUNTIME_STATE[start_time]}" && -n "${RUNTIME_STATE[end_time]}" ]]; then
        duration_ms=$(( ${RUNTIME_STATE[end_time]} - ${RUNTIME_STATE[start_time]} ))
    fi

    cat << EOF
  "run": {
    "timestamp": "$timestamp_iso",
    "duration_ms": ${duration_ms:-0},
    "exit_code": $exit_code,
    "mode": "$(if [[ "${CONFIG[dry_run]}" == "true" ]]; then echo "dry_run"; else echo "apply"; fi)"
  }
EOF
}

generate_json_metrics() {
    local entries_ok=$((${RUNTIME_STATE[entries_attempted]} - ${RUNTIME_STATE[entries_failed]}))
    local success_pct=100
    if [[ ${RUNTIME_STATE[entries_attempted]} -gt 0 ]]; then
        success_pct=$(( entries_ok * 100 / ${RUNTIME_STATE[entries_attempted]} ))
    fi

    cat << EOF
  "metrics": {
    "paths": {
      "applied": ${RUNTIME_STATE[total_applied]},
      "failed": ${RUNTIME_STATE[total_failed]},
      "skipped": ${RUNTIME_STATE[total_skipped]}
    },
    "entries": {
      "ok": $entries_ok,
      "failed": ${RUNTIME_STATE[entries_failed]},
      "attempted": ${RUNTIME_STATE[entries_attempted]},
      "success_percentage": $success_pct
    },
    "performance": {
      "cache_hits": ${RUNTIME_STATE[cache_hits]},
      "optimized_rules": ${RUNTIME_STATE[optimized_rules]}
    }
  }
EOF
}

generate_json_warnings_errors() {
    cat << EOF
  "warnings": [${JSON_OUTPUT[warnings]:-}],
  "errors": [${JSON_OUTPUT[errors]:-}]
EOF
}

generate_json_output() {
    local exit_code="$1"
    cat << EOF
{
$(generate_json_run_metadata "$exit_code"),
$(generate_json_config),
$(generate_json_metrics),
  "rules": [${JSON_OUTPUT[rule_summaries]}],
$(generate_json_warnings_errors)
}
EOF
}

# JSON Lines output (one JSON object per line)
generate_jsonl_output() {
    local exit_code="$1"
    # Run metadata
    local duration_ms="" timestamp_iso="" mode="apply"
    if [[ -n "${RUNTIME_STATE[start_time]}" && -n "${RUNTIME_STATE[end_time]}" ]]; then
        duration_ms=$(( ${RUNTIME_STATE[end_time]} - ${RUNTIME_STATE[start_time]} ))
    else
        duration_ms=0
    fi
    if [[ -n "${RUNTIME_STATE[start_time]}" ]]; then
        timestamp_iso=$(format_timestamp $((${RUNTIME_STATE[start_time]} / 1000)))
    fi
    if [[ "${CONFIG[dry_run]}" == "true" ]]; then mode="dry_run"; fi
    printf '{"type":"run","timestamp":"%s","duration_ms":%s,"exit_code":%s,"mode":"%s"}\n' \
        "$timestamp_iso" "$duration_ms" "$exit_code" "$mode"

    # Config
    printf '{"type":"config","definitions_file":"%s","color_mode":"%s","mask_setting":"%s","mask_explicit":"%s","dry_run":%s,"quiet":%s,"find_optimization":%s,"recursive_optimization":%s,"output_format":"%s"}\n' \
        "${CONFIG[definitions_file]}" "${CONFIG[color_mode]}" "${CONFIG[mask_setting]}" "${CONFIG[mask_explicit]}" \
        "${CONFIG[dry_run]}" "${CONFIG[quiet]}" "${CONFIG[find_optimization]}" "${CONFIG[recursive_optimization]}" "${CONFIG[output_format]}"

    # Metrics
    local entries_ok=$((${RUNTIME_STATE[entries_attempted]} - ${RUNTIME_STATE[entries_failed]}))
    local success_pct=100
    if [[ ${RUNTIME_STATE[entries_attempted]} -gt 0 ]]; then
        success_pct=$(( entries_ok * 100 / ${RUNTIME_STATE[entries_attempted]} ))
    fi
    printf '{"type":"metrics","paths":{"applied":%s,"failed":%s,"skipped":%s},"entries":{"ok":%s,"failed":%s,"attempted":%s,"success_percentage":%s},"performance":{"cache_hits":%s,"optimized_rules":%s}}\n' \
        "${RUNTIME_STATE[total_applied]}" "${RUNTIME_STATE[total_failed]}" "${RUNTIME_STATE[total_skipped]}" \
        "$entries_ok" "${RUNTIME_STATE[entries_failed]}" "${RUNTIME_STATE[entries_attempted]}" "$success_pct" \
        "${RUNTIME_STATE[cache_hits]}" "${RUNTIME_STATE[optimized_rules]}"

    # Rules (stream each summary as a line)
    if [[ -n "${JSON_OUTPUT[rule_summaries]}" ]]; then
        printf '[%s]' "${JSON_OUTPUT[rule_summaries]}" | jq -rc '.[] | {type:"rule"} + .'
    fi

    # Warnings and errors
    if [[ -n "${JSON_OUTPUT[warnings]}" ]]; then
        # Messages in JSON_OUTPUT are already JSON-escaped strings; decode before embedding
        printf '[%s]' "${JSON_OUTPUT[warnings]}" | jq -rc '.[] | {type:"warning", message: fromjson}'
    fi
    if [[ -n "${JSON_OUTPUT[errors]}" ]]; then
        # Messages in JSON_OUTPUT are already JSON-escaped strings; decode before embedding
        printf '[%s]' "${JSON_OUTPUT[errors]}" | jq -rc '.[] | {type:"error", message: fromjson}'
    fi
}

main() {
    RUNTIME_STATE[start_time]=$(date +%s%3N)
    # Defensive reset: ensure no stale data if main is invoked multiple times
    JSON_OUTPUT[warnings]=""
    JSON_OUTPUT[errors]=""
    JSON_OUTPUT[rule_summaries]=""
    RUNTIME_STATE[entries_attempted]=0
    RUNTIME_STATE[entries_failed]=0
    RUNTIME_STATE[cache_hits]=0
    RUNTIME_STATE[optimized_rules]=0
    RUNTIME_STATE[total_applied]=0
    RUNTIME_STATE[total_failed]=0
    RUNTIME_STATE[total_skipped]=0
    RUNTIME_STATE[bulk_operations]=0
    parse_arguments "$@"
    initialize
    determine_target_paths

    log_bold "ACL definitions from: ${CONFIG[definitions_file]}"

    local exit_code="$EXIT_SUCCESS"
    if ! apply_all_rules; then
        exit_code="$EXIT_ERROR"
    fi

    RUNTIME_STATE[end_time]=$(date +%s%3N)

    # Generate output based on format
    case "${CONFIG[output_format]}" in
        json)
            generate_json_output "$exit_code" ;;
        jsonl)
            generate_jsonl_output "$exit_code" ;;
    esac

    exit "$exit_code"
}

# Entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi