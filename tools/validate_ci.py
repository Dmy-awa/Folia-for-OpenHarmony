"""Structural validation for the CI workflow files.

Catches the mistakes that make a workflow silently do nothing or fail at parse
time on the runner:

  * no trigger block / no jobs / no steps
  * a step with neither `uses` nor `run`, or with both
  * a build job that never uploads an artifact
  * `secrets.*` used inside an `if:` condition (not allowed by GitHub Actions)
  * `env.RUNNER_TEMP` used instead of `runner.temp`
  * shell scripts referenced by a workflow that do not exist on disk

Also sanity-checks the shell/PowerShell build scripts exist and are non-empty.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# Windows 控制台默认是 GBK，中文与符号会直接抛 UnicodeEncodeError
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except (AttributeError, ValueError):
    pass

ROOT = Path(__file__).resolve().parent.parent
CI_DIR = ROOT / "ci"

try:
    import yaml
except ImportError:  # pragma: no cover
    print("PyYAML is required:  python -m pip install pyyaml", file=sys.stderr)
    sys.exit(2)


def load(path: Path) -> dict:
    # GitHub Actions' `on:` key is parsed as boolean True by YAML 1.1 rules
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def check_github_workflow(path: Path, problems: list[str], notes: list[str]) -> None:
    doc = load(path)
    name = path.name

    if not isinstance(doc, dict):
        problems.append(f"{name}: top level is not a mapping")
        return

    trigger = doc.get(True) if True in doc else doc.get("on")
    if trigger is None:
        problems.append(f"{name}: missing `on:` trigger block")
    else:
        keys = list(trigger.keys()) if isinstance(trigger, dict) else [str(trigger)]
        notes.append(f"{name}: triggers = {keys}")

    jobs = doc.get("jobs") or {}
    if not jobs:
        problems.append(f"{name}: no `jobs`")
        return

    for job_id, job in jobs.items():
        steps = job.get("steps") or []
        runs_on = job.get("runs-on")
        notes.append(f"{name}#{job_id}: runs-on={runs_on}, steps={len(steps)}")

        if not steps:
            problems.append(f"{name}#{job_id}: no steps")
            continue

        for idx, step in enumerate(steps, start=1):
            label = step.get("name", f"step{idx}")
            has_uses = "uses" in step
            has_run = "run" in step
            if not has_uses and not has_run:
                problems.append(f"{name}#{job_id}/{label}: neither `uses` nor `run`")
            if has_uses and has_run:
                problems.append(f"{name}#{job_id}/{label}: both `uses` and `run`")

            condition = step.get("if")
            if isinstance(condition, str) and "secrets." in condition:
                problems.append(
                    f"{name}#{job_id}/{label}: `secrets.*` used in `if:` "
                    f"(not available there; route it through a job-level env)"
                )

            script = step.get("run")
            if isinstance(script, str):
                if "env.RUNNER_TEMP" in script:
                    problems.append(
                        f"{name}#{job_id}/{label}: use `runner.temp` instead of `env.RUNNER_TEMP`"
                    )
                # referenced project scripts must exist
                for ref in re.findall(r"scripts[/\\]([\w.-]+\.(?:ps1|sh))", script):
                    if not (ROOT / "scripts" / ref).exists():
                        problems.append(f"{name}#{job_id}/{label}: missing scripts/{ref}")

        uses = [str(s.get("uses", "")) for s in steps]
        if not any("upload-artifact" in u for u in uses):
            problems.append(f"{name}#{job_id}: no artifact upload step")


def check_generic_pipeline(path: Path, problems: list[str], notes: list[str]) -> None:
    doc = load(path)
    if not isinstance(doc, dict):
        problems.append(f"{path.name}: top level is not a mapping")
        return
    for key in ("name", "triggers", "stages"):
        if key not in doc:
            problems.append(f"{path.name}: missing `{key}`")
    stages = doc.get("stages") or []
    total_jobs = 0
    for stage in stages:
        jobs = stage.get("jobs") or []
        total_jobs += len(jobs)
        if not jobs:
            problems.append(f"{path.name}: stage `{stage.get('stage')}` has no jobs")
    notes.append(f"{path.name}: stages={len(stages)}, jobs={total_jobs}")
    notes.append(
        f"{path.name}: [注意] Gitee Go 的 schema 随版本变化，"
        f"请对照官方文档核对键名（构建逻辑都在 scripts/ 里，YAML 只是壳）"
    )


def main() -> int:
    if not CI_DIR.is_dir():
        print(f"ci/ not found at {CI_DIR}", file=sys.stderr)
        return 2

    problems: list[str] = []
    notes: list[str] = []

    files = sorted(CI_DIR.glob("*.yml"))
    if not files:
        print("no workflow files found", file=sys.stderr)
        return 2

    for path in files:
        try:
            if path.name.startswith("github-actions-"):
                check_github_workflow(path, problems, notes)
            else:
                check_generic_pipeline(path, problems, notes)
        except yaml.YAMLError as e:
            problems.append(f"{path.name}: YAML parse error: {str(e)[:200]}")

    # scripts referenced anywhere must exist and be non-empty
    for s in sorted((ROOT / "scripts").glob("*")):
        if s.suffix in (".ps1", ".sh") and s.stat().st_size < 200:
            problems.append(f"scripts/{s.name}: suspiciously small ({s.stat().st_size} bytes)")

    print(f"checked {len(files)} workflow file(s) in ci/\n")
    for n in notes:
        print("  " + n)

    if problems:
        print(f"\n=== PROBLEMS ({len(problems)}) ===")
        for p in problems:
            print("  " + p)
        return 1

    print("\nno structural problems found")
    return 0


if __name__ == "__main__":
    sys.exit(main())
