#!/usr/bin/env bash
# config.sh - INI-like config parser for syshammer

# Config is stored in a flat kv file after parsing.
# Sections map to dotted prefixes:
#   [global]       -> global.<key>
#   [module_defaults] -> module_defaults.<key>
#   [plan]         -> plan.<key>
#   [stage.<name>] -> stage.<name>.<key>
#   [module.<name>] -> module.<name>.<key>

# Global config file path (set after parsing)
_CONFIG_FILE=""
_CONFIG_KV_FILE=""

# Parse INI config file into a flat kv file.
# Usage: config_parse <ini_file> <output_kv_file>
config_parse() {
    local ini_file="$1" out_file="$2"
    _CONFIG_FILE="$ini_file"
    _CONFIG_KV_FILE="$out_file"

    if [[ ! -f "$ini_file" ]]; then
        log_error "Config file not found: $ini_file"
        return 1
    fi

    : > "$out_file"

    local section=""
    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Strip leading/trailing whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        # Skip empty lines and comments
        [[ -z "$line" || "$line" == "#"* || "$line" == ";"* ]] && continue || true

        # Section header
        if [[ "$line" == "["*"]" ]]; then
            section="${line#[}"
            section="${section%]}"
            # Strip whitespace from section name
            section="${section#"${section%%[![:space:]]*}"}"
            section="${section%"${section##*[![:space:]]}"}"
            continue
        fi

        # Key=value pair
        if [[ "$line" == *"="* ]]; then
            key="${line%%=*}"
            value="${line#*=}"
            # Strip whitespace
            key="${key#"${key%%[![:space:]]*}"}"
            key="${key%"${key##*[![:space:]]}"}"
            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%"${value##*[![:space:]]}"}"

            if [[ -n "$section" ]]; then
                # Replace dots in section with dots (section already has dots for stage.X, module.X)
                printf '%s.%s=%s\n' "$section" "$key" "$value" >> "$out_file"
            else
                printf '%s=%s\n' "$key" "$value" >> "$out_file"
            fi
        fi
    done < "$ini_file"
}

# Get config value with optional default.
# Usage: config_get <key> [default]
config_get() {
    local key="$1" default="${2:-}"
    if [[ -z "$_CONFIG_KV_FILE" || ! -f "$_CONFIG_KV_FILE" ]]; then
        printf '%s' "$default"
        return 0
    fi
    kv_read "$_CONFIG_KV_FILE" "$key" "$default"
}

# Apply CLI overrides to the parsed config.
# Usage: config_apply_overrides <kv_file> [key=value ...]
config_apply_overrides() {
    local kv_file="$1"; shift
    _CONFIG_KV_FILE="$kv_file"
    local override
    for override in "$@"; do
        local key="${override%%=*}"
        local value="${override#*=}"
        kv_write "$kv_file" "$key" "$value"
    done
}

# List all config keys matching a prefix.
# Usage: config_keys_with_prefix <prefix>
config_keys_with_prefix() {
    local prefix="$1"
    if [[ -f "$_CONFIG_KV_FILE" ]]; then
        grep "^${prefix}" "$_CONFIG_KV_FILE" 2>/dev/null | while IFS='=' read -r key _; do
            printf '%s\n' "$key"
        done
    fi
}
