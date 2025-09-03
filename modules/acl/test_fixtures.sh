#!/bin/bash
#
# test_fixtures.sh - Test data and fixtures for ACL engine tests
#

# Prevent multiple sourcing
if [[ "${TEST_FIXTURES_LOADED:-}" == "true" ]]; then
    return 0
fi
readonly TEST_FIXTURES_LOADED="true"

# Valid JSON configurations for testing

# Minimal valid configuration
MINIMAL_CONFIG='{
  "rules": [
    {
      "roots": "/tmp/test",
      "acl": ["g:testgroup:rwx"]
    }
  ]
}'

# Complete configuration with all features
COMPLETE_CONFIG='{
  "version": "1.0",
  "apply_order": "shallow_to_deep",
  "rules": [
    {
      "id": "test-rule-1",
      "description": "Test rule with all features",
      "roots": ["/tmp/test1", "/tmp/test2"],
      "recurse": true,
      "include_self": true,
      "match": {
        "types": ["file", "directory"],
        "pattern_syntax": "glob",
        "include": ["**/*"],
        "exclude": ["*.tmp", ".git/**"],
        "match_base": true,
        "case_sensitive": true
      },
      "acl": {
        "files": [
          {"kind": "group", "name": "developers", "mode": "rw-"},
          {"kind": "other", "mode": "r--"}
        ],
        "directories": [
          {"kind": "group", "name": "developers", "mode": "rwx"},
          {"kind": "other", "mode": "r-x"}
        ]
      },
      "default_acl": [
        {"kind": "group", "name": "developers", "mode": "rwx"},
        {"kind": "mask", "mode": "rwx"}
      ]
    },
    {
      "id": "test-rule-2",
      "description": "Test rule with string ACL format",
      "roots": "/tmp/test3",
      "recurse": false,
      "acl": [
        "g:testgroup:rwx",
        "u:testuser:rw-",
        "o::r--"
      ]
    }
  ]
}'

# Configuration with regex patterns
REGEX_CONFIG='{
  "rules": [
    {
      "roots": "/tmp/test",
      "match": {
        "pattern_syntax": "regex",
        "include": ["\\.(txt|log)$"],
        "exclude": ["temp_.*"]
      },
      "acl": ["g:testgroup:rw-"]
    }
  ]
}'

# Configuration with deep_to_shallow order
DEEP_TO_SHALLOW_CONFIG='{
  "apply_order": "deep_to_shallow",
  "rules": [
    {
      "roots": "/tmp/test",
      "recurse": true,
      "acl": ["g:testgroup:rwx"]
    }
  ]
}'

# Invalid JSON configurations for error testing

# Missing required field
INVALID_NO_RULES='{
  "version": "1.0"
}'

# Empty rules array
INVALID_EMPTY_RULES='{
  "rules": []
}'

# Missing required ACL field
INVALID_NO_ACL='{
  "rules": [
    {
      "roots": "/tmp/test"
    }
  ]
}'

# Invalid JSON syntax
INVALID_JSON_SYNTAX='{
  "rules": [
    {
      "roots": "/tmp/test",
      "acl": ["g:test:rwx"]
    }
  ]
  // missing comma
  "invalid": true
}'

# Invalid ACL entry kind
INVALID_ACL_KIND='{
  "rules": [
    {
      "roots": "/tmp/test",
      "acl": [
        {"kind": "invalid_kind", "name": "test", "mode": "rwx"}
      ]
    }
  ]
}'

# User ACL without name
INVALID_USER_NO_NAME='{
  "rules": [
    {
      "roots": "/tmp/test",
      "acl": [
        {"kind": "user", "mode": "rwx"}
      ]
    }
  ]
}'

# Owner ACL with name (not allowed)
INVALID_OWNER_WITH_NAME='{
  "rules": [
    {
      "roots": "/tmp/test",
      "acl": [
        {"kind": "owner", "name": "test", "mode": "rwx"}
      ]
    }
  ]
}'

# Invalid permission mode
INVALID_PERMISSION_MODE='{
  "rules": [
    {
      "roots": "/tmp/test",
      "acl": [
        {"kind": "group", "name": "test", "mode": "invalid"}
      ]
    }
  ]
}'

# Test filesystem structure creation
create_test_filesystem() {
    local base_dir="${1:-/tmp/acl_test}"
    
    # Create directory structure
    mkdir -p "$base_dir"/{app,data,logs}
    mkdir -p "$base_dir"/app/{src,config,bin}
    mkdir -p "$base_dir"/data/{input,output,temp}
    
    # Create test files
    touch "$base_dir"/app/src/{main.py,utils.py,test.py}
    touch "$base_dir"/app/config/{app.conf,db.json,secrets.yaml}
    touch "$base_dir"/app/bin/{start.sh,stop.sh}
    touch "$base_dir"/data/input/{data1.txt,data2.csv}
    touch "$base_dir"/data/output/{result1.json,result2.xml}
    touch "$base_dir"/data/temp/{temp1.tmp,temp2.log}
    touch "$base_dir"/logs/{app.log,error.log,debug.log}
    
    # Create .git directory for exclusion testing
    mkdir -p "$base_dir"/.git/objects
    touch "$base_dir"/.git/{config,HEAD}
    
    echo "$base_dir"
}

