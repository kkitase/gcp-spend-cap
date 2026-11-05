#!/usr/bin/env bash
# gcp-spend-cap.sh: manage Cloud Billing spend cap budgets.
#
# A spend cap budget pauses new usage of one service in one project when the
# monthly cost reaches the amount you set. Supported services: Gemini API,
# Vertex AI, Cloud Run and Cloud Run functions.
#
# Requires: bash 3.2+, curl, jq and the gcloud CLI (all preinstalled on recent
# macOS and in Cloud Shell, except gcloud on macOS).

set -euo pipefail

BUDGETS_API="https://billingbudgets.googleapis.com/v1"
BILLING_API="https://cloudbilling.googleapis.com/v1"
ALL_SERVICES="gemini vertex run functions"

usage() {
  cat <<'EOF'
Usage:
  gcp-spend-cap.sh set    -p PROJECT -a AMOUNT [options] [--force]
  gcp-spend-cap.sh status -p PROJECT [options]
  gcp-spend-cap.sh lift   -p PROJECT [options]
  gcp-spend-cap.sh delete -p PROJECT [options]

Commands:
  set     Create or update monthly caps
  status  Show caps and their state
  lift    Resume usage that was paused because a cap was reached
  delete  Delete caps

Options:
  -p, --project PROJECT   Project ID (default: current gcloud project)
  -a, --amount AMOUNT     Monthly cap per service, in the billing account currency
  -s, --services LIST     all (default) or a comma-separated list of:
                          gemini, vertex, run, functions
  -y, --yes               Do not ask for confirmation
      --dry-run           Show changes without making them
      --enable-api        Enable the Budget and Billing APIs on the project first
      --force             set: lift reached caps so the new amount can be applied
  -h, --help              Show this help

Amounts use the billing account currency (for example 10000 = JPY 10,000).
Credits are ignored: usage paid by credits still counts toward the cap.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

service_id() {
  case "$1" in
    gemini) echo "AEFD-7695-64FA" ;;
    vertex) echo "C7E2-9256-1C43" ;;
    run) echo "152E-C115-5142" ;;
    functions) echo "29E7-DA93-CA13" ;;
    *) return 1 ;;
  esac
}

service_name() {
  case "$1" in
    gemini) echo "Gemini API" ;;
    vertex) echo "Vertex AI" ;;
    run) echo "Cloud Run" ;;
    functions) echo "Cloud Run functions" ;;
    *) return 1 ;;
  esac
}

# --- Arguments -----------------------------------------------------------------

COMMAND="${1:-}"
case "$COMMAND" in
  set | status | lift | delete) shift ;;
  -h | --help | help | "") usage; exit 0 ;;
  *) die "unknown command '$COMMAND'. Run with --help." ;;
esac

PROJECT=""
AMOUNT=""
SERVICES_ARG="all"
YES=false
DRY_RUN=false
ENABLE_API=false
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p | --project | -a | --amount | -s | --services)
      [[ $# -ge 2 ]] || die "$1 needs a value."
      case "$1" in
        -p | --project) PROJECT="$2" ;;
        -a | --amount) AMOUNT="$2" ;;
        *) SERVICES_ARG="$2" ;;
      esac
      shift 2
      ;;
    -y | --yes) YES=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --enable-api) ENABLE_API=true; shift ;;
    --force) FORCE=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown option '$1'. Run with --help." ;;
  esac
done

