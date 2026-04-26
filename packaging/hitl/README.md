# Hardware-in-the-loop rig setup

This directory holds the scaffolding for Deckhand's HITL CI:
scenarios, helper scripts, and the BOM for a self-hosted rig. The
high-level design lives in
[`docs/HITL.md`](../../docs/HITL.md); this README is the
hands-on guide for someone setting up a rig.

## What you need

| Component | Purpose | Notes |
|-----------|---------|-------|
| Mini-PC (Intel NUC, Mac mini, or similar) | Hosts the GitHub Actions self-hosted runner | One per OS in the rig matrix (linux/macos/windows) |
| Klipper-class printer | The system under test | We use the Sovol Zero — small eMMC, fast Python rebuild |
| Ethernet between mini-PC and printer | Reliable network for SSH + image downloads | Don't use Wi-Fi; captive portals + handover delays mask real bugs |
| eMMC adapter with USB switch | Lets the rig flash the eMMC without a human | We use a custom board built around an Adafruit USB hub IC; any commandable USB switch works |
| Network-controllable PDU | Power-cycle the printer between flows + simulate power loss | TP-Link Tapo P110 (no model dependency in scripts — abstracts behind `power_on` / `power_off` calls) |

## Repo layout under `packaging/hitl/`

```
packaging/hitl/
├── README.md            # this file
├── bin/                 # built artifacts (sidecar, helper, headless driver) — gitignored
├── scenarios/           # YAML scenario files, one per (rig, flow) pair
│   ├── linux/
│   │   ├── stock-keep.yaml
│   │   ├── fresh-flash.yaml
│   │   ├── sentinel-test.yaml
│   │   └── snapshot-test.yaml
│   ├── macos/  (same set)
│   └── windows/  (same set)
└── scripts/
    ├── reset-rig.sh         # PDU off → on → wait for SSH; eMMC mux to printer
    ├── open-broken-issue.sh # nightly-failure GitHub issue manager
    ├── pdu/                 # vendor-specific PDU drivers (only the abstract interface is portable)
    └── mux/                 # vendor-specific eMMC mux drivers
```

`bin/` is populated by the `hitl.yml` workflow at run time; the
git-tracked files are scenarios + scripts only.

## Scenario file shape

See the example scenarios under `scenarios/<rig>/`. A scenario is a
declarative description of:

- which printer to talk to (host, credentials env-mapping)
- which profile + flow to run
- the wizard decisions to feed
- the post-install assertions to evaluate

The headless driver (`cmd/deckhand-hitl/main.dart`) reads the
scenario, drives the wizard controller without the UI, and writes
artifacts to `--output-dir`.

## Running locally

The HITL workflow runs against self-hosted runners in CI, but a
maintainer with a connected printer can drive a scenario locally:

```sh
# Build everything
./packaging/hitl/scripts/build-rig.sh

# Run one scenario
./packaging/hitl/bin/deckhand-hitl \
  --scenario packaging/hitl/scenarios/linux/stock-keep.yaml \
  --sidecar-path packaging/hitl/bin/deckhand-sidecar \
  --helper-path packaging/hitl/bin/deckhand-elevated-helper \
  --output-dir ./tmp-hitl
```

The output directory will contain the session log, the on-printer
run-state file fetched after the run, the sidecar's stderr capture,
the result of the final `disks.list`, and (on failure) a debug
bundle assembled by the same redactor users get.

## Adding a printer to the matrix

1. Wire up the printer to the rig (Ethernet + eMMC adapter +
   PDU outlet).
2. Add a scenario for each flow under
   `scenarios/<rig>/<printer-id>-<flow>.yaml`.
3. Update `hitl.yml`'s matrix to include the new flow names.
4. Test locally end-to-end before merging.

The PDU and mux drivers are pluggable — see `scripts/pdu/README.md`
(pending) for the interface.