# Mock group data for testing
create_mock_groups() {
    # Create a mock getent script that simulates group existence
    cat > getent << 'EOF'
#!/bin/bash
case "$1" in
    group)
        case "$2" in
            developers|testgroup|webapp|editors|devs)
                echo "$2:x:1000:"
                exit 0
                ;;
            *)
                exit 2
                ;;
        esac
        ;;
    *)
        exit 1
        ;;
esac
EOF
    chmod +x getent
    export PATH="$PWD:$PATH"
}

# Test configuration writers
write_config() {
    local config_var="$1"
    local filename="${2:-test_config.json}"
    echo "${!config_var}" > "$filename"
    echo "$PWD/$filename"
}

write_minimal_config() {
    write_config "MINIMAL_CONFIG" "${1:-minimal.json}"
}

write_complete_config() {
    write_config "COMPLETE_CONFIG" "${1:-complete.json}"
}

write_regex_config() {
    write_config "REGEX_CONFIG" "${1:-regex.json}"
}

write_deep_to_shallow_config() {
    write_config "DEEP_TO_SHALLOW_CONFIG" "${1:-deep_to_shallow.json}"
}

write_invalid_config() {
    local config_type="$1"
    local filename="${2:-invalid.json}"
    case "$config_type" in
        no_rules) write_config "INVALID_NO_RULES" "$filename" ;;
        empty_rules) write_config "INVALID_EMPTY_RULES" "$filename" ;;
        no_acl) write_config "INVALID_NO_ACL" "$filename" ;;
        json_syntax) write_config "INVALID_JSON_SYNTAX" "$filename" ;;
        acl_kind) write_config "INVALID_ACL_KIND" "$filename" ;;
        user_no_name) write_config "INVALID_USER_NO_NAME" "$filename" ;;
        owner_with_name) write_config "INVALID_OWNER_WITH_NAME" "$filename" ;;
        permission_mode) write_config "INVALID_PERMISSION_MODE" "$filename" ;;
        *) echo "Unknown invalid config type: $config_type" >&2; return 1 ;;
    esac
}

# Test data for pattern matching
declare -a GLOB_TEST_PATTERNS=(
    "*.txt"
    "**/*.py"
    "config/*"
    "temp_*"
    ".git/**"
)

declare -a REGEX_TEST_PATTERNS=(
    "\\.(txt|log)$"
    "^config_.*\\.json$"
    "temp_.*"
    "\\.git/"
)

declare -a TEST_FILENAMES=(
    "test.txt"
    "app/main.py"
    "config/app.conf"
    "temp_file.dat"
    ".git/config"
    "data.csv"
    "config_prod.json"
    "temp_123.log"
)

# Expected results for pattern tests
declare -A GLOB_MATCHES=(
    ["*.txt,test.txt"]="match"
    ["*.txt,app/main.py"]="no_match"
    ["**/*.py,app/main.py"]="match"
    ["config/*,config/app.conf"]="match"
    ["temp_*,temp_file.dat"]="match"
    [".git/**,.git/config"]="match"
)

declare -A REGEX_MATCHES=(
    ["\\.(txt|log)$,test.txt"]="match"
    ["\\.(txt|log)$,temp_123.log"]="match"
    ["\\.(txt|log)$,app/main.py"]="no_match"
    ["^config_.*\\.json$,config_prod.json"]="match"
    ["temp_.*,temp_file.dat"]="match"
    ["\\.git/,.git/config"]="match"
)

# Permission mode test data
declare -a VALID_MODES=("rwx" "rw-" "r-x" "r--" "---" "rwX" "r-X")
declare -a INVALID_MODES=("rwz" "xyz" "rwxw" "" "rw" "rwxx" "invalid")

# Group name test data
declare -a VALID_GROUPS=("developers" "dev_team" "app-users" "test123" "_group")
declare -a INVALID_GROUPS=("123group" "-invalid" "group with spaces" "group/slash" "")

# Test helper functions
get_expected_match() {
    local pattern="$1"
    local filename="$2"
    local match_type="$3"  # "glob" or "regex"
    
    local key="${pattern},${filename}"
    if [[ "$match_type" == "glob" ]]; then
        echo "${GLOB_MATCHES[$key]:-no_match}"
    else
        echo "${REGEX_MATCHES[$key]:-no_match}"
    fi
}
