#!/usr/bin/env bash
# ==========================================
# OCI Always Free VM Creator (fixed)
# ==========================================
set -u

PROFILE="${OCI_PROFILE:-DEFAULT}"
CONFIG="${OCI_CLI_CONFIG_FILE:-$HOME/.oci/config}"
REGION="${OCI_REGION:-ap-singapore-1}"

# Read tenancy from the profile (tolerates spaces around "=" and CRLF files)
TENANCY="$(awk -v p="[$PROFILE]" '
  { line=$0; gsub(/\r/, "", line); gsub(/^[ \t]+|[ \t]+$/, "", line) }
  line==p { f=1; next }
  line ~ /^\[/ { f=0 }
  f && line ~ /^tenancy[ \t]*=/ { sub(/^tenancy[ \t]*=[ \t]*/, "", line); print line; exit }
' "$CONFIG" 2>/dev/null)"

COMPARTMENT="${COMPARTMENT_ID:-$TENANCY}"

SHAPE_KIND="${SHAPE:-A1}"
OCPUS="${OCPUS:-1}"
MEMORY_GB="${MEMORY_GB:-6}"
BOOT_GB="${BOOT_GB:-50}"
NAME="${VM_NAME:-free-vm}"

# Retry settings (seconds)
SLEEP="${SLEEP:-300}"
RATE_LIMIT_SLEEP="${RATE_LIMIT_SLEEP:-300}"
MAX_RATE_LIMIT_SLEEP="${MAX_RATE_LIMIT_SLEEP:-3600}"
INTERNAL_ERROR_SLEEP="${INTERNAL_ERROR_SLEEP:-300}"
RATE_LIMIT_SLEEP_START="$RATE_LIMIT_SLEEP"

# Always Free A1 limits (whole tenancy)
MAX_A1_OCPUS=4
MAX_A1_MEM=24

command -v oci >/dev/null 2>&1 || { echo "ERROR: oci CLI not found."; exit 1; }

# Normal calls (CLI retries are fine for read-only lookups)
oci_() {
  oci --profile "$PROFILE" --region "$REGION" "$@"
}

# Launch/update calls: no hidden CLI retries, so this script controls timing
# and we don't hammer the API (the CLI's own retries caused extra 429s).
oci_nr_() {
  oci --profile "$PROFILE" --region "$REGION" \
      --no-retry --connection-timeout 30 --read-timeout 120 "$@"
}

# ------------------------------------------
# Helpers
# ------------------------------------------

# Classify an OCI error. ORDER MATTERS: capacity is checked before
# InternalError because OCI often returns "InternalError / Out of host
# capacity" (HTTP 500) when A1 capacity is simply unavailable.
classify() {
  local o="$1"
  if   grep -qiE 'TooManyRequests|"status": *429' <<<"$o"; then echo RATE
  elif grep -qiE 'out of (host )?capacity|OutOfHostCapacity' <<<"$o"; then echo CAPACITY
  elif grep -qiE 'LimitExceeded|QuotaExceeded' <<<"$o"; then echo LIMIT
  elif grep -qiE 'InternalError|"status": *5[0-9][0-9]|ServiceUnavailable|BadGateway|RequestException|ConnectTimeout|ReadTimeout|Max retries|Connection (reset|aborted|refused)' <<<"$o"; then echo INTERNAL
  else echo FATAL
  fi
}

# Print only the useful part of an OCI error
show_error() {
  local o="$1" code msg
  code="$(grep -oE '"code": *"[^"]*"' <<<"$o" | head -1 | sed 's/.*: *//; s/"//g')"
  msg="$(grep -oE '"message": *"[^"]*"' <<<"$o" | head -1 | sed 's/"message": *//; s/^"//; s/"$//')"
  if [[ -n "$code$msg" ]]; then
    echo "  OCI says: code=${code:-n/a} | message=${msg:-n/a}"
  else
    echo "  Raw output (first 5 lines):"
    head -5 <<<"$o" | sed 's/^/    /'
  fi
}

# Sleep with a little jitter
nap() {
  local s=$(( $1 + RANDOM % 30 ))
  echo "Sleeping ${s}s..."
  sleep "$s"
}

rate_backoff() {
  echo "Rate limit backoff."
  nap "$RATE_LIMIT_SLEEP"
  RATE_LIMIT_SLEEP=$(( RATE_LIMIT_SLEEP * 2 ))
  (( RATE_LIMIT_SLEEP > MAX_RATE_LIMIT_SLEEP )) && RATE_LIMIT_SLEEP="$MAX_RATE_LIMIT_SLEEP"
}

cmd="${1:-create}"

# ==========================================
# Resize mode
# ==========================================

if [[ "$cmd" == "resize" ]]; then

  INST="${2:?Instance OCID required}"

  NEW_OCPUS="${OCPUS_NEW:-1}"
  NEW_MEM="${MEMORY_NEW:-6}"

  if (( NEW_OCPUS < 1 || NEW_MEM < 1 || NEW_OCPUS > MAX_A1_OCPUS || NEW_MEM > MAX_A1_MEM )); then
    echo "ERROR: Exceeds configured A1 limits (max ${MAX_A1_OCPUS} OCPU / ${MAX_A1_MEM} GB)."
    exit 1
  fi

  echo "Resizing instance: $INST"
  echo "New configuration: ${NEW_OCPUS} OCPU / ${NEW_MEM} GB"

  while true; do

    out="$(oci_nr_ compute instance update \
      --instance-id "$INST" \
      --shape-config "{\"ocpus\":$NEW_OCPUS,\"memoryInGBs\":$NEW_MEM}" \
      --force 2>&1)"
    status=$?

    if (( status == 0 )); then
      echo "$out"
      echo "Resize request successful."
      exit 0
    fi

    kind="$(classify "$out")"
    echo "$(date) | Resize failed: $kind"
    show_error "$out"

    case "$kind" in
      RATE)     rate_backoff ;;
      CAPACITY) RATE_LIMIT_SLEEP="$RATE_LIMIT_SLEEP_START"; nap "$SLEEP" ;;
      INTERNAL) nap "$INTERNAL_ERROR_SLEEP" ;;
      *)        echo "FATAL: Resize failed."; echo "$out"; exit 1 ;;
    esac

  done
