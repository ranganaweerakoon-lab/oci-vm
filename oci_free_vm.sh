#!/usr/bin/env bash
# Retry-create an Oracle Cloud ALWAYS FREE VM until capacity frees up.
set -u

PROFILE="${OCI_PROFILE:-DEFAULT}"
CONFIG="${OCI_CLI_CONFIG_FILE:-$HOME/.oci/config}"
TENANCY="$(awk -F= -v p="[$PROFILE]" '$0==p{f=1;next} /^\[/{f=0} f&&$1=="tenancy"{print $2}' "$CONFIG" | tr -d ' ')"
COMPARTMENT="${COMPARTMENT_ID:-$TENANCY}"

SHAPE_KIND="${SHAPE:-A1}"
OCPUS="${OCPUS:-1}"
MEMORY_GB="${MEMORY_GB:-6}"
BOOT_GB="${BOOT_GB:-50}"
SLEEP="${SLEEP:-60}"
NAME="${VM_NAME:-free-vm}"

MAX_A1_OCPUS=4
MAX_A1_MEM=24

oci_() { oci --profile "$PROFILE" "$@"; }

cmd="${1:-create}"

if [[ "$cmd" == "resize" ]]; then
  INST="${2:?instance ocid required}"
  NEW_OCPUS="${OCPUS_NEW:-4}"; NEW_MEM="${MEMORY_NEW:-24}"
  if (( NEW_OCPUS > MAX_A1_OCPUS || NEW_MEM > MAX_A1_MEM )); then
    echo "Refusing: exceeds Always Free A1 limit"; exit 1
  fi
  echo "Resizing $INST to ${NEW_OCPUS} OCPU / ${NEW_MEM} GB (instance will reboot)..."
  until oci_ compute instance update --instance-id "$INST" \
      --shape-config "{\"ocpus\":$NEW_OCPUS,\"memoryInGBs\":$NEW_MEM}" --force 2>/tmp/oci_err; do
    if grep -qiE "capacity|TooManyRequests|InternalError" /tmp/oci_err; then
      echo "$(date) resize: no capacity yet, retrying in ${SLEEP}s"; sleep "$SLEEP"
    else cat /tmp/oci_err; exit 1; fi
  done
  echo "Resize requested."
  exit 0
fi

: "${SUBNET_ID:?set SUBNET_ID to a public subnet OCID}"
: "${SSH_PUBKEY_FILE:?set SSH_PUBKEY_FILE to your public key path}"

if [[ "$SHAPE_KIND" == "A1" ]]; then
  SHAPE_NAME="VM.Standard.A1.Flex"
  if (( OCPUS > MAX_A1_OCPUS || MEMORY_GB > MAX_A1_MEM )); then
    echo "Refusing: exceeds Always Free limits"; exit 1
  fi
  SHAPE_ARGS=(--shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEMORY_GB}")
else
  SHAPE_NAME="VM.Standard.E2.1.Micro"
  SHAPE_ARGS=()
fi

IMAGE_ID="$(oci_ compute image list --compartment-id "$COMPARTMENT" \
  --operating-system "Canonical Ubuntu" --operating-system-version "22.04" \
  --shape "$SHAPE_NAME" --sort-by TIMECREATED --sort-order DESC \
  --query 'data[0].id' --raw-output)"
echo "Image: $IMAGE_ID"
[[ -z "$IMAGE_ID" || "$IMAGE_ID" == "null" ]] && { echo "No image found"; exit 1; }

mapfile -t ADS < <(oci_ iam availability-domain list --compartment-id "$TENANCY" \
  --query 'data[].name' --raw-output | tr -d '[]," ' | grep -v '^$')
echo "Availability domains: ${ADS[*]}"

attempt=0
while true; do
  for AD in "${ADS[@]}"; do
    attempt=$((attempt+1))
    echo "$(date) attempt $attempt  AD=$AD  shape=$SHAPE_NAME"
    out="$(oci_ compute instance launch \
      --availability-domain "$AD" \
      --compartment-id "$COMPARTMENT" \
      --shape "$SHAPE_NAME" "${SHAPE_ARGS[@]}" \
      --image-id "$IMAGE_ID" \
      --subnet-id "$SUBNET_ID" \
      --assign-public-ip true \
      --boot-volume-size-in-gbs "$BOOT_GB" \
      --display-name "$NAME" \
      --ssh-authorized-keys-file "$SSH_PUBKEY_FILE" 2>&1)"
    if echo "$out" | grep -q '"lifecycle-state"'; then
      echo "$out"; echo "SUCCESS - VM created."; exit 0
    fi
    if echo "$out" | grep -qiE "out of (host )?capacity|TooManyRequests|InternalError|LimitExceeded.*capacity"; then
      echo "  -> no capacity"
    else
      echo "$out"; echo "Non-capacity error, stopping."; exit 1
    fi
  done
  sleep "$SLEEP"
done
