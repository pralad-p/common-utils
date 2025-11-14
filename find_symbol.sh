#!/bin/bash

# Symbol finder with dependency chain tracking
# Usage: ./find_symbol.sh <library_path> <symbol_pattern>

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Check arguments
if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <library_path> <symbol_pattern>"
  echo "Example: $0 /usr/lib/libexample.so 'pthread_create'"
  exit 1
fi

LIBRARY="$1"
SYMBOL_PATTERN="$2"

# Check if required tools are installed
for cmd in nm ldd rg; do
  if ! command -v $cmd &>/dev/null; then
    echo "Error: $cmd is not installed"
    exit 1
  fi
done

# Associative arrays to track visited libraries and their paths
declare -A visited
declare -A lib_full_paths
declare -A symbol_found_in

# Function to resolve library path
resolve_lib_path() {
  local lib="$1"

  # If it's already a full path, use it
  if [[ "$lib" == /* ]]; then
    echo "$lib"
    return
  fi

  # Try to find it using ldconfig
  local full_path=$(ldconfig -p 2>/dev/null | grep -E "^\s*$lib " | awk '{print $NF}' | head -1)
  if [ -n "$full_path" ]; then
    echo "$full_path"
  else
    echo "$lib"
  fi
}

# Function to get symbol status description
get_symbol_status() {
  local status="$1"
  case "$status" in
  U) echo "Undefined (external dependency)" ;;
  T) echo "Text section (defined function)" ;;
  t) echo "Local text (static function)" ;;
  D) echo "Data section (initialized global)" ;;
  d) echo "Local data (static initialized)" ;;
  B) echo "BSS section (uninitialized global)" ;;
  b) echo "Local BSS (static uninitialized)" ;;
  W) echo "Weak symbol" ;;
  w) echo "Local weak symbol" ;;
  R) echo "Read-only data section" ;;
  r) echo "Local read-only data" ;;
  A) echo "Absolute symbol" ;;
  C) echo "Common symbol" ;;
  V) echo "Weak object" ;;
  v) echo "Local weak object" ;;
  *) echo "Unknown status: $status" ;;
  esac
}

# Function to search symbols in a library
search_symbols() {
  local lib_path="$1"
  local indent="$2"

  if [ ! -f "$lib_path" ]; then
    return
  fi

  # Search for symbols using nm and ripgrep
  local symbols=$(nm -D "$lib_path" 2>/dev/null | rg "$SYMBOL_PATTERN" || true)

  if [ -n "$symbols" ]; then
    while IFS= read -r line; do
      # Parse nm output (format: address status symbol)
      local status=$(echo "$line" | awk '{print $2}')
      local symbol=$(echo "$line" | awk '{print $3}')
      local status_desc=$(get_symbol_status "$status")

      if [ "$status" = "U" ]; then
        echo -e "${indent}  ${YELLOW}↳ Symbol: $symbol${NC}"
        echo -e "${indent}    Status: ${RED}$status${NC} - $status_desc"
      else
        echo -e "${indent}  ${GREEN}↳ Symbol: $symbol${NC}"
        echo -e "${indent}    Status: ${GREEN}$status${NC} - $status_desc"
        symbol_found_in["$lib_path"]=1
      fi
    done <<<"$symbols"
  fi
}

# Recursive function to traverse dependencies
traverse_deps() {
  local lib_path="$1"
  local chain="$2"
  local indent="$3"

  # Skip if already visited
  if [[ ${visited["$lib_path"]+isset} ]]; then
    echo -e "${indent}${CYAN}[Already processed: $(basename "$lib_path")]${NC}"
    return
  fi

  visited["$lib_path"]=1

  # Print current library in chain
  echo -e "${indent}${BLUE}→ $(basename "$lib_path")${NC} ($lib_path)"

  # Search for symbols in current library
  search_symbols "$lib_path" "$indent"

  # Get dependencies
  local deps=$(ldd "$lib_path" 2>/dev/null | grep -E '^\s*lib' | awk '{print $1, $3}' || true)

  if [ -n "$deps" ]; then
    while IFS=' ' read -r dep_name dep_path; do
      if [ -n "$dep_path" ] && [ "$dep_path" != "not" ]; then
        local new_chain="${chain} > ${dep_name}"
        traverse_deps "$dep_path" "$new_chain" "${indent}  "
      fi
    done <<<"$deps"
  fi
}

# Main execution
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}Symbol Search Report${NC}"
echo -e "${CYAN}========================================${NC}"
echo -e "Library: $LIBRARY"
echo -e "Symbol Pattern: $SYMBOL_PATTERN"
echo -e "${CYAN}========================================${NC}"
echo ""

# Resolve the main library path
MAIN_LIB_PATH=$(resolve_lib_path "$LIBRARY")

if [ ! -f "$MAIN_LIB_PATH" ]; then
  echo -e "${RED}Error: Cannot find library $LIBRARY${NC}"
  exit 1
fi

# Start traversal
echo -e "${GREEN}Dependency Tree:${NC}"
traverse_deps "$MAIN_LIB_PATH" "$(basename "$MAIN_LIB_PATH")" ""

# Summary
echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}Summary${NC}"
echo -e "${CYAN}========================================${NC}"

if [ ${#symbol_found_in[@]} -gt 0 ]; then
  echo -e "${GREEN}Symbol DEFINED in:${NC}"
  for lib in "${!symbol_found_in[@]}"; do
    echo -e "  ✓ $(basename "$lib") ($lib)"
  done
else
  echo -e "${RED}Symbol not defined in any library (only undefined references found)${NC}"
fi

echo ""
echo -e "Total libraries scanned: ${#visited[@]}"
