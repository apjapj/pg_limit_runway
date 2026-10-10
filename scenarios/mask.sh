# scenarios/mask.sh: turn a raw capture into evidence comparable between runs. Sourced by run.sh.
# Same convention as pg_bloat_cause: pg_lock_tree's token names, and one rule per named volatile field,
# so every count, limit and threshold passes through as it ran.
MASKS=(
  's/\x1b\[[0-9;]*m//g'
)
mask_capture() {
    local args=() e
    for e in "${MASKS[@]}"; do args+=(-e "$e"); done
    grep -v '^NOTICE:' | sed -E "${args[@]}" | sed -E -e 's/ +/ /g' -e 's/ +$//' -e '/^-+(\+-+)*$/d'
}
