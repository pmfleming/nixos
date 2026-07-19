set -euo pipefail
export LC_ALL=C

profile=/nix/var/nix/profiles/system
refresh_boot=1
keep_recent=5
keep_weekly=8
keep_monthly=12

while (( $# )); do
  case "$1" in
    --profile)
      profile="${2:?--profile requires a path}"
      shift 2
      ;;
    --no-refresh-boot)
      refresh_boot=0
      shift
      ;;
    *)
      printf 'Usage: %s [--profile PATH] [--no-refresh-boot]\n' "$0" >&2
      exit 2
      ;;
  esac
done

refresh_boot_entries() {
  (( refresh_boot )) || return 0
  echo "Refreshing systemd-boot entries"
  /run/current-system/bin/switch-to-configuration boot
}

# Keep exactly bounded calendar buckets: the current week plus seven previous
# ISO weeks, and the current month plus eleven previous calendar months.
declare -A allowed_weeks=()
declare -A allowed_months=()

for ((offset = 0; offset < keep_weekly; offset++)); do
  bucket="$(date --date="$offset weeks ago" +%G-W%V)"
  allowed_weeks["$bucket"]=1
done

# Anchor at the first of the month before subtracting. Subtracting directly
# from dates such as March 31 can roll into March instead of reaching February.
month_anchor="$(date +%Y-%m-01)"
for ((offset = 0; offset < keep_monthly; offset++)); do
  bucket="$(date --date="$month_anchor - $offset months" +%Y-%m)"
  allowed_months["$bucket"]=1
done

mapfile -t generation_rows < <(
  nix-env --profile "$profile" --list-generations \
    | awk '$1 ~ /^[0-9]+$/ { print $1, $2, $3 }' \
    | sort -n -k1,1
)

gens=()
declare -A generation_epoch=()

for row in "${generation_rows[@]}"; do
  read -r gen created_date created_time <<< "$row"
  gens+=("$gen")

  if epoch="$(date --date="$created_date $created_time" +%s 2>/dev/null)"; then
    generation_epoch["$gen"]="$epoch"
  else
    # An unparseable timestamp must fail safe: retain that generation.
    generation_epoch["$gen"]=""
    printf 'Keeping generation %s because its creation time could not be parsed: %s %s\n' \
      "$gen" "$created_date" "$created_time" >&2
  fi
done

total="${#gens[@]}"
if (( total <= keep_recent )); then
  echo "Keeping all $total generations in $profile"
  refresh_boot_entries
  exit 0
fi

profile_current="$(readlink -f "$profile" 2>/dev/null || true)"
run_current="$(readlink -f /run/current-system 2>/dev/null || true)"
run_booted="$(readlink -f /run/booted-system 2>/dev/null || true)"

declare -A keep_by_policy=()
declare -A selected_weeks=()
declare -A selected_months=()

# Traverse newest to oldest so each bucket retains its newest generation.
for ((idx = total - 1; idx >= 0; idx--)); do
  gen="${gens[$idx]}"
  epoch="${generation_epoch[$gen]:-}"

  if (( idx >= total - keep_recent )); then
    keep_by_policy["$gen"]=1
  fi

  if [[ -z "$epoch" ]]; then
    keep_by_policy["$gen"]=1
    continue
  fi

  week_bucket="$(date --date="@$epoch" +%G-W%V)"
  if [[ -n "${allowed_weeks[$week_bucket]+set}" && -z "${selected_weeks[$week_bucket]+set}" ]]; then
    keep_by_policy["$gen"]=1
    selected_weeks["$week_bucket"]="$gen"
  fi

  month_bucket="$(date --date="@$epoch" +%Y-%m)"
  if [[ -n "${allowed_months[$month_bucket]+set}" && -z "${selected_months[$month_bucket]+set}" ]]; then
    keep_by_policy["$gen"]=1
    selected_months["$month_bucket"]="$gen"
  fi
done

keep=()
delete=()

for gen in "${gens[@]}"; do
  link="$(readlink -f "$profile-$gen-link" 2>/dev/null || true)"
  keep_gen=0

  if [[ -n "${keep_by_policy[$gen]+set}" ]]; then
    keep_gen=1
  fi

  # Never delete the active profile target or a running/booted system target.
  if [[ -n "$link" && -n "$profile_current" && "$link" == "$profile_current" ]]; then
    keep_gen=1
  fi
  if [[ -n "$link" && -n "$run_current" && "$link" == "$run_current" ]]; then
    keep_gen=1
  fi
  if [[ -n "$link" && -n "$run_booted" && "$link" == "$run_booted" ]]; then
    keep_gen=1
  fi

  if (( keep_gen )); then
    keep+=("$gen")
  else
    delete+=("$gen")
  fi
done

echo "Keeping generations in $profile: ${keep[*]}"

if (( ${#delete[@]} )); then
  echo "Deleting generations in $profile: ${delete[*]}"
  nix-env --profile "$profile" --delete-generations "${delete[@]}"
else
  echo "No generations to delete in $profile"
fi

refresh_boot_entries