if [[ "$COMMAND" == "set" ]]; then
  [[ -n "$AMOUNT" ]] || die "set needs --amount."
  if [[ ! "$AMOUNT" =~ ^[0-9]+(\.[0-9]{1,9})?$ ]] || [[ ! "$AMOUNT" =~ [1-9] ]]; then
    die "'$AMOUNT' is not a positive number such as 100 or 49.99."
  fi
  # Split the amount into the API's units and nanos fields.
  NEW_UNITS=$((10#${AMOUNT%%.*}))
  NEW_NANOS=0
  if [[ "$AMOUNT" == *.* ]]; then
    fraction="${AMOUNT#*.}000000000"
    NEW_NANOS=$((10#${fraction:0:9}))
  fi
else
  [[ -z "$AMOUNT" ]] || die "--amount is only used by set."
  ! $FORCE || die "--force is only used by set."
fi

SERVICES=""
if [[ "$SERVICES_ARG" == "all" ]]; then
  SERVICES="$ALL_SERVICES"
else
  [[ -n "$SERVICES_ARG" ]] || die "no services given."
  IFS=',' read -r -a requested <<<"$SERVICES_ARG"
  for key in ${requested[@]+"${requested[@]}"}; do
    key="${key// /}"
    [[ -n "$key" ]] || continue
    service_id "$key" >/dev/null || die "unknown service '$key'. Use all or: ${ALL_SERVICES// /, }."
    [[ " $SERVICES " == *" $key "* ]] || SERVICES="$SERVICES $key"
  done
  [[ -n "$SERVICES" ]] || die "no services given."
fi

for tool in gcloud curl jq; do
  command -v "$tool" >/dev/null || die "'$tool' is required but not installed."
done

# --- Authentication and HTTP ---------------------------------------------------

if [[ -z "$PROJECT" ]]; then
  PROJECT="$(gcloud config get-value project 2>/dev/null </dev/null || true)"
fi
[[ -n "$PROJECT" && "$PROJECT" != "(unset)" ]] || die "no project. Pass -p PROJECT."
[[ "$PROJECT" =~ ^[a-zA-Z0-9.:-]+$ ]] || die "invalid project ID '$PROJECT'."

ACTIVE_CONFIG="${CLOUDSDK_ACTIVE_CONFIG_NAME:-$(cat "${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}/active_config" 2>/dev/null || echo default)}"
GCLOUD_ACCOUNT="$(gcloud config get-value account 2>/dev/null </dev/null || true)"
[[ "$GCLOUD_ACCOUNT" != "(unset)" ]] || GCLOUD_ACCOUNT=""
CREDENTIAL=""

print_gcloud_switch_help() {
  local config_dir="${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}"
  cat >&2 <<EOF
  Current auth state:
    Account:       ${CREDENTIAL:-${GCLOUD_ACCOUNT:-none}}
    Configuration: ${ACTIVE_CONFIG} (${config_dir})
    Project:       ${PROJECT}

  How to check or change credentials with gcloud:
    # Switch account
    gcloud auth list
    gcloud config set account ACCOUNT_EMAIL

    # Switch named configuration
    gcloud config configurations list
    gcloud config configurations activate CONFIG_NAME

    # Sign in again (if your session expired)
    gcloud auth login
    gcloud auth application-default login
EOF
  if [[ -n "${CLOUDSDK_CONFIG:-}" || -n "${CLOUDSDK_ACTIVE_CONFIG_NAME:-}" ]]; then
    cat >&2 <<EOF

  Note: Shell environment variables are overriding 'gcloud config configurations activate':
    ${CLOUDSDK_CONFIG:+CLOUDSDK_CONFIG=$CLOUDSDK_CONFIG }${CLOUDSDK_ACTIVE_CONFIG_NAME:+CLOUDSDK_ACTIVE_CONFIG_NAME=$CLOUDSDK_ACTIVE_CONFIG_NAME}
    Switch your shell profile/helper, or override per command:
    CLOUDSDK_CONFIG=~/.config/gcloud-other CLOUDSDK_ACTIVE_CONFIG_NAME=default $0 ...
EOF
  fi
}

TOKEN="$(gcloud auth print-access-token --quiet 2>/dev/null </dev/null || true)"
if [[ -n "$TOKEN" ]]; then
  CREDENTIAL="${GCLOUD_ACCOUNT:-gcloud user credentials}"
else
  # Fall back to Application Default Credentials (for example when gcloud needs reauthentication).
  TOKEN="$(gcloud auth application-default print-access-token --quiet 2>/dev/null </dev/null || true)"
  CREDENTIAL="application default credentials${GCLOUD_ACCOUNT:+ ($GCLOUD_ACCOUNT)}"
fi
if [[ -z "$TOKEN" ]]; then
  echo "Authentication error: no valid credentials found in gcloud." >&2
  echo >&2
  CREDENTIAL=""
  print_gcloud_switch_help
  exit 1
fi

# Keep the token out of the process list: curl reads the header from a private file.
HEADER_FILE="$(umask 077 && mktemp)"
cleanup() { rm -f "$HEADER_FILE"; }
trap cleanup EXIT
trap 'cleanup; trap - INT; kill -INT $$' INT
trap 'cleanup; exit 143' TERM HUP
printf 'Authorization: Bearer %s\n' "$TOKEN" >"$HEADER_FILE"

API_NEWLY_ENABLED=false
AUTH_VERIFIED=false

# api METHOD URL [BODY]: print the JSON response, or print the error and return 1.
api() {
  local method="$1" url="$2" body="${3:-}" response status attempt max_attempts=3 msg
  local args=(-sS --max-time 30 -X "$method" -H "@$HEADER_FILE" -H "x-goog-user-project: $PROJECT"
    -H "Content-Type: application/json" -w $'\n%{http_code}')
  [[ -z "$body" ]] || args+=(--data "$body")
  ! $API_NEWLY_ENABLED || max_attempts=8
  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    response="$(curl "${args[@]}" "$url" </dev/null)" || {
      echo "Network error: $method $url" >&2
      return 1
    }
    status="${response##*$'\n'}"
    response="${response%$'\n'*}"
    # 429 and 503 mean the request was not processed, so retrying is safe.
    if [[ "$status" == 429 || "$status" == 503 ]] && [[ $attempt -lt 3 ]]; then
      sleep $((attempt * 2))
      continue
    fi
    # Newly enabled APIs can take up to a minute to propagate.
    if $API_NEWLY_ENABLED && [[ "$status" == 403 && "$response" == *SERVICE_DISABLED* && $attempt -lt $max_attempts ]]; then
      [[ $attempt -gt 1 ]] || echo "Waiting for enabled APIs to propagate..." >&2
      sleep 5
      continue
    fi
    break
  done
  if [[ "$status" -ge 400 ]]; then
    msg="$(jq -r '.error.message // empty' <<<"$response" 2>/dev/null || true)"
    if [[ "$status" == 401 ]]; then
      echo "Authentication error (HTTP 401): access token was rejected by Google Cloud." >&2
      echo "  Reason: ${msg:-$response}" >&2
      echo "  Likely cause: wrong account/configuration is active, your login expired, or this account" >&2
      echo "  requires Context-Aware Access (mTLS client certificates), which curl cannot use." >&2
      echo >&2
      print_gcloud_switch_help
    elif [[ "$response" == *SERVICE_DISABLED* ]]; then
      echo "HTTP $status: ${msg:-$response}" >&2
      if $ENABLE_API && $DRY_RUN; then
        echo "  Hint: --dry-run did not enable APIs; rerun without --dry-run or enable them first." >&2
      elif $ENABLE_API; then
        echo "  Hint: new APIs can take a few minutes to activate; wait a moment and rerun." >&2
      else
        echo "  Hint: rerun with --enable-api (new APIs can take a few minutes to activate)." >&2
      fi
    elif [[ "$status" == 403 ]] && ! $AUTH_VERIFIED; then
      echo "Permission error (HTTP 403): '${CREDENTIAL:-unknown}' cannot access project '$PROJECT'." >&2
      echo "  Reason: ${msg:-$response}" >&2
      echo "  If you are signed in with the wrong Google account, switch credentials below." >&2
      echo >&2
      print_gcloud_switch_help
    elif [[ "$status" == 403 ]]; then
      echo "HTTP $status: ${msg:-$response}" >&2
      echo "  Hint: check that '${CREDENTIAL:-unknown}' has billing.resourcebudgets.read/write and" >&2
      echo "        billing.resourcebudgets.configureSpendCap on '$PROJECT' (or Billing Account Administrator)." >&2
    else
      echo "HTTP $status: ${msg:-$response}" >&2
    fi
    return 1
  fi
  printf '%s\n' "${response:-"{}"}"
}

# write METHOD URL [BODY]: send a change, or only show it in dry-run mode (prints nothing).
write() {
  if $DRY_RUN; then
    echo "  [dry-run] $1 $2" >&2
    [[ -z "${3:-}" ]] || jq . <<<"$3" | sed 's/^/  /' >&2
    return 0
  fi
  api "$@"
}

confirm() {
  if $YES || $DRY_RUN; then return 0; fi
  [[ -t 0 ]] || die "confirmation needed, but this is not an interactive session. Rerun with --yes."
  local answer
  read -r -p "$1 [y/N]: " answer
  case "$answer" in
    y | Y | yes | YES) ;;
    *) echo "Aborted. Nothing was changed."; exit 1 ;;
  esac
}

# --- Budget helpers ------------------------------------------------------------

state_of() { jq -r '.spendCap.outputState // "UNKNOWN"' <<<"$1"; }
name_of() { jq -r '.name' <<<"$1"; }

# Print "UNITS NANOS" of a budget amount.
amount_of() { jq -r '"\(.amount.specifiedAmount.units // "0") \(.amount.specifiedAmount.nanos // 0)"' <<<"$1"; }

# fmt_amount UNITS NANOS: print a readable amount such as 100 or 49.99 with the currency.
fmt_amount() {
  local text="$1"
  if [[ "$2" -ne 0 ]]; then
    text="$1.$(printf '%09d' "$2" | sed 's/0*$//')"
  fi
  echo "$text${CURRENCY:+ $CURRENCY}"
}

# Find the project's spend cap budgets and store them in CAPS as {"gemini": [{...}, ...], ...}.
find_caps() {
  local all="[]" page token="" url
  while true; do
    url="$BUDGETS_API/billingAccounts/$ACCOUNT/budgets?scope=projects/$PROJECT&pageSize=100"
    [[ -z "$token" ]] || url="$url&pageToken=$(jq -rn --arg t "$token" '$t | @uri')"
    page="$(api GET "$url")" || return 1
    all="$(jq -sc '.[0] + (.[1].budgets // [])' <<<"$all"$'\n'"$page")"
    token="$(jq -r '.nextPageToken // empty' <<<"$page")"
    [[ -n "$token" ]] || break
  done
  CAPS="$(jq -c '
    {"AEFD-7695-64FA": "gemini", "C7E2-9256-1C43": "vertex",
     "152E-C115-5142": "run", "29E7-DA93-CA13": "functions"} as $keys
    | map(select(((.spendCap.outputState // "STATE_UNSPECIFIED") != "STATE_UNSPECIFIED")
        and (((.budgetFilter.services // []) | length) == 1)))
    | map({key: $keys[.budgetFilter.services[0] | split("/")[-1]], value: .})
    | map(select(.key != null))
    | reduce .[] as $item ({}; .[$item.key] = ((.[$item.key] // []) + [$item.value]))' <<<"$all")"
}

cap_count() { jq -r --arg key "$1" '(.[$key] // []) | length' <<<"$CAPS"; }
cap_at() { jq -c --arg key "$1" --argjson i "$2" '.[$key][$i]' <<<"$CAPS"; }

# Spend cap state changes run asynchronously. Wait until the server finishes, then print the budget.
wait_until_settled() {
  local budget="$1" i
  for i in $(seq 60); do
    if [[ "$(jq -r '.spendCap.reconciling // false' <<<"$budget")" != "true" ]]; then
      echo "$budget"
      return 0
    fi
    [[ $i -gt 1 ]] || echo "  Waiting for spend cap state change to finish..." >&2
    sleep 3
    budget="$(api GET "$BUDGETS_API/$(name_of "$budget")")" || return 1
  done
  echo "Timed out waiting for the spend cap state change to finish." >&2
  return 1
}

# Lift an enforced cap so paused usage resumes. Prints the updated budget (nothing in dry-run).
lift_cap() {
  local budget result
  budget="$(wait_until_settled "$1")" || return 1
  result="$(write PATCH "$BUDGETS_API/$(name_of "$budget")?updateMask=spendCap.inputState" \
    '{"spendCap": {"inputState": "AWAITING_NEXT_PERIOD"}}')" || return 1
  [[ -z "$result" ]] || wait_until_settled "$result"
}

new_budget_body() {
  local key="$1"
  # Spend caps require: one project, one service, monthly, credits excluded,
  # thresholds at exactly 50/80/100 % and project-level recipients.
  jq -n --arg name "$PROJECT $(service_name "$key") spend cap" --arg project "projects/$PROJECT" \
    --arg service "services/$(service_id "$key")" --arg units "$NEW_UNITS" --argjson nanos "$NEW_NANOS" '{
      displayName: $name[0:60],
      budgetFilter: {projects: [$project], services: [$service],
                     creditTypesTreatment: "EXCLUDE_ALL_CREDITS", calendarPeriod: "MONTH"},
      amount: {specifiedAmount: {units: $units, nanos: $nanos}},
      thresholdRules: [{thresholdPercent: 0.5}, {thresholdPercent: 0.8}, {thresholdPercent: 1.0}],
      notificationsRule: {enableProjectLevelRecipients: true},
      spendCap: {inputState: "CONFIGURED"}
    }'
}

create_cap() {
  local result
  result="$(write POST "$BUDGETS_API/billingAccounts/$ACCOUNT/budgets" "$(new_budget_body "$1")")" || return 1
  [[ -z "$result" ]] || wait_until_settled "$result"
}

update_amount() {
  local budget="$1" lifted body result
  budget="$(wait_until_settled "$budget")" || return 1
  if [[ "$(state_of "$budget")" == "ENFORCED" ]]; then
    # An enforced budget cannot be edited until the cap is lifted.
    lifted="$(lift_cap "$budget")" || return 1
    budget="${lifted:-$(jq -c '.spendCap.outputState = "AWAITING_NEXT_PERIOD"' <<<"$budget")}"
  fi
  # Updating a spend cap budget with updateMask always requires spendCap.inputState in the mask.
  body="$(jq -n --arg units "$NEW_UNITS" --argjson nanos "$NEW_NANOS" \
    '{amount: {specifiedAmount: {units: $units, nanos: $nanos}}, spendCap: {inputState: "CONFIGURED"}}')"
  result="$(write PATCH "$BUDGETS_API/$(name_of "$budget")?updateMask=amount.specifiedAmount,spendCap.inputState" "$body")" || return 1
  [[ -z "$result" ]] || wait_until_settled "$result"
}

# --- Commands ------------------------------------------------------------------

cmd_status() {
  local key count idx budget state units nanos
  printf '%-22s %-16s %s\n' "SERVICE" "MONTHLY CAP" "STATE"
  for key in $SERVICES; do
    count="$(cap_count "$key")"
    if [[ "$count" -eq 0 ]]; then
      printf '%-22s %-16s %s\n' "$(service_name "$key")" "-" "NOT SET"
      continue
    fi
    for ((idx = 0; idx < count; idx++)); do
      budget="$(cap_at "$key" "$idx")"
      state="$(state_of "$budget")"
      [[ "$(jq -r '.spendCap.reconciling // false' <<<"$budget")" != "true" ]] || state="$state (changing)"
      [[ "$count" -eq 1 ]] || state="$state (duplicate $((idx + 1))/$count)"
      read -r units nanos <<<"$(amount_of "$budget")"
      printf '%-22s %-16s %s\n' "$(service_name "$key")" "$(fmt_amount "$units" "$nanos")" "$state"
    done
  done
}

cmd_set() {
  local key name count budget state units nanos current new todo="" skipped=0 failed result note
  case "$CURRENCY" in
    JPY | KRW | VND | CLP) [[ "$NEW_NANOS" -eq 0 ]] || die "$CURRENCY has no decimals. Use a whole number." ;;
  esac
  new="$(fmt_amount "$NEW_UNITS" "$NEW_NANOS")"

  echo "Plan:"
  for key in $SERVICES; do
    name="$(service_name "$key")"
    count="$(cap_count "$key")"
    if [[ "$count" -eq 0 ]]; then
      echo "  create  $name: $new"
      todo="$todo $key"
      continue
    fi
    if [[ "$count" -gt 1 ]]; then
      echo "  skip    $name: $count spend caps exist; delete duplicates before updating."
      skipped=$((skipped + 1))
      continue
    fi
    budget="$(cap_at "$key" 0)"
    state="$(state_of "$budget")"
    read -r units nanos <<<"$(amount_of "$budget")"
    current="$(fmt_amount "$units" "$nanos")"
    if [[ "$state" == "ENFORCED" ]] && ! $FORCE; then
      echo "  skip    $name: cap reached and usage is paused. Use --force to lift it and apply $new."
      skipped=$((skipped + 1))
    elif [[ "$state" == "CONFIGURED" && "$units" -eq "$NEW_UNITS" && "$nanos" -eq "$NEW_NANOS" ]]; then
      echo "  skip    $name: already $new"
    else
      note=""
      [[ "$state" != "ENFORCED" ]] || note=" (lifts the cap first, so paused usage resumes)"
      echo "  update  $name: $current -> $new$note"
      if [[ "$state" == "ENFORCED" || "$state" == "AWAITING_NEXT_PERIOD" ]] &&
        ((NEW_UNITS < units || (NEW_UNITS == units && NEW_NANOS <= nanos))); then
        echo "          Warning: a lifted cap triggers again this month only if the amount is raised."
      fi
      todo="$todo $key"
    fi
  done

  if [[ -z "$todo" ]]; then
    echo "Nothing to change."
    [[ $skipped -eq 0 ]]
    return
  fi
  confirm "Apply the changes to $PROJECT?"

  failed=$skipped
  for key in $todo; do
    name="$(service_name "$key")"
    if [[ "$(cap_count "$key")" -eq 0 ]]; then
      result="$(create_cap "$key")" || result="FAILED"
    else
      result="$(update_amount "$(cap_at "$key" 0)")" || result="FAILED"
    fi
    if [[ "$result" == "FAILED" ]]; then
      echo "[failed] $name" >&2
      failed=$((failed + 1))
    elif [[ -n "$result" ]]; then
      read -r units nanos <<<"$(amount_of "$result")"
      echo "[done]   $name: $(fmt_amount "$units" "$nanos") ($(state_of "$result"))"
    fi
  done
  [[ $failed -eq 0 ]]
}

cmd_lift() {
  local key count idx budget names="" has_enforced=false failed=0 result
  for key in $SERVICES; do
    count="$(cap_count "$key")"
    for ((idx = 0; idx < count; idx++)); do
      budget="$(cap_at "$key" "$idx")"
      if [[ "$(state_of "$budget")" == "ENFORCED" ]]; then
        has_enforced=true
        names="$names [$(service_name "$key")]"
      fi
    done
  done
  if ! $has_enforced; then
    echo "No enforced caps. Nothing to lift."
    return 0
  fi
  echo "Caps to lift:$names"
  confirm "Lift them? Paused usage resumes and the caps stay off until next month unless you raise the amount."

  for key in $SERVICES; do
    count="$(cap_count "$key")"
    for ((idx = 0; idx < count; idx++)); do
      budget="$(cap_at "$key" "$idx")"
      [[ "$(state_of "$budget")" == "ENFORCED" ]] || continue
      if result="$(lift_cap "$budget")"; then
        [[ -z "$result" ]] || echo "[done]   $(service_name "$key"): $(state_of "$result") (can take up to 1 hour to resume)"
      else
        echo "[failed] $(service_name "$key")" >&2
        failed=$((failed + 1))
      fi
    done
  done
  [[ $failed -eq 0 ]]
}

delete_cap() {
  local budget
  budget="$(wait_until_settled "$1")" || return 1
  if [[ "$(state_of "$budget")" == "ENFORCED" ]]; then
    lift_cap "$budget" >/dev/null || return 1 # Enforced budgets must be lifted before deletion.
  fi
  write DELETE "$BUDGETS_API/$(name_of "$budget")" >/dev/null
}

cmd_delete() {
  local key count idx names="" has_targets=false failed=0
  for key in $SERVICES; do
    count="$(cap_count "$key")"
    for ((idx = 0; idx < count; idx++)); do
      has_targets=true
      names="$names [$(service_name "$key")]"
    done
  done
  if ! $has_targets; then
    echo "No spend caps. Nothing to delete."
    return 0
  fi
  echo "Caps to delete:$names"
  confirm "Delete them from $PROJECT? This cannot be undone."

  for key in $SERVICES; do
    count="$(cap_count "$key")"
    for ((idx = 0; idx < count; idx++)); do
      if delete_cap "$(cap_at "$key" "$idx")"; then
        $DRY_RUN || echo "[done]   $(service_name "$key"): deleted"
      else
        echo "[failed] $(service_name "$key")" >&2
        failed=$((failed + 1))
      fi
    done
  done
  [[ $failed -eq 0 ]]
}

enable_apis() {
  local service_usage="https://serviceusage.googleapis.com/v1" body op i
  body='{"serviceIds": ["billingbudgets.googleapis.com", "cloudbilling.googleapis.com"]}'
  if $DRY_RUN; then
    write POST "$service_usage/projects/$PROJECT/services:batchEnable" "$body"
    return 0
  fi
  op="$(api POST "$service_usage/projects/$PROJECT/services:batchEnable" "$body")" || return 1
  for i in $(seq 60); do
    if [[ "$(jq -r '.done // false' <<<"$op")" == "true" ]]; then
      if [[ -n "$(jq -r '.error // empty' <<<"$op")" ]]; then
        echo "API enablement failed: $(jq -r '.error.message // (.error | tostring)' <<<"$op")" >&2
        return 1
      fi
      API_NEWLY_ENABLED=true
      echo "Enabled Billing and Budget APIs on $PROJECT."
      return 0
    fi
    [[ $i -gt 1 ]] || echo "Enabling Billing and Budget APIs on $PROJECT..." >&2
    sleep 3
    op="$(api GET "$service_usage/$(jq -r '.name' <<<"$op")")" || return 1
  done
  echo "Timed out waiting for API enablement to finish." >&2
  return 1
}

# --- Main ----------------------------------------------------------------------

if $ENABLE_API; then
  enable_apis || exit 1
fi

BILLING="$(api GET "$BILLING_API/projects/$PROJECT/billingInfo")" || exit 1
AUTH_VERIFIED=true
[[ "$(jq -r '.billingEnabled // false' <<<"$BILLING")" == "true" ]] ||
  die "project $PROJECT has no active billing account."
ACCOUNT="$(jq -r '.billingAccountName | split("/")[-1]' <<<"$BILLING")"
# Reading the currency needs billing.accounts.get, which project-level users may not have.
CURRENCY="$(api GET "$BILLING_API/billingAccounts/$ACCOUNT" 2>/dev/null | jq -r '.currencyCode // empty' || true)"
CAPS="{}"
find_caps || exit 1

printf '%-17s %s\n' "Project:" "$PROJECT"
printf '%-17s %s (%s)\n' "Billing account:" "$ACCOUNT" "${CURRENCY:-currency unknown}"
printf '%-17s %s\n' "Credential:" "${CREDENTIAL:-unknown}"
# No public API returns credit balances, so link to the console page instead.
printf '%-17s %s\n' "Credits:" "https://console.cloud.google.com/billing/$ACCOUNT/credits"
printf '%-17s %s\n' "" "(spend caps ignore credits)"
! $DRY_RUN || printf '%-17s %s\n' "Mode:" "dry run (nothing will change)"
echo

"cmd_$COMMAND"