fi

# ==========================================
# Validate configuration
# ==========================================

: "${SUBNET_ID:?Set SUBNET_ID to your public subnet OCID}"
: "${SSH_PUBKEY_FILE:?Set SSH_PUBKEY_FILE to your public SSH key path}"

if [[ ! -f "$SSH_PUBKEY_FILE" ]]; then
  echo "ERROR: SSH public key file not found: $SSH_PUBKEY_FILE"
  exit 1
fi

if [[ -z "$TENANCY" ]]; then
  echo "ERROR: Could not read tenancy OCID from OCI config ($CONFIG, profile $PROFILE)."
  exit 1
fi

if [[ -z "$COMPARTMENT" ]]; then
  echo "ERROR: Compartment OCID is missing."
  exit 1
fi

# ==========================================
# Select shape
# ==========================================

if [[ "$SHAPE_KIND" == "A1" ]]; then

  SHAPE_NAME="VM.Standard.A1.Flex"

  if (( OCPUS < 1 || OCPUS > MAX_A1_OCPUS ||
        MEMORY_GB < 1 || MEMORY_GB > MAX_A1_MEM )); then
    echo "ERROR: Invalid A1 configuration."
    exit 1
  fi

  SHAPE_ARGS=(
    --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEMORY_GB}"
  )

else

  SHAPE_NAME="VM.Standard.E2.1.Micro"
  SHAPE_ARGS=()

fi

# ==========================================
# Display configuration
# ==========================================

echo
echo "=========================================="
echo "OCI VM CREATION"
echo "=========================================="
echo "Region: $REGION"
echo "Profile: $PROFILE"
echo "Compartment: $COMPARTMENT"
echo "Shape: $SHAPE_NAME"
echo "OCPU: $OCPUS"
echo "Memory: ${MEMORY_GB} GB"
echo "Boot volume: ${BOOT_GB} GB"
echo "Name: $NAME"
echo "Capacity retry: ${SLEEP}s"
echo "=========================================="
echo

ERR_IMG="$(mktemp)"
ERR_AD="$(mktemp)"
trap 'rm -f "$ERR_IMG" "$ERR_AD"' EXIT

# ==========================================
# Get Ubuntu image
# ==========================================

echo "Finding Ubuntu 22.04 image..."

IMAGE_ID="$(oci_ compute image list \
  --compartment-id "$COMPARTMENT" \
  --operating-system "Canonical Ubuntu" \
  --operating-system-version "22.04" \
  --shape "$SHAPE_NAME" \
  --sort-by TIMECREATED \
  --sort-order DESC \
  --query 'data[0].id' \
  --raw-output 2>"$ERR_IMG")"

if [[ -z "$IMAGE_ID" || "$IMAGE_ID" == "null" ]]; then
  echo "ERROR: Could not find compatible Ubuntu image."
  cat "$ERR_IMG"
  exit 1
fi

echo "Image: $IMAGE_ID"

# ==========================================
# Get availability domains
# ==========================================

