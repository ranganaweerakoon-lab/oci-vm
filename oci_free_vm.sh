
#!/usr/bin/env bash

# ============================================================
# ORACLE CLOUD ALWAYS FREE A1 INSTANCE HUNTER
# Singapore | VM.Standard.A1.Flex | 1 OCPU | 6 GB RAM
# ============================================================

set -Eeuo pipefail

# ------------------------------------------------------------
# CONFIGURATION - ORIGINAL VARIABLE NAMES PRESERVED
# ------------------------------------------------------------

PROFILE="${OCI_PROFILE:-DEFAULT}"
CONFIG="${OCI_CLI_CONFIG_FILE:-$HOME/.oci/config}"
REGION="${OCI_REGION:-ap-singapore-1}"

NAME="${VM_NAME:-free-vm}"

OCPUS="${OCPUS:-1}"
MEMORY_GB="${MEMORY_GB:-6}"
BOOT_GB="${BOOT_GB:-50}"

SHAPE_KIND="${SHAPE:-A1}"

INITIAL_DELAY="${SLEEP:-120}"
MAX_DELAY=900
JITTER=60

MAX_A1_OCPUS=2
MAX_A1_MEM=12

SUCCESS_FILE="$HOME/oci-a1-success.txt"
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
# LOCK
# ------------------------------------------------------------

command -v flock >/dev/null 2>&1 ||
    die "flock is not installed."

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
    log "Another hunter is already running."
    exit 0
fi

# ------------------------------------------------------------
# OCI WRAPPER
# ------------------------------------------------------------

oci_() {
    oci --profile "$PROFILE" --region "$REGION" "$@"
}

# ------------------------------------------------------------
# DEPENDENCIES
# ------------------------------------------------------------

command -v oci >/dev/null 2>&1 ||
    die "OCI CLI not installed."

command -v python3 >/dev/null 2>&1 ||
    die "Python3 not installed."

[[ -f "$CONFIG" ]] ||
    die "OCI configuration file not found: $CONFIG"

# ------------------------------------------------------------
# TENANCY
# ------------------------------------------------------------

TENANCY="$(
    awk -F= -v p="[$PROFILE]" '
        $0==p { found=1; next }
        /^\[/ { found=0 }
        found && $1=="tenancy" {
            print $2
            exit
        }
    ' "$CONFIG" | tr -d ' '
)"

[[ -n "$TENANCY" ]] ||
    die "Could not retrieve tenancy OCID."

COMPARTMENT="${COMPARTMENT_ID:-$TENANCY}"

# ------------------------------------------------------------
# VALIDATION
# ------------------------------------------------------------

: "${SUBNET_ID:?SUBNET_ID is required}"
: "${SSH_PUBKEY_FILE:?SSH_PUBKEY_FILE is required}"

[[ -f "$SSH_PUBKEY_FILE" ]] ||
    die "SSH public key file not found."

[[ "$OCPUS" =~ ^[0-9]+$ ]] ||
    die "Invalid OCPUS."

[[ "$MEMORY_GB" =~ ^[0-9]+$ ]] ||
    die "Invalid MEMORY_GB."

[[ "$BOOT_GB" =~ ^[0-9]+$ ]] ||
    die "Invalid BOOT_GB."

[[ "$INITIAL_DELAY" =~ ^[0-9]+$ ]] ||
    die "Invalid SLEEP."

(( INITIAL_DELAY >= 30 )) ||
    die "SLEEP must be at least 30 seconds."

# ------------------------------------------------------------
# SHAPE
# ------------------------------------------------------------

if [[ "$SHAPE_KIND" != "A1" ]]; then
    die "This script supports A1 only."
fi

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

# ------------------------------------------------------------
# STARTUP
# ------------------------------------------------------------

log "============================================"
log "ORACLE A1 ALWAYS FREE HUNTER"
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
# Exit 0: no instance found
# Exit 0 with output: existing instance found
# Exit 1: OCI/API error
# ------------------------------------------------------------

check_existing() {

    local result
    local error_file
    local status

    error_file="$(mktemp)"

    if result="$(oci_ compute instance list \
        --compartment-id "$COMPARTMENT" \
        --all \
        --output json 2>"$error_file")"; then
        status=0
    else
        status=$?
    fi

    if (( status != 0 )); then
        log "Failed to list existing instances:" >&2
        cat "$error_file" >&2
        rm -f "$error_file"
        return 1
    fi

    rm -f "$error_file"

    python3 -c '
import json
import sys

name = sys.argv[1]

try:
    data = json.load(sys.stdin)
except Exception as error:
    print("Invalid OCI JSON response:", error, file=sys.stderr)
    sys.exit(2)

for item in data.get("data", []):
    if item.get("display-name") == name:
        state = item.get("lifecycle-state", "")

        if state != "TERMINATED":
            print(item.get("id", "") + "|" + state)
            sys.exit(0)
' "$NAME" <<< "$result"
}

