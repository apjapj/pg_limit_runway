# scenarios/mask.sh: turn a raw capture into evidence comparable between runs. Sourced by run.sh.
# Same convention as pg_bloat_cause: pg_lock_tree's token names, and one rule per named volatile field,
# so every count, limit and threshold passes through as it ran.
MASKS=(
  's/\x1b\[[0-9;]*m//g'
  # s9's password expiry, set from now(): a timestamp with fractional seconds is one taken at run time.
  # The fixed partition bounds (2026-03-01 00:00:00+00) have none and pass through.
  's/[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+\+[0-9]{2}/<run-time timestamp>/g'
)
mask_capture() {
    local args=() e
    for e in "${MASKS[@]}"; do args+=(-e "$e"); done
    grep -v '^NOTICE:' | sed -E "${args[@]}" | sed -E -e 's/ +/ /g' -e 's/ +$//' -e '/^-+(\+-+)*$/d'
}
