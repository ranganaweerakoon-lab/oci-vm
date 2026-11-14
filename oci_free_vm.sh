
#!/usr/bin/env bash

# ============================================================
# ORACLE CLOUD ALWAYS FREE A1 INSTANCE HUNTER
#
# Region:       Singapore (ap-singapore-1)
# Shape:        VM.Standard.A1.Flex
# OCPU:         1
# RAM:          6 GB
# Boot Volume:  50 GB
# OS:           Ubuntu 22.04
#
# Uses existing environment variables and OCI config.
# ============================================================

set -Eeuo pipefail

# ------------------------------------------------------------
# CONFIGURATION - EXISTING VARIABLE NAMES PRESERVED
# ------------------------------------------------------------

PROFILE="${OCI_PROFILE:-DEFAULT}"
CONFIG="${OCI_CLI_CONFIG_FILE:-$HOME/.oci/config}"

REGION="${OCI_REGION:-ap-singapore-1}"

TENANCY="$(
    awk -F= -v p="[$PROFILE]" '
        $0==p { f=1; next }
        /^\[/ { f=0 }
        f && $1=="tenancy" {
            print $2
            exit
        }
    ' "$CONFIG" | tr -d ' '
)"

COMPARTMENT="${COMPARTMENT_ID:-$TENANCY}"

SHAPE_KIND="${SHAPE:-A1}"

OCPUS="${OCPUS:-1}"
MEMORY_GB="${MEMORY_GB:-6}"
BOOT_GB="${BOOT_GB:-50}"

NAME="${VM_NAME:-free-vm}"

# Existing OCI A1 Always Free allowance
MAX_A1_OCPUS=2
MAX_A1_MEM=12

# Retry settings
INITIAL_DELAY="${SLEEP:-120}"
MAX_DELAY=900
JITTER=60

# Existing files
SUCCESS_FILE="${HOME}/oci-a1-success.txt"
LOCK_FILE="/tmp/oci-a1-hunter.lock"

# ------------------------------------------------------------
# LOGGING
# ------------------------------------------------------------

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
    log "FATAL: $*"
    exit 1
}

# ------------------------------------------------------------
# LOCK - PREVENT DUPLICATE RUNNERS
# ------------------------------------------------------------

command -v flock >/dev/null 2>&1 ||
    die "flock is required."

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
    log "Another instance hunter is already running."
    exit 0
fi

# ------------------------------------------------------------
# OCI WRAPPER
# ------------------------------------------------------------

oci_() {
    oci --profile "$PROFILE" --region "$REGION" "$@"
}

# ------------------------------------------------------------
# VALIDATE CONFIGURATION
# ------------------------------------------------------------

[[ -f "$CONFIG" ]] ||
    die "OCI config not found: $CONFIG"

[[ -n "$TENANCY" ]] ||
    die "Could not retrieve tenancy OCID."

COMPARTMENT="${COMPARTMENT_ID:-$TENANCY}"

: "${SUBNET_ID:?SUBNET_ID is required}"
: "${SSH_PUBKEY_FILE:?SSH_PUBKEY_FILE is required}"

[[ -f "$SSH_PUBKEY_FILE" ]] ||
    die "SSH public key file not found."

command -v oci >/dev/null 2>&1 ||
    die "OCI CLI is not installed."

command -v python3 >/dev/null 2>&1 ||
    die "Python3 is required."

[[ "$OCPUS" =~ ^[0-9]+$ ]] ||
    die "Invalid OCPUS."

[[ "$MEMORY_GB" =~ ^[0-9]+$ ]] ||
    die "Invalid MEMORY_GB."

[[ "$BOOT_GB" =~ ^[0-9]+$ ]] ||
    die "Invalid BOOT_GB."

# ------------------------------------------------------------
# SHAPE CONFIGURATION
# ------------------------------------------------------------

