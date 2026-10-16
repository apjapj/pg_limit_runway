# vendored from pg-dev-infra harness/check-ci-parity.sh; do not edit here.
# Edit the source there and re-vendor (pg-dev-infra/scripts/vendor-harness.sh).
# vendored-sha256: 68aa2f7acc7334200f9081aec6b2aac5a28ffe06ecb65898d27b3c3ef834b191
# check-ci-parity.sh: the two CI copies must agree, so that "one definition" is enforced and not a
# convention. It checks two things:
#
#   1. A job in one copy exists in the other, unless it is a documented platform difference. The
#      scenario job is one matrix job on GitHub and two named jobs on Forgejo, because the two need
#      different runner labels; that is the only difference allowed, and it is allowed by name.
#   2. The jobs the copies share run the same command. `lint` runs `./scripts/lint.sh` in both and
#      `defects` runs `make defects PG=18` in both; a change to one command in one file fails here.
#
# Without this, the two files drift the first time someone edits one, which is the failure the
# sibling check-pg-versions.sh exists to prevent for the version matrix. No shebang: this file is
# vendored and run with `bash`.
set -uo pipefail
cd "$(dirname "$0")/.."

gh=.github/workflows/ci.yml
fj=.forgejo/workflows/ci.yml
if [ ! -f "$gh" ] || [ ! -f "$fj" ]; then
    echo "  ok    no second CI copy to compare"
    exit 0
fi

python3 - "$gh" "$fj" <<'PY'
import sys, yaml

gh = yaml.safe_load(open(sys.argv[1])) or {}
fj = yaml.safe_load(open(sys.argv[2])) or {}
ghj = list((gh.get("jobs") or {}).keys())
fjj = list((fj.get("jobs") or {}).keys())
bad = []

def is_scenario(n):
    # The one documented platform difference: GitHub's matrix job against Forgejo's two named jobs.
    return n.startswith("scenarios")

for n in ghj:
    if n not in fjj and not is_scenario(n):
        bad.append("only in %s: %s" % (sys.argv[1], n))
for n in fjj:
    if n not in ghj and not is_scenario(n):
        bad.append("only in %s: %s" % (sys.argv[2], n))

def command(wf, job, needle):
    for st in (wf["jobs"][job].get("steps") or []):
        for line in (st.get("run") or "").splitlines():
            s = line.strip()
            if s.startswith("#"):
                continue   # a comment naming the command is not the command
            if needle in s:
                return s
    return None

for job, needle in (("lint", "scripts/lint.sh"), ("defects", "make defects")):
    if job not in ghj:
        bad.append("the GitHub copy has no %s job" % job)
    if job not in fjj:
        bad.append("the Forgejo copy has no %s job" % job)
    if job in ghj and job in fjj:
        a = command(gh, job, needle)
        b = command(fj, job, needle)
        if a != b:
            bad.append("%s runs different commands: %r vs %r" % (job, a, b))
        elif a is None:
            bad.append("the %s job does not run %s" % (job, needle))

if bad:
    print("  FAIL  the two CI copies disagree:")
    for b in bad:
        print("        " + b)
    sys.exit(1)
print("  ok    both copies define the same jobs, and %s run the same command"
      % " and ".join(sorted(set(ghj) & set(fjj))))
PY
