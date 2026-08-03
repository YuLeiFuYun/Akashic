# Conformance status

`docs/CONFORMANCE_STATUS.json` is the machine-readable status source for `AKASHIC-CT-001` through `AKASHIC-CT-042`.

Current classification:

- fully implemented local component obligations: CT-001–015, CT-017–018, CT-020–021 and CT-027–029;
- partial local obligations: CT-016 and CT-019;
- planned host/version obligations: CT-022–026 and CT-030.

The status uses several non-equivalent labels:

- `implemented-local`: named local evidence exists;
- `implemented-local-process-crash`: actual child process termination and reopen evidence exists, but not power-loss evidence;
- `implemented-local-cross-process-lock`: kernel lock behavior was observed through another process;
- `implemented-local-scope-limited`: the stated narrow scope is tested and broader semantics are explicitly unsupported;
- `partial-*`: useful evidence exists but the obligation is not closed;
- `planned`: no implementation claim.

Component evidence cannot close Fovea host obligations. In particular, passing Akashic Disk tests does not prove ContentID projection, HTTP record transaction, namespace revocation or final delivery degradation inside Fovea.

The status rules also keep `candidateDoesNotImplyDefault=true`: implemented local evidence for an opt-in candidate does not make it the Fovea default or a release-qualified winner.