if [[ "$SHAPE_KIND" == "A1" ]]; then

    SHAPE_NAME="VM.Standard.A1.Flex"

    (( OCPUS >= 1 && OCPUS <= MAX_A1_OCPUS )) ||
        die "A1 Always Free allowance: maximum 2 OCPUs."

    (( MEMORY_GB >= OCPUS && MEMORY_GB <= MAX_A1_MEM )) ||
        die "Invalid A1 memory allocation."

    (( BOOT_GB >= 47 && BOOT_GB <= 200 )) ||
        die "Invalid boot volume size."

    SHAPE_ARGS=(
        --shape-config
        "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEMORY_GB}"
    )

else

    die "This hunter is configured for A1 only. Set SHAPE=A1."

fi

# ------------------------------------------------------------
# STARTUP INFORMATION
# ------------------------------------------------------------

log "============================================"
log "ORACLE ALWAYS FREE A1 HUNTER"
log "============================================"

log "Region:       $REGION"
log "Profile:      $PROFILE"
log "Compartment:  $COMPARTMENT"
log "Shape:        $SHAPE_NAME"
log "OCPU:         $OCPUS"
log "Memory:       ${MEMORY_GB} GB"
log "Boot volume:  ${BOOT_GB} GB"
log "Name:         $NAME"

log "============================================"

# ------------------------------------------------------------
# CHECK EXISTING INSTANCE
# ------------------------------------------------------------

check_existing() {

    local result

    result="$(oci_ compute instance list \
        --compartment-id "$COMPARTMENT" \
        --all \
        --output json)" || return 1

    python3 -c '
import json, sys

name = sys.argv[1]
data = json.load(sys.stdin)

for item in data.get("data", []):
    if item.get("display-name") == name:
        state = item.get("lifecycle-state", "")
        if state != "TERMINATED":
            print(item.get("id", "") + "|" + state)
            sys.exit(0)
' "$NAME" <<< "$result"
}

EXISTING="$(check_existing)" ||
    die "Could not check existing instances."

if [[ -n "$EXISTING" ]]; then
    log "An instance with this name already exists."
    log "$EXISTING"
    exit 0
fi

# ------------------------------------------------------------
# FIND UBUNTU IMAGE
# ------------------------------------------------------------

log "Finding latest compatible Ubuntu 22.04 image..."

IMAGE_ID="$(oci_ compute image list \
    --compartment-id "$COMPARTMENT" \
    --operating-system "Canonical Ubuntu" \
    --operating-system-version "22.04" \
    --shape "$SHAPE_NAME" \
    --sort-by TIMECREATED \
    --sort-order DESC \
    --query 'data[0].id' \
    --raw-output)" ||
    die "Failed to retrieve Ubuntu image."

[[ -n "$IMAGE_ID" && "$IMAGE_ID" != "null" ]] ||
    die "No compatible Ubuntu image found."

log "Image ID: $IMAGE_ID"

# ------------------------------------------------------------
# GET AVAILABILITY DOMAINS
# ------------------------------------------------------------

log "Retrieving availability domains..."

AD_JSON="$(oci_ iam availability-domain list \
    --compartment-id "$TENANCY" \
    --output json)" ||
    die "Could not retrieve availability domains."

mapfile -t ADS < <(
    python3 -c '
import json, sys
for item in json.load(sys.stdin).get("data", []):
    print(item["name"])
' <<< "$AD_JSON"
)

