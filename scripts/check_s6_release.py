"""Audit saved S6 evidence against current sources; timing failure is a failure."""
from pathlib import Path
from datetime import datetime
import hashlib
import json
import re
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / "reports/s6_integration"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def main():
    failures = []
    simulations = {}
    required = {
        "frontend": {"sd_protocol_default", "sd_protocol_fast", "sd_spi_ctrl", "sd_probe",
                     "fat32_reader", "bmp_parser", "img_loader", "player_ctrl"},
        "storage": {"tb_async_fifo", "tb_framebuf_arbiter", "tb_sdram_ctrl_wrap",
                    "tb_pix_reader", "tb_pix_reader_vga"},
        "simulation": {"image_player", "image_player_full"},
    }
    for suite, names in required.items():
        data = json.loads((REPORT / suite / "result.json").read_text(encoding="utf-8-sig"))
        tests = data.get("tests", [])
        good = data.get("status") == "passed" and names <= {x["name"] for x in tests}
        for source in data["sources"]:
            if sha(ROOT / source["path"]) != source["sha256"].upper():
                failures.append(f"Stale {suite} evidence: {source['path']}")
                good = False
        for test in tests:
            if not test.get("passed", test.get("status") == "passed"):
                good = False
        simulations[suite] = {"passed": good, "tests": tests}
        if not good:
            failures.append(f"Incomplete or failed {suite} regression")

    project = ROOT / "project/hdmi_td.al"
    inputs = [{"path": str(project.relative_to(ROOT)), "sha256": sha(project)}]
    # TD rewrites this attribute with a bare '&'; normalize that spelling only
    # in memory, preserving the exact project bytes used by the build.
    project_xml = project.read_text(encoding="utf-8-sig").replace(
        'Name="UsedInP&R"', 'Name="UsedInP&amp;R"')
    for entry in ET.fromstring(project_xml).findall(".//Source_Files//File"):
        path = (project.parent / entry.attrib["Path"]).resolve()
        inputs.append({"path": str(path.relative_to(ROOT)), "sha256": sha(path)})
        candidates = []
        if path.suffix == ".v" and "enc" not in path.parts:
            candidates = list((ROOT / "rtl").rglob(path.name))
        elif path.suffix in (".adc", ".sdc"):
            candidates = list((ROOT / "constraints").glob(path.name))
        if len(candidates) == 1 and sha(candidates[0]) != sha(path):
            failures.append(f"Unsynchronized project copy: {path.name}")

    timing = (REPORT / "timing.txt").read_text(encoding="utf-8", errors="replace")
    setup = float(re.search(r"SWNS:\s*(-?[\d.]+)ns", timing)[1])
    hold = float(re.search(r"HWNS:\s*(-?[\d.]+)ns", timing)[1])
    clock_checks = {
        "pixel_25MHz": r"25\.000\s+\d+\s+u_pll/pll_inst.clkc\[0\]",
        "serializer_125MHz": r"125\.000\s+\d+\s+u_pll/pll_inst.clkc\[2\]",
        "sdram_150MHz": r"150\.[\d]+\s+\d+\s+u_sdram_pll/pll_inst.clkc\[1\]",
        "sdram_shift_150MHz": r"150\.[\d]+\s+\d+\s+u_sdram_pll/pll_inst.clkc\[2\]",
    }
    clocks = {k: bool(re.search(v, timing)) for k, v in clock_checks.items()}
    if not all(clocks.values()) or "Confidence          : Routed" not in timing:
        failures.append("Missing clocks or non-routed timing report")

    build = (ROOT / "reports/s6_build.txt").read_text(encoding="utf-8", errors="replace")
    started = datetime.strptime(re.search(r"Run Date\s*=\s*(.+)", build)[1].strip(), "%a %b %d %H:%M:%S %Y")
    for source in inputs[1:]:
        if (ROOT / source["path"]).stat().st_mtime > started.timestamp():
            failures.append(f"Build source changed after TD started: {source['path']}")
    if "S6_BIT_FLOW_DONE" not in build or re.search(r"\b(?:ERROR|FATAL):|S6_FAIL-", build):
        failures.append("Build did not complete cleanly")
    bit = ROOT / "project/hdmi_td_Runs/phy_1/hdmi_td.bit"
    if not bit.exists() or bit.stat().st_size == 0 or bit.stat().st_mtime < started.timestamp():
        failures.append("Missing or stale candidate bit")
    timing_passed = setup >= 0 and hold >= 0
    result = {
        "checkedAt": datetime.now().astimezone().isoformat(),
        "status": "evidence_invalid" if failures else ("passed" if timing_passed else "blocked_by_sdram_timing"),
        "failures": failures, "simulations": simulations, "clocks": clocks,
        "timing": {"passed": timing_passed, "setupWnsNs": setup, "holdWnsNs": hold},
        "buildInputs": inputs, "candidateBit": {"path": str(bit.relative_to(ROOT)), "sha256": sha(bit)},
    }
    (REPORT / "release_check.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(f"S6: {result['status']}; setup={setup}ns; hold={hold}ns")
    for failure in failures:
        print(f"FAIL: {failure}")
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError, AttributeError, ET.ParseError) as exc:
        print(f"FAIL: incomplete evidence: {exc}")
        sys.exit(2)