# ------------------------------------------------------------
# INITIAL INSTANCE CHECK
# ------------------------------------------------------------

if EXISTING="$(check_existing)"; then

    if [[ -n "$EXISTING" ]]; then
        log "Existing instance found: $EXISTING"
        exit 0
    fi

else
    die "Could not check existing instances."
fi

# ------------------------------------------------------------
# FIND UBUNTU IMAGE
# ------------------------------------------------------------

log "Finding Ubuntu 22.04 image..."

IMAGE_ID="$(oci_ compute image list \
    --compartment-id "$COMPARTMENT" \
    --operating-system "Canonical Ubuntu" \
    --operating-system-version "22.04" \
    --shape "$SHAPE_NAME" \
    --sort-by TIMECREATED \
    --sort-order DESC \
    --query 'data[0].id' \
    --raw-output)" ||
    die "Ubuntu image lookup failed."

[[ -n "$IMAGE_ID" && "$IMAGE_ID" != "null" ]] ||
    die "No compatible Ubuntu image found."

log "Ubuntu image: $IMAGE_ID"

# ------------------------------------------------------------
# AVAILABILITY DOMAINS
# ------------------------------------------------------------

log "Retrieving availability domains..."

AD_JSON="$(oci_ iam availability-domain list \
    --compartment-id "$TENANCY" \
    --output json)" ||
    die "Availability domain lookup failed."

mapfile -t ADS < <(
    python3 -c '
import json, sys
for item in json.load(sys.stdin).get("data", []):
    print(item["name"])
' <<< "$AD_JSON"
)

(( ${#ADS[@]} > 0 )) ||
    die "No availability domains returned."

log "Availability domains: ${ADS[*]}"

# ------------------------------------------------------------
# RETRY LOOP
# ------------------------------------------------------------

ATTEMPT=0
DELAY="$INITIAL_DELAY"

while true; do

    log "============================================"
    log "NEW CAPACITY CHECK ROUND"
    log "============================================"

    # Check for an existing VM before every round.

    if EXISTING="$(check_existing)"; then

        if [[ -n "$EXISTING" ]]; then
            log "Instance detected: $EXISTING"
            printf '%s\n' "$EXISTING" > "$SUCCESS_FILE"
            exit 0
        fi

    else
        die "Existing-instance check failed."
    fi

    for AD in "${ADS[@]}"; do

        ATTEMPT=$((ATTEMPT + 1))

        log "--------------------------------------------"
        log "Attempt: $ATTEMPT"
        log "AD: $AD"
        log "Shape: $SHAPE_NAME"
        log "Configuration: ${OCPUS} OCPU / ${MEMORY_GB} GB"
        log "--------------------------------------------"

        ERROR_FILE="$(mktemp)"

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
            --output json 2>"$ERROR_FILE")"; then

            INSTANCE_ID="$(
                python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get("data", {}).get("id", ""))
except Exception:
    pass
' <<< "$OUTPUT"
            )"

            rm -f "$ERROR_FILE"

            if [[ -n "$INSTANCE_ID" ]]; then

                log "============================================"
                log "SUCCESS! INSTANCE ACCEPTED!"
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

            log "Launch response has no instance OCID."
            log "Checking for an accepted launch."

            sleep 30

            if EXISTING="$(check_existing)"; then

                if [[ -n "$EXISTING" ]]; then
                    printf '%s\n' "$EXISTING" > "$SUCCESS_FILE"
                    log "Instance found: $EXISTING"
                    exit 0
                fi

            else
                die "Could not verify launch result."
            fi

            die "Ambiguous launch result. Check OCI Console."

        else

            ERROR="$(cat "$ERROR_FILE")"
            rm -f "$ERROR_FILE"

            if echo "$ERROR" | grep -qiE \
                'OutOfHostCapacity|OutOfCapacity|out of (host )?capacity'; then

                log "OUT OF CAPACITY in $AD"

            elif echo "$ERROR" | grep -qiE \
                'TooManyRequests|429|InternalServerError|InternalError|ExternalServerTimeout|ExternalServerUnreachable|503|timed out|connection reset'; then

                log "TEMPORARY API ERROR"
                echo "$ERROR"

                DELAY=$((DELAY * 2))

                if (( DELAY > MAX_DELAY )); then
                    DELAY="$MAX_DELAY"
                fi

            else

                log "NON-RETRYABLE ERROR:"
                echo "$ERROR"

                die "OCI launch failed. Check configuration."

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

    log "No capacity available."
    log "Total attempts: $ATTEMPT"
    log "Next attempt in $WAIT seconds."

    sleep "$WAIT"

    if (( DELAY < MAX_DELAY )); then

        DELAY=$((DELAY * 2))

        if (( DELAY > MAX_DELAY )); then
            DELAY="$MAX_DELAY"
        fi

    fi

done
