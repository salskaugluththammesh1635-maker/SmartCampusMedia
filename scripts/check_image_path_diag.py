"""Bind the diagnostic bit to its inputs, simulation results and routed timing."""
from datetime import datetime
from pathlib import Path
import hashlib
import json
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
READBACK = "--readback" in sys.argv
DM_FIX = "--dm-fix" in sys.argv
NAME = "image_readback_diag" if READBACK else "image_path_diag"
MARKER = "IMAGE_READBACK" if READBACK else "IMAGE_DIAG"
if DM_FIX:
    NAME, MARKER = "image_dm_fix", "IMAGE_DM_FIX"
REPORT = ROOT / "reports" / NAME


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def main():
    errors = []
    inputs = json.loads((REPORT / "build_inputs.json").read_text(encoding="utf-8-sig"))
    simulation = json.loads((REPORT / "simulation/result.json").read_text(encoding="utf-8-sig"))
    if simulation.get("status") != "passed" or {"path_boundaries", "path_full_vga"} != {
        case["name"] for case in simulation.get("tests", []) if case.get("passed")
    }:
        errors.append("Missing successful boundary / full-VGA simulation")
    for entry in inputs + simulation["sources"]:
        if sha(ROOT / entry["path"]) != entry["sha256"]:
            errors.append("Changed input: " + entry["path"])
    unit = None
    if READBACK or DM_FIX:
        unit = json.loads((REPORT / "unit/result.json").read_text(encoding="utf-8-sig"))
        if unit.get("status") != "passed":
            errors.append("Readback unit verification did not pass")
        for entry in unit["sources"]:
            if sha(ROOT / entry["path"]) != entry["sha256"]:
                errors.append("Changed unit input: " + entry["path"])

    build = (REPORT / "build.txt").read_text(encoding="utf-8", errors="replace")
    started = datetime.strptime(re.search(r"Run Date\s*=\s*(.+)", build)[1].strip(), "%a %b %d %H:%M:%S %Y")
    if MARKER+"_BIT_DONE" not in build or re.search(MARKER+r"_FAIL-|\b(?:ERROR|FATAL):", build):
        errors.append("Build did not finish bit generation cleanly")
    for entry in inputs:
        # TD prints its launch timestamp with second precision; compare at that
        # same precision. Content hashes still bind every input exactly.
        if int((ROOT / entry["path"]).stat().st_mtime) > int(started.timestamp()):
            errors.append("Input newer than build start: " + entry["path"])
    bit = ROOT / f"project/{NAME}_td_Runs/phy_1/{NAME}.bit"
    if bit.stat().st_mtime < started.timestamp() or bit.stat().st_size < 600000:
        errors.append("Stale or incomplete diagnostic bit")

    timing = (REPORT / "timing.txt").read_text(encoding="utf-8", errors="replace")
    setup = float(re.search(r"SWNS:\s+(-?[\d.]+)ns", timing)[1])
    hold = float(re.search(r"HWNS:\s+(-?[\d.]+)ns", timing)[1])
    sdr_self = re.search(
        r"(?s)Path Group\s+:\s+u_sdram_pll/pll_inst.clkc\[1\] -> u_sdram_pll/pll_inst.clkc\[1\].*?Max\s+: SWNS\s+(-?[\d.]+)ns.*?Min\s+: HWNS\s+(-?[\d.]+)ns", timing)
    self_setup, self_hold = float(sdr_self[1]), float(sdr_self[2])
    if min(self_setup, self_hold) < 0:
        errors.append("Diagnostic SDRAM self-clock timing failed")
    if "Confidence          : Routed" not in timing or "-phase 180" not in build:
        errors.append("Missing routed report or SDRAM 180-degree clock")
    project = ROOT / f"project/{NAME}_td.al"
    candidate = {
        "checkedAt": datetime.now().astimezone().isoformat(),
        "status": "evidence_invalid" if errors else "diagnostic_only_awaiting_board_feedback",
        "errors": errors, "path": str(bit.relative_to(ROOT)), "bytes": bit.stat().st_size,
        "sha256": sha(bit), "build_inputs_match": not errors,
        "project_sha256_after_build": sha(project),
        "setup_wns_ns": setup, "hold_wns_ns": hold,
        "sdram_self_setup_ns": self_setup, "sdram_self_hold_ns": self_hold,
        "timing_passed": min(setup, hold) >= 0,
        "simulation": simulation["tests"],
    }
    if unit is not None:
        candidate["readback_unit"] = unit
    if DM_FIX:
        core = json.loads((ROOT / "reports/image_real_core_sim/idle_dm_fix/result.json").read_text(encoding="utf-8-sig"))
        arbiter = json.loads((ROOT / "reports/dm_mask_fix/arbiter/result.json").read_text(encoding="utf-8-sig"))
        if core.get("status") != "passed" or core.get("checks", 0) < 614406:
            errors.append("Missing full-frame real-controller functional verification")
        if arbiter.get("status") != "passed":
            errors.append("Arbiter regression did not pass")
        for entry in core["sources"] + arbiter["sources"]:
            if sha(ROOT / entry["path"]) != entry["sha256"]:
                errors.append("Changed fix regression input: " + entry["path"])
        baseline = json.loads((ROOT / "reports/image_real_core_sim/small/result.json").read_text(encoding="utf-8-sig"))
        if baseline.get("status") != "failed" or baseline.get("errors", 0) == 0:
            errors.append("Missing captured failure of the original controller path")
        candidate["status"] = "evidence_invalid" if errors else "functional_fix_awaiting_board_feedback_timing_failed"
        candidate["errors"] = errors
        candidate["build_inputs_match"] = not errors
        candidate["real_core_checks"] = core["checks"]
        candidate["arbiter_regression"] = [{k: case[k] for k in ["name", "checks", "errors", "cases", "status"]} for case in arbiter["tests"]]
        candidate["fix"] = "Drive DQM=0 when no application write is accepted; use DQM=F only for masked make-up writes"
        feedback_path = REPORT / "board_feedback.json"
        if feedback_path.exists():
            feedback = json.loads(feedback_path.read_text(encoding="utf-8-sig"))
            if feedback.get("bit_sha256") == candidate["sha256"]:
                candidate["board_feedback"] = feedback
                if not errors and feedback.get("result") == "functional_board_pass_reported":
                    candidate["status"] = (
                        "functional_board_pass_reported" if candidate["timing_passed"]
                        else "functional_board_pass_reported_timing_failed"
                    )
    (REPORT / "candidate.json").write_text(json.dumps(candidate, indent=2), encoding="utf-8")
    print(f"IMAGE_PATH_DIAG: {candidate['status']}; self setup={self_setup}ns; overall setup={setup}ns")
    for error in errors:
        print("FAIL: " + error)
    return 1 if errors else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError, IndexError) as exc:
        print(f"FAIL: incomplete diagnostic evidence: {exc}")
        sys.exit(2)
