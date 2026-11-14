
#!/usr/bin/env bash

set -u

# ==========================================
# OCI Always Free VM Creator
# ==========================================

PROFILE="${OCI_PROFILE:-DEFAULT}"
CONFIG="${OCI_CLI_CONFIG_FILE:-$HOME/.oci/config}"

REGION="${OCI_REGION:-ap-singapore-1}"

TENANCY="$(awk -F= -v p="[$PROFILE]" \
  '$0==p{f=1;next} /^\[/{f=0} f&&$1=="tenancy"{print $2}' \
  "$CONFIG" | tr -d ' ')"

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
INTERNAL_ERROR_SLEEP="${INTERNAL_ERROR_SLEEP:-600}"

# Configured A1 limits
MAX_A1_OCPUS=4
MAX_A1_MEM=24

oci_() {
  oci --profile "$PROFILE" --region "$REGION" "$@"
}

cmd="${1:-create}"

# ==========================================
# Resize mode
# ==========================================

if [[ "$cmd" == "resize" ]]; then

  INST="${2:?Instance OCID required}"

  NEW_OCPUS="${OCPUS_NEW:-1}"
  NEW_MEM="${MEMORY_NEW:-6}"

  if (( NEW_OCPUS > MAX_A1_OCPUS || NEW_MEM > MAX_A1_MEM )); then
    echo "ERROR: Exceeds configured A1 limits."
    exit 1
  fi

  echo "Resizing instance: $INST"
  echo "New configuration: ${NEW_OCPUS} OCPU / ${NEW_MEM} GB"

  RATE_LIMIT_SLEEP=300

  while true; do

    out="$(oci_ compute instance update \
      --instance-id "$INST" \
      --shape-config "{\"ocpus\":$NEW_OCPUS,\"memoryInGBs\":$NEW_MEM}" \
      --force 2>&1)"
    status=$?

    if (( status == 0 )); then
      echo "$out"
      echo "Resize request successful."
      exit 0
    fi

    if echo "$out" | grep -qiE "TooManyRequests|429|rate.?limit"; then
      echo "API rate limit. Waiting ${RATE_LIMIT_SLEEP}s..."
      sleep "$RATE_LIMIT_SLEEP"

      RATE_LIMIT_SLEEP=$((RATE_LIMIT_SLEEP * 2))
      (( RATE_LIMIT_SLEEP > MAX_RATE_LIMIT_SLEEP )) && \
        RATE_LIMIT_SLEEP="$MAX_RATE_LIMIT_SLEEP"

    elif echo "$out" | grep -qi "InternalError"; then
      echo "OCI internal error. Waiting ${INTERNAL_ERROR_SLEEP}s..."
      sleep "$INTERNAL_ERROR_SLEEP"

    elif echo "$out" | grep -qiE "out of (host )?capacity|capacity"; then
      echo "Capacity unavailable. Waiting ${SLEEP}s..."
      sleep "$SLEEP"

    else
      echo "FATAL: Resize failed."
      echo "$out"
      exit 1
    fi

  done
fi

# ==========================================
# Validate configuration
# ==========================================

: "${SUBNET_ID:?Set SUBNET_ID to your public subnet OCID}"
: "${SSH_PUBKEY_FILE:?Set SSH_PUBKEY_FILE to your public SSH key path}"

if [[ ! -f "$SSH_PUBKEY_FILE" ]]; then
  echo "ERROR: SSH public key file not found."
  exit 1
fi

if [[ -z "$TENANCY" ]]; then
  echo "ERROR: Could not read tenancy OCID from OCI config."
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
  --raw-output 2>/tmp/oci_image_err)"

if [[ -z "$IMAGE_ID" || "$IMAGE_ID" == "null" ]]; then
  echo "ERROR: Could not find compatible Ubuntu image."
  cat /tmp/oci_image_err
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
  --raw-output 2>/tmp/oci_ad_err)"
AD_STATUS=$?

if (( AD_STATUS != 0 )); then
  echo "ERROR: Could not retrieve availability domains."
  cat /tmp/oci_ad_err
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

# ==========================================
# VM creation loop
# ==========================================

attempt=0
RATE_LIMIT_SLEEP=300

while true; do

  RATE_LIMITED=0
  INTERNAL_ERROR=0

  for AD in "${ADS[@]}"; do

    attempt=$((attempt + 1))

    echo
    echo "$(date) | Attempt $attempt | AD=$AD"
    echo "Requesting VM creation..."

    out="$(oci_ compute instance launch \
      --availability-domain "$AD" \
      --compartment-id "$COMPARTMENT" \
      --shape "$SHAPE_NAME" \
      "${SHAPE_ARGS[@]}" \
      --image-id "$IMAGE_ID" \
      --subnet-id "$SUBNET_ID" \
      --assign-public-ip true \
      --boot-volume-size-in-gbs "$BOOT_GB" \
      --display-name "$NAME" \
      --ssh-authorized-keys-file "$SSH_PUBKEY_FILE" 2>&1)"
    status=$?

    # ======================================
    # SUCCESS: Stop immediately
    # ======================================

    if (( status == 0 )) && [[ "$out" == *'"lifecycle-state"'* ]]; then

      echo
      echo "=========================================="
      echo "SUCCESS - VM CREATED!"
      echo "=========================================="
      echo "$out"
      echo
      echo "Stopping script. No more API requests."
      exit 0

    fi

    # ======================================
    # API rate limit
    # ======================================

    if echo "$out" | grep -qiE "TooManyRequests|429|rate.?limit"; then

      echo "API rate limit detected."
      RATE_LIMITED=1
      break

    # ======================================
    # Internal OCI error
    # ======================================

    elif echo "$out" | grep -qi "InternalError"; then

      echo "OCI internal error detected."
      INTERNAL_ERROR=1
      break

    # ======================================
    # Capacity unavailable
    # ======================================

    elif echo "$out" | grep -qiE "out of (host )?capacity|capacity"; then

      echo "No capacity in $AD."
      continue

    # ======================================
    # Other errors
    # ======================================

    else

      echo
      echo "=========================================="
      echo "FATAL: VM creation failed."
      echo "=========================================="
      echo "$out"
      exit 1

    fi

  done

  # ========================================
  # Rate-limit backoff
  # ========================================

  if (( RATE_LIMITED == 1 )); then

    echo
    echo "Rate limit backoff: ${RATE_LIMIT_SLEEP} seconds."
    sleep "$RATE_LIMIT_SLEEP"

    RATE_LIMIT_SLEEP=$((RATE_LIMIT_SLEEP * 2))

    if (( RATE_LIMIT_SLEEP > MAX_RATE_LIMIT_SLEEP )); then
      RATE_LIMIT_SLEEP="$MAX_RATE_LIMIT_SLEEP"
    fi

  # ========================================
  # Internal error retry
  # ========================================

  elif (( INTERNAL_ERROR == 1 )); then

    echo
    echo "Waiting ${INTERNAL_ERROR_SLEEP} seconds."
    sleep "$INTERNAL_ERROR_SLEEP"

  # ========================================
  # All ADs checked: capacity retry
  # ========================================

  else

    RATE_LIMIT_SLEEP=300

    echo
    echo "$(date) | All availability domains checked."
    echo "No capacity available."
    echo "Next retry in ${SLEEP} seconds."

    sleep "$SLEEP"

  fi

done
