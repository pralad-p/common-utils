# Usage:
#   find_symbol_tree ./libfoo.so 'MyNamespace::MyClass::func()'
#
# Requires:
#   - bash 4+
#   - ldd
#   - nm (binutils)
#   - rg (ripgrep)

find_symbol_tree() {
  local root="$1"
  local symbol="$2"

  if [[ -z "$root" || -z "$symbol" ]]; then
    echo "Usage: find_symbol_tree <binary-or-so> <symbol-string>" >&2
    return 1
  fi

  if ! command -v rg >/dev/null 2>&1; then
    echo "find_symbol_tree: requires ripgrep (rg) on PATH" >&2
    return 1
  fi

  # Graph: library -> parent
  local -A seen
  local -A parent

  local queue=()
  queue+=("$(readlink -f "$root")")
  local root_abs="${queue[0]}"

  seen["$root_abs"]=1
  parent["$root_abs"]=""

  # Build dependency graph with a BFS over ldd
  local i=0
  while [[ $i -lt ${#queue[@]} ]]; do
    local current="${queue[$i]}"
    ((i++))

    while IFS= read -r line; do
      # Handle:
      #   libX.so => /path/to/libX.so (0x...)
      #   /lib64/ld-linux-x86-64.so.2 (0x...)
      local tok path
      if [[ "$line" == *"=>"* ]]; then
        tok=$(awk '{print $3}' <<<"$line")
      else
        tok=$(awk '{print $1}' <<<"$line")
      fi

      # Skip "not found" and non-absolute paths (linux-vdso, etc.)
      [[ -z "$tok" || "$tok" == "not" ]] && continue
      [[ "$tok" != /* ]] && continue

      path="$tok"
      path=$(readlink -f "$path" 2>/dev/null || echo "$path")

      if [[ -z "${seen[$path]}" ]]; then
        seen["$path"]=1
        parent["$path"]="$current"
        queue+=("$path")
      fi
    done < <(ldd "$current" 2>/dev/null)
  done

  # Helper: print chain root > ... > lib
  _print_path() {
    local node="$1"
    local path=()
    while [[ -n "$node" ]]; do
      path+=("$node")
      node="${parent[$node]}"
    done

    local out=""
    for ((idx = ${#path[@]} - 1; idx >= 0; idx--)); do
      local base
      base=$(basename "${path[$idx]}")
      if [[ -z "$out" ]]; then
        out="$base"
      else
        out="$out > $base"
      fi
    done
    echo "$out"
  }

  local found=0

  # Walk all libs and search for the symbol
  for lib in "${!seen[@]}"; do
    # Use nm on dynamic symbols, demangled, then ripgrep literal match
    mapfile -t matches < <(nm -D -C "$lib" 2>/dev/null | rg -F "$symbol" || true)
    [[ ${#matches[@]} -eq 0 ]] && continue

    ((found++))

    local defined=0
    local undefined=0

    for line in "${matches[@]}"; do
      local trimmed first second type

      # Normalize whitespace
      trimmed=$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+/ /g' <<<"$line")
      first=${trimmed%% *}
      second=""
      if [[ "$trimmed" == *" "* ]]; then
        second=${trimmed#* }
        second=${second%% *}
      fi

      # Infer the nm type char (U, T, B, etc.)
      if [[ ${#first} -eq 1 && "$first" =~ [A-Za-z] ]]; then
        type="$first" # format: "U name"
      else
        type="$second" # format: "ADDR T name"
      fi

      case "$type" in
      U | w | v) ((undefined++)) ;; # U = undefined, w/v = weak/undefined-ish
      *) ((defined++)) ;;
      esac
    done

    local status
    if ((defined > 0 && undefined > 0)); then
      status="defined here and also referenced"
    elif ((defined > 0)); then
      status="defined here"
    else
      status="only referenced here (undefined in this object)"
    fi

    echo "========================================"
    echo "Library:   $lib"
    echo "Chain:     $(_print_path "$lib")"
    echo "Symbol:    $symbol"
    echo
    echo "Summary:   $status"
    echo
    printf 'nm matches:\n'
    printf '  %s\n' "${matches[@]}"
    echo
  done

  if ((found == 0)); then
    echo "Symbol '$symbol' not found in dependency tree of $root_abs"
    return 1
  fi
}
