#!/bin/bash

BOT_TOKEN="8093034722:AAHNxvf15lI0TXtvY0UYToT6zsbUulwCybM"
CHAT_ID="-1002534976589"

# ============================================================
# DSU IMAGE PACKER + GOFILE + TELEGRAM
# ============================================================

set -o pipefail

PRODUCT_BASE="out/target/product"

# ---------------- Telegram ----------------
send_telegram() {
    curl -s -X POST \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d "chat_id=${CHAT_ID}" \
        --data-urlencode "text=$1" \
        -d "parse_mode=HTML" \
        > /dev/null
}

# ---------------- Logging ----------------
log() {
    echo "[$(date '+%H:%M:%S')] $1"
}

sep() {
    echo "--------------------------------------------------"
}

# ---------------- Link formatter ----------------
fmt_link() {
    local link="$1"

    if [[ -n "$link" && "$link" != "N/A" && "$link" != "null" ]]; then
        echo "<a href=\"$link\">Download</a>"
    else
        echo "N/A"
    fi
}

# ============================================================
# START
# ============================================================

clear

sep
log "DSU image packaging script started"
sep

# ============================================================
# CHECK DEPENDENCIES
# ============================================================

for cmd in curl jq zip md5sum du find; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log "ERROR: Required command not found: $cmd"

        send_telegram \
            "<b>❌ DSU Build Failed</b>

Required command missing:
<code>${cmd}</code>"

        exit 1
    fi
done

# ============================================================
# DETECT DEVICE
# ============================================================

log "Detecting device..."

DEVICE=$(find "$PRODUCT_BASE" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    ! -name generic \
    ! -name obj \
    ! -name symbols \
    -printf "%f\n" \
    | head -n 1)

PRODUCT_DIR="$PRODUCT_BASE/$DEVICE"

if [[ -z "$DEVICE" || ! -d "$PRODUCT_DIR" ]]; then
    log "ERROR: Device directory not detected."

    send_telegram \
        "<b>❌ DSU Build Failed</b>

Device directory was not detected inside:
<code>${PRODUCT_BASE}</code>"

    exit 1
fi

log "Device detected: $DEVICE"
log "Product directory: $PRODUCT_DIR"

# ============================================================
# FIND ROM BUILD ZIP
# ============================================================

sep
log "Searching for ROM build ZIP..."

ROM_ZIP=$(find "$PRODUCT_DIR" \
    -maxdepth 1 \
    -type f \
    -name "*${DEVICE}*.zip" \
    | grep -Ev "ota|symbol|target_files|DSU-" \
    | sort -r \
    | head -n 1)

if [[ ! -f "$ROM_ZIP" ]]; then
    log "ERROR: ROM build ZIP not found."

    send_telegram \
        "<b>❌ DSU Build Failed</b>

ROM build ZIP was not found for:
<code>${DEVICE}</code>"

    exit 1
fi

ROM_FILENAME=$(basename "$ROM_ZIP")
ROM_NAME="${ROM_FILENAME%.zip}"

log "ROM build found:"
log "$ROM_FILENAME"

# ============================================================
# REQUIRED IMAGES
# ============================================================

SYSTEM_IMG="$PRODUCT_DIR/system.img"
SYSTEM_EXT_IMG="$PRODUCT_DIR/system_ext.img"
VENDOR_IMG="$PRODUCT_DIR/vendor.img"
PRODUCT_IMG="$PRODUCT_DIR/product.img"
ODM_IMG="$PRODUCT_DIR/odm.img"

# ============================================================
# CHECK IMAGES
# ============================================================

sep
log "Checking required DSU images..."

MISSING_IMAGES=()

check_image() {
    local image="$1"
    local path="$2"

    if [[ -f "$path" ]]; then
        local size
        size=$(du -h "$path" | awk '{print $1}')
        log "✓ $image ($size)"
    else
        log "✗ $image NOT FOUND"
        MISSING_IMAGES+=("$image")
    fi
}

check_image "system.img"     "$SYSTEM_IMG"
check_image "system_ext.img" "$SYSTEM_EXT_IMG"
check_image "vendor.img"     "$VENDOR_IMG"
check_image "product.img"    "$PRODUCT_IMG"
check_image "odm.img"        "$ODM_IMG"

# ============================================================
# HANDLE MISSING IMAGES
# ============================================================