(( ${#ADS[@]} > 0 )) ||
    die "No availability domains found."

log "Availability domains: ${ADS[*]}"

# ------------------------------------------------------------
# RETRY LOOP
# ------------------------------------------------------------

ATTEMPT=0
DELAY="$INITIAL_DELAY"

while true; do

    log "============================================"
    log "Starting new capacity check round."
    log "============================================"

    # Always check for an existing instance first.
    EXISTING="$(check_existing)" ||
        die "Cannot verify existing instances."

    if [[ -n "$EXISTING" ]]; then

        log "Existing instance detected!"
        printf '%s\n' "$EXISTING" | tee "$SUCCESS_FILE"
        exit 0

    fi

    for AD in "${ADS[@]}"; do

        ATTEMPT=$((ATTEMPT + 1))

        log "--------------------------------------------"
        log "Attempt: $ATTEMPT"
        log "Availability domain: $AD"
        log "Shape: $SHAPE_NAME"
        log "Configuration: ${OCPUS} OCPU / ${MEMORY_GB} GB"
        log "--------------------------------------------"

        if OUTPUT="$(oci_ compute instance launch \
            --availability-domain "$AD" \
            --compartment-id "$COMPARTMENT" \
            --shape "$SHAPE_NAME" \
            "${SHAPE_ARGS[@]}" \
            --image-id "$IMAGE_ID" \
            --subnet-id "$SUBNET_ID" \
            --assign-public-ip true \
            --boot-volume-size-in-gbs "$BOOT_GB" \
            --display-name "$NAME" \
            --ssh-authorized-keys-file "$SSH_PUBKEY_FILE" \
            --output json 2>&1)"; then

            INSTANCE_ID="$(
                python3 -c '
import json, sys
try:
    obj = json.load(sys.stdin)
    print(obj.get("data", {}).get("id", ""))
except Exception:
    pass
' <<< "$OUTPUT"
            )"

            if [[ -n "$INSTANCE_ID" ]]; then

                log "============================================"
                log "SUCCESS! INSTANCE CREATION ACCEPTED!"
                log "============================================"

                log "Instance OCID: $INSTANCE_ID"

                {
                    echo "INSTANCE_ID=$INSTANCE_ID"
                    echo "REGION=$REGION"
                    echo "SHAPE=$SHAPE_NAME"
                    echo "OCPUS=$OCPUS"
                    echo "MEMORY_GB=$MEMORY_GB"
                    echo "CREATED=$(date -Is)"
                } | tee "$SUCCESS_FILE"

                exit 0

            fi

            log "Launch response did not contain an OCID."
            log "Checking OCI to avoid duplicate launch."

            sleep 60

            EXISTING="$(check_existing)" ||
                die "Cannot verify ambiguous launch."

            if [[ -n "$EXISTING" ]]; then
                printf '%s\n' "$EXISTING" | tee "$SUCCESS_FILE"
                exit 0
            fi

            die "Ambiguous launch result. Check OCI Console."

        else

            ERROR="$OUTPUT"

            if echo "$ERROR" | grep -qiE \
                'OutOfHostCapacity|OutOfCapacity|out of (host )?capacity'; then

                log "OUT OF CAPACITY: $AD"

            elif echo "$ERROR" | grep -qiE \
                'TooManyRequests|429|InternalServerError|InternalError|ExternalServerTimeout|ExternalServerUnreachable|503|timed out|connection reset'; then

                log "TEMPORARY OCI/API ERROR"
                echo "$ERROR"

                DELAY=$((DELAY * 2))

                if (( DELAY > MAX_DELAY )); then
                    DELAY="$MAX_DELAY"
                fi

            else

                log "NON-RETRYABLE ERROR:"
                echo "$ERROR"

                die "Please check OCI configuration and permissions."

            fi

        fi

    done

    # --------------------------------------------------------
    # RANDOMIZED BACKOFF
    # --------------------------------------------------------

    RANDOM_WAIT=0

    if (( JITTER > 0 )); then
        RANDOM_WAIT=$((RANDOM % (JITTER + 1)))
    fi

    WAIT=$((DELAY + RANDOM_WAIT))

    log "No capacity available in this round."
    log "Total attempts: $ATTEMPT"
    log "Next attempt in $WAIT seconds."

    sleep "$WAIT"

    # Increase delay gradually.
    if (( DELAY < MAX_DELAY )); then

        DELAY=$((DELAY * 2))

        if (( DELAY > MAX_DELAY )); then
            DELAY="$MAX_DELAY"
        fi

    fi

done
