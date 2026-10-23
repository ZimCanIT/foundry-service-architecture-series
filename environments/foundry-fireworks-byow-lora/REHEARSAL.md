# Rehearsal checklist

Copy this file outside the repository for each rehearsal and fill in the values there. Each gate must close before the next step starts. Leave out subscription IDs, tenant IDs and personal data.

## G2 – toolchain

- [ ] `preflight.sh --stage all` output pasted below [Measured]
- [ ] `firectl version --long` and the binary's SHA-256 [Measured]
- [ ] Where `firectl` runs: native or WSL [Measured]
- [ ] `azd version`, `azure.ai.models` extension version, `azd ai models create --help` saved [Measured]
- [ ] AzCopy version and the `--azcopy-path` used [Measured]

## G3 – Fireworks

- [ ] Payment method present and spend cap set: amount ______ [Measured]
- [ ] `firectl model get -a fireworks qwen3p5-9b` shows `Tunable: true` [Measured]
- [ ] Base model licence read and shown: licence ______ [Measured]
- [ ] Dataset manifest SHA-256 values recorded [Measured]
- [ ] Training job ID ______, final state ______, duration ______ [Measured]
- [ ] Adapter downloaded; `r`, `lora_alpha`, `target_modules` recorded; `adapter.sha256` saved [Measured]

## G4 – Azure prerequisites

- [ ] Phase 1 applied; plan summary recorded [Measured]
- [ ] `Fireworks.EnableDeploy` is `Registered` [Measured]
- [ ] Global Provisioned quota covers the planned capacity, or the quota request is approved [Measured]

## G5 – registration

- [ ] `azd ai models create` completed; name ______, version ______ [Measured]
- [ ] Portal shows `Registered` [Measured]
- [ ] Local hashes after the upload match `adapter.sha256` [Measured]

## G6 – PTU approval

- [ ] Deploy dialog minimum ______ and increment ______, with the date read [Measured]
- [ ] Hourly figure ______ and its source, with the date read [Measured]
- [ ] Approver ______ has read the saved phase 2 plan; cap ______ [Measured]
- [ ] Phase 2 applied; deployment created at ______ [Measured]
- [ ] `test_keyless_call.py` result, route and the role that worked [Measured]
- [ ] `read_logs.sh` output after the call [Measured]

## G7 – teardown

- [ ] Stop plan applied (`adapters = {}`); deployment deleted at ______ [Measured]
- [ ] No `FireworksCustom` deployment remains in the portal or in `az cognitiveservices account deployment list` [Measured]
- [ ] Registration still present after the deletion: yes or no [Measured]
- [ ] Next-day cost analysis line for the resource group ______ [Measured]