if [[ ${#MISSING_IMAGES[@]} -gt 0 ]]; then

    sep
    log "ERROR: Required image(s) missing!"

    MISSING_TEXT=""

    for image in "${MISSING_IMAGES[@]}"; do
        log "  - $image"
        MISSING_TEXT+="❌ ${image}"$'\n'
    done

    send_telegram \
        "<b>❌ DSU Build Failed</b>

• <b>DEVICE:</b> <code>${DEVICE}</code>
• <b>ROM:</b> <code>${ROM_FILENAME}</code>

<b>Missing DSU image(s):</b>

<code>${MISSING_TEXT}</code>

DSU package was <b>NOT</b> created or uploaded."

    exit 1
fi

log "All required images found."

# ============================================================
# CREATE DSU ZIP
# ============================================================

sep
log "Creating DSU ZIP..."

# Convert to absolute path BEFORE any cd
PRODUCT_DIR_ABS="$(realpath "$PRODUCT_DIR")"

DSU_ZIP="${PRODUCT_DIR_ABS}/DSU-${ROM_FILENAME}"

# Remove old DSU package
if [[ -f "$DSU_ZIP" ]]; then
    log "Removing existing DSU ZIP..."
    rm -f "$DSU_ZIP"
fi

log "Output:"
log "$DSU_ZIP"

START_TIME=$(date +%s)

# Create ZIP directly from product directory.
# No temporary copy required.

cd "$PRODUCT_DIR_ABS" || {
    log "ERROR: Could not enter product directory."
    exit 1
}

zip -q \
    -9 \
    "$DSU_ZIP" \
    system.img \
    system_ext.img \
    vendor.img \
    product.img \
    odm.img

ZIP_STATUS=$?

END_TIME=$(date +%s)
BUILD_TIME=$((END_TIME - START_TIME))

# ============================================================
# CHECK ZIP
# ============================================================

if [[ "$ZIP_STATUS" -ne 0 || ! -f "$DSU_ZIP" ]]; then

    log "ERROR: Failed to create DSU ZIP."

    send_telegram \
        "<b>❌ DSU Build Failed</b>

Device: <code>${DEVICE}</code>
ROM: <code>${ROM_FILENAME}</code>

Failed while creating the DSU ZIP."

    exit 1
fi

# ============================================================
# FILE INFORMATION
# ============================================================

DSU_NAME=$(basename "$DSU_ZIP")
DSU_SIZE=$(du -h "$DSU_ZIP" | awk '{print $1}')
DSU_MD5=$(md5sum "$DSU_ZIP" | awk '{print $1}')

sep
log "DSU package created successfully."
log "Package: $DSU_NAME"
log "Size: $DSU_SIZE"
log "MD5: $DSU_MD5"
log "Compression time: ${BUILD_TIME}s"

# ============================================================
# VERIFY ZIP CONTENTS
# ============================================================

log "Verifying DSU ZIP contents..."

if ! unzip -t "$DSU_ZIP" >/dev/null 2>&1; then

    log "ERROR: DSU ZIP verification failed."

    send_telegram \
        "<b>❌ DSU Build Failed</b>

Device: <code>${DEVICE}</code>
Package: <code>${DSU_NAME}</code>

ZIP integrity verification failed."

    rm -f "$DSU_ZIP"
    exit 1
fi

log "ZIP integrity verified."

# ============================================================
# GOFILE SERVER
# ============================================================

sep
log "Fetching GoFile server..."

SERVER=$(curl -s \
    --retry 3 \
    --connect-timeout 15 \
    https://api.gofile.io/servers \
    | jq -r '.data.servers[0].name')

if [[ -z "$SERVER" || "$SERVER" == "null" ]]; then

    log "ERROR: Could not obtain GoFile server."

    send_telegram \
        "<b>❌ DSU Upload Failed</b>

Device: <code>${DEVICE}</code>
Package: <code>${DSU_NAME}</code>

Could not obtain a GoFile upload server."

    exit 1
fi

log "GoFile server: $SERVER"

# ============================================================
# UPLOAD TO GOFILE
# ============================================================

sep
log "Uploading DSU ZIP to GoFile..."
log "Please wait..."

DSU_LINK=$(curl -s \
    --retry 3 \
    --connect-timeout 30 \
    -F "file=@${DSU_ZIP}" \
    "https://${SERVER}.gofile.io/uploadFile" \
    | jq -r '.data.downloadPage' 2>/dev/null)

if [[ -z "$DSU_LINK" || "$DSU_LINK" == "null" ]]; then

    log "ERROR: GoFile upload failed."

    send_telegram \
        "<b>❌ DSU Upload Failed</b>

Device: <code>${DEVICE}</code>
Package: <code>${DSU_NAME}</code>

GoFile upload failed."

    exit 1
fi

log "GoFile upload successful."
log "$DSU_LINK"

# ============================================================
# TELEGRAM
# ============================================================

sep
log "Sending Telegram notification..."

send_telegram \
"📦 | <b>DSU Package Ready!</b>

• <b>ROM</b>: ${ROM_NAME}
• <b>DEVICE</b>: ${DEVICE}
• <b>PACKAGE</b>: <code>${DSU_NAME}</code>
• <b>SIZE</b>: ${DSU_SIZE}
• <b>MD5SUM</b>: <code>${DSU_MD5}</code>

• <b>IMAGES</b>:
<code>system.img
system_ext.img
vendor.img
product.img
odm.img</code>

• <b>DSU</b>: $(fmt_link "$DSU_LINK")
"

# ============================================================
# FINISH
# ============================================================

sep
log "Telegram notification sent."
log "DSU package uploaded successfully."
log "Script finished."
sep