echo "Getting availability domains..."

AD_OUTPUT="$(oci_ iam availability-domain list \
  --compartment-id "$TENANCY" \
  --query 'data[].name' \
  --raw-output 2>"$ERR_AD")"
AD_STATUS=$?

if (( AD_STATUS != 0 )); then
  echo "ERROR: Could not retrieve availability domains."
  cat "$ERR_AD"
  exit 1
fi

mapfile -t ADS < <(
  printf '%s\n' "$AD_OUTPUT" |
    tr -d '[]," ' |
    grep -v '^$'
)

if (( ${#ADS[@]} == 0 )); then
  echo "ERROR: No availability domains found."
  echo "$AD_OUTPUT"
  exit 1
fi

echo "Availability domains: ${ADS[*]}"

# Returns the OCID of a live instance with this name (empty if none).
# Prevents creating duplicates if an earlier "failed" request actually worked.
existing_instance() {
  local r
  r="$(oci_ compute instance list \
        --compartment-id "$COMPARTMENT" \
        --display-name "$NAME" \
        --query 'data[?"lifecycle-state"!=`TERMINATED` && "lifecycle-state"!=`TERMINATING`] | [0].id' \
        --raw-output 2>/dev/null)"
  [[ "$r" == "null" ]] && r=""
  echo "$r"
}

# ==========================================
# VM creation loop
# ==========================================

attempt=0

while true; do

  RATE_LIMITED=0
  INTERNAL_ERROR=0

  ex="$(existing_instance)"
  if [[ -n "$ex" ]]; then
    echo "$(date) | Instance named '$NAME' already exists: $ex"
    echo "Nothing to do. Stopping."
    exit 0
  fi

  for AD in "${ADS[@]}"; do

    attempt=$((attempt + 1))

    echo
    echo "$(date) | Attempt $attempt | AD=$AD"
    echo "Requesting VM creation..."

    out="$(oci_nr_ compute instance launch \
      --availability-domain "$AD" \
      --compartment-id "$COMPARTMENT" \
      --shape "$SHAPE_NAME" \
      ${SHAPE_ARGS[@]+"${SHAPE_ARGS[@]}"} \
      --image-id "$IMAGE_ID" \
      --subnet-id "$SUBNET_ID" \
      --assign-public-ip true \
      --boot-volume-size-in-gbs "$BOOT_GB" \
      --display-name "$NAME" \
      --ssh-authorized-keys-file "$SSH_PUBKEY_FILE" 2>&1)"
    status=$?

    # SUCCESS
    if (( status == 0 )) && [[ "$out" == *'"lifecycle-state"'* ]]; then
      echo
      echo "=========================================="
      echo "SUCCESS - VM CREATED!"
      echo "=========================================="
      echo "$out"
      echo
      echo "Instance OCID: $(grep -oE '"id": *"ocid1\.instance[^"]*"' <<<"$out" | head -1 | sed 's/.*: *//; s/"//g')"
      echo "Get its public IP in ~1-2 min with:"
      echo "  oci compute instance list-vnics --instance-id <OCID above> --query 'data[0].\"public-ip\"'"
      echo "Stopping script. No more API requests."
      exit 0
    fi

    kind="$(classify "$out")"

    case "$kind" in
      RATE)
        echo "API rate limit (429)."
        show_error "$out"
        RATE_LIMITED=1
        break
        ;;
      INTERNAL)
        echo "OCI internal/server error (5xx)."
        show_error "$out"
        INTERNAL_ERROR=1
        break
        ;;
      CAPACITY)
        echo "No capacity in $AD."
        show_error "$out"
        sleep 2
        continue
        ;;
      LIMIT)
        echo
        echo "=========================================="
        echo "FATAL: Free-tier limit/quota exceeded."
        echo "(You may already have A1 instances using your 4 OCPU / 24 GB.)"
        echo "=========================================="
        echo "$out"
        exit 1
        ;;
      *)
        echo
        echo "=========================================="
        echo "FATAL: VM creation failed."
        echo "=========================================="
        echo "$out"
        exit 1
        ;;
    esac

  done

  if (( RATE_LIMITED == 1 )); then

    rate_backoff

  elif (( INTERNAL_ERROR == 1 )); then

    # Usually capacity in disguise, so don't reset the rate-limit backoff
    echo
    nap "$INTERNAL_ERROR_SLEEP"

  else

    RATE_LIMIT_SLEEP="$RATE_LIMIT_SLEEP_START"

    echo
    echo "$(date) | All availability domains checked."
    echo "No capacity available."
    echo "Next retry in ~${SLEEP} seconds."
    nap "$SLEEP"

  fi

done
