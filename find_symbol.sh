#!/bin/bash

# Symbol finder - only shows paths leading to the symbol
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

# Associative arrays
declare -A visited
declare -A lib_symbols # stores "lib_path:status:symbol_name"

# Function to resolve library path
resolve_lib_path() {
  local lib="$1"

  if [[ "$lib" == /* ]]; then
    echo "$lib"
    return
  fi

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
  w) echo "Local weak object" ;;
  R) echo "Read-only data section" ;;
  r) echo "Local read-only data" ;;
  A) echo "Absolute symbol" ;;
  C) echo "Common symbol" ;;
  V) echo "Weak object" ;;
  v) echo "Local weak object" ;;
  *) echo "Unknown status: $status" ;;
  esac
}

# Function to check if library contains symbol
check_library_for_symbol() {
  local lib_path="$1"

  if [ ! -f "$lib_path" ]; then
    return 1
  fi

  # Search for symbols using nm and ripgrep
  local symbols=$(nm -D "$lib_path" 2>/dev/null | rg "$SYMBOL_PATTERN" || true)

  if [ -n "$symbols" ]; then
    # Store all matching symbols for this library
    lib_symbols["$lib_path"]="$symbols"
    return 0
  fi
  return 1
}

# Recursive function to find paths to symbol
find_symbol_paths() {
  local lib_path="$1"
  local chain_array=("${@:2}") # Rest of args are the chain

  # Skip if already visited
  if [[ ${visited["$lib_path"]+isset} ]]; then
    return 1
  fi

  visited["$lib_path"]=1

  local found=0
  local has_symbol=0

  # Check if this library has the symbol
  if check_library_for_symbol "$lib_path"; then
    has_symbol=1
    found=1
  fi

  # Get dependencies and check them recursively
  local deps=$(ldd "$lib_path" 2>/dev/null | grep -E '^\s*lib' | awk '{print $3}' || true)

  if [ -n "$deps" ]; then
    while IFS= read -r dep_path; do
      if [ -n "$dep_path" ] && [ "$dep_path" != "not" ] && [ -f "$dep_path" ]; then
        local new_chain=("${chain_array[@]}" "$dep_path")
        if find_symbol_paths "$dep_path" "${new_chain[@]}"; then
          found=1
        fi
      fi
    done <<<"$deps"
  fi

  # If symbol was found in this branch, print the chain
  if [ $found -eq 1 ] && [ $has_symbol -eq 1 ]; then
    # Print the chain
    echo ""
    echo -e "${CYAN}Found in chain:${NC}"
    for i in "${!chain_array[@]}"; do
      local indent=""
      for ((j = 0; j < i; j++)); do
        indent="  $indent"
      done

      local lib="${chain_array[$i]}"
      local basename=$(basename "$lib")

      if [ "$lib" = "$lib_path" ]; then
        # This is the library with the symbol
        echo -e "${indent}${GREEN}→ $basename${NC}"

        # Print symbol details
        while IFS= read -r line; do
          if [ -n "$line" ]; then
            local status=$(echo "$line" | awk '{print $2}')
            local symbol=$(echo "$line" | awk '{print $3}')
            local status_desc=$(get_symbol_status "$status")

            if [ "$status" = "U" ]; then
              echo -e "${indent}  ${YELLOW}Symbol: $symbol${NC}"
              echo -e "${indent}  ${RED}Status: $status${NC} - $status_desc"
            else
              echo -e "${indent}  ${GREEN}Symbol: $symbol${NC}"
              echo -e "${indent}  ${GREEN}Status: $status${NC} - $status_desc"
            fi
          fi
        done <<<"${lib_symbols[$lib_path]}"
      else
        echo -e "${indent}${BLUE}→ $basename${NC}"
      fi
    done
  fi

  return $found
}

# Main execution
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}Symbol Search Report${NC}"
echo -e "${CYAN}========================================${NC}"
echo -e "Library: $LIBRARY"
echo -e "Symbol Pattern: $SYMBOL_PATTERN"
echo -e "${CYAN}========================================${NC}"

# Resolve the main library path
MAIN_LIB_PATH=$(resolve_lib_path "$LIBRARY")

if [ ! -f "$MAIN_LIB_PATH" ]; then
  echo -e "${RED}Error: Cannot find library $LIBRARY${NC}"
  exit 1
fi

# Start search
if ! find_symbol_paths "$MAIN_LIB_PATH" "$MAIN_LIB_PATH"; then
  echo ""
  echo -e "${RED}Symbol pattern '$SYMBOL_PATTERN' not found in any dependencies${NC}"
  exit 1
fi

# Summary
echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}Summary${NC}"
echo -e "${CYAN}========================================${NC}"

# Count defined vs undefined
defined_count=0
undefined_count=0

for lib_path in "${!lib_symbols[@]}"; do
  while IFS= read -r line; do
    if [ -n "$line" ]; then
      local status=$(echo "$line" | awk '{print $2}')
      if [ "$status" = "U" ]; then
        ((undefined_count++))
      else
        ((defined_count++))
      fi
    fi
  done <<<"${lib_symbols[$lib_path]}"
done

echo -e "Symbol occurrences found:"
if [ $defined_count -gt 0 ]; then
  echo -e "  ${GREEN}✓ Defined: $defined_count${NC}"
fi
if [ $undefined_count -gt 0 ]; then
  echo -e "  ${YELLOW}○ Undefined references: $undefined_count${NC}"
fi
echo -e "Libraries in chain: $(echo ${!lib_symbols[@]} | wc -w)"
