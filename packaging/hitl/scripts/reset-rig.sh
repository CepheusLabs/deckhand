#!/usr/bin/env bash
# reset-rig.sh — bring the rig to a known state before a scenario.
#
# Sequence:
#   1. PDU off → wait → on (full power cycle of the printer).
#   2. eMMC mux → printer (in case the previous run left it on host).
#   3. Wait for SSH on the printer's known IP, up to 5 minutes.
#
# This script is idempotent — running it twice in a row is fine.
# Vendor-specific PDU + mux drivers live under ./pdu and ./mux; this
# script only knows the abstract interface.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RIG_CONFIG="${HITL_RIG_CONFIG:-$HERE/../rig.env}"

if [ ! -f "$RIG_CONFIG" ]; then
    echo "::error::missing rig config at $RIG_CONFIG" >&2
    echo "expected variables: PRINTER_IP, PDU_DRIVER, PDU_OUTLET, MUX_DRIVER, MUX_PORT" >&2
    exit 2
fi
# shellcheck disable=SC1090
source "$RIG_CONFIG"

: "${PRINTER_IP:?PRINTER_IP must be set in $RIG_CONFIG}"
: "${PDU_DRIVER:?PDU_DRIVER must be set in $RIG_CONFIG}"
: "${MUX_DRIVER:?MUX_DRIVER must be set in $RIG_CONFIG}"

run_pdu() { "$HERE/pdu/$PDU_DRIVER.sh" "$@"; }
run_mux() { "$HERE/mux/$MUX_DRIVER.sh" "$@"; }

echo ":: powering off"
run_pdu off "${PDU_OUTLET:-0}"
sleep 5

echo ":: switching eMMC mux back to printer"
run_mux to-printer "${MUX_PORT:-0}"

echo ":: powering on"
run_pdu on "${PDU_OUTLET:-0}"

echo ":: waiting for SSH on $PRINTER_IP"
deadline=$((SECONDS + 300))
until nc -z -w 2 "$PRINTER_IP" 22 2>/dev/null; do
    if [ "$SECONDS" -gt "$deadline" ]; then
        echo "::error::printer at $PRINTER_IP did not come up within 300s" >&2
        exit 1
    fi
    sleep 5
done
echo ":: rig reset complete"
