"""Generate the synthetic fault-report dataset for the bring-your-own-weights LoRA root.

The reports describe faults on an invented district-heating network, Norrvik Fjärrvärme. Every record
carries four labels drawn from closed vocabularies: category, urgency, asset_class and next_action. The
data contains no real customers, people, addresses or meters.

Output, written under --out (default ./.byow-work/dataset):
  train.jsonl     600 records by default  Fireworks SFT training set (system, user and assistant messages)
  eval.jsonl      100 records by default  Fireworks SFT evaluation set, passed to the training job
  heldout.jsonl   100 records by default  never uploaded to Fireworks; used after deployment
  ood.jsonl        20 records by default  out-of-domain prompts (system and user messages only)
  manifest.json                           generator version, seed, counts, label distribution, SHA-256 per file

Held-out reports use phrasings that the training split never contains, so a held-out score measures
generalisation rather than memory. The same seed gives byte-identical JSONL files. manifest.json differs
between runs only in its creation time.

The script uses only the Python standard library. It prints an estimate of training tokens for the train
split (characters divided by four), so the cost can be checked against the live price list before a job
starts. The estimate is not a tokenizer count.

Usage:
  python make_dataset.py [--out DIR] [--seed N] [--train N] [--eval N] [--heldout N] [--ood N] [--epochs N]
  python make_dataset.py --self-test
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import random
import sys
from collections import Counter
from pathlib import Path

GENERATOR_VERSION = "1.0.0"
DEFAULT_SEED = 20261023
DEFAULT_OUT = Path(".byow-work/dataset")
DEFAULT_COUNTS = {"train": 600, "eval": 100, "heldout": 100, "ood": 20}
DESCRIPTION = "Synthetic data; no real customer, person or address."
ORGANISATION = "Norrvik Fjärrvärme, an invented district-heating cooperative"

VOCABULARIES: dict[str, list[str]] = {
    "category": [
        "heat_loss",
        "pressure_fault",
        "pump_fault",
        "leak",
        "meter_fault",
        "valve_fault",
        "controls_fault",
    ],
    "urgency": ["immediate", "same_day", "next_visit", "routine"],
    "asset_class": [
        "substation",
        "heat_exchanger",
        "circulation_pump",
        "expansion_vessel",
        "district_main",
        "service_pipe",
        "heat_meter",
        "control_valve",
    ],
    "next_action": [
        "dispatch_crew",
        "isolate_section",
        "schedule_visit",
        "remote_reset",
        "order_part",
        "log_only",
    ],
}

ASSETS_FOR_CATEGORY: dict[str, list[str]] = {
    "heat_loss": ["substation", "heat_exchanger", "district_main"],
    "pressure_fault": ["expansion_vessel", "district_main"],
    "pump_fault": ["circulation_pump"],
    "leak": ["district_main", "service_pipe"],
    "meter_fault": ["heat_meter"],
    "valve_fault": ["control_valve"],
    "controls_fault": ["substation", "control_valve"],
}

URGENCY_FOR_CATEGORY: dict[str, list[str]] = {
    "heat_loss": ["same_day", "next_visit"],
    "pressure_fault": ["same_day", "next_visit", "routine"],
    "pump_fault": ["immediate", "same_day"],
    "leak": ["immediate", "same_day"],
    "meter_fault": ["next_visit", "routine"],
    "valve_fault": ["same_day", "next_visit"],
    "controls_fault": ["same_day", "next_visit", "routine"],
}

ASSET_PREFIX = {
    "substation": "SS",
    "heat_exchanger": "HX",
    "circulation_pump": "CP",
    "expansion_vessel": "EV",
    "district_main": "DM",
    "service_pipe": "SP",
    "heat_meter": "HM",
    "control_valve": "CV",
}

# Training split wording. Templates, symptoms and cues here never appear in the held-out split.
TRAIN_SYMPTOMS = {
    "heat_loss": "outlet temperature falling below the setpoint",
    "pressure_fault": "secondary pressure dropping under load",
    "pump_fault": "pump drawing high current and tripping its overload",
    "leak": "wet patch and drip found at a joint",
    "meter_fault": "meter reading stuck at zero",
    "valve_fault": "valve not responding to commands",
    "controls_fault": "controller reporting a communications timeout",
}
TRAIN_CUES = {
    "immediate": "risk to customers, crew needed now",
    "same_day": "service degraded, fix today",
    "next_visit": "no immediate risk, book a visit",
    "routine": "trend noted, no action needed today",
}
TRAIN_TEMPLATES = [
    "Site {site}, {asset} {tag}: {symptom}. {cue}. Logged reading {reading} at {date}.",
    "Operator note for {site}. Fault on the {asset} ({tag}), {symptom}. {cue}. Last reading was {reading}.",
    "Fault raised on {date} at {site}. Asset {tag} ({asset}). Observed: {symptom}. {cue}. Reading {reading}.",
    "Morning round, {site}: {asset} {tag} reports {symptom}; {cue}; value {reading}.",
]

# Held-out wording. Different symptoms, cues and templates from the training split.
HELD_SYMPTOMS = {
    "heat_loss": "supply side running cold against the target",
    "pressure_fault": "gauge sagging when the network peaks",
    "pump_fault": "motor hot to touch and drawing excess amps",
    "leak": "moisture staining and a steady drip at a fitting",
    "meter_fault": "display frozen on zero with no pulses",
    "valve_fault": "actuator unresponsive to the control room",
    "controls_fault": "panel reports lost link with the controller",
}
HELD_CUES = {
    "immediate": "safety-critical, act now",
    "same_day": "degraded service, same-day attention",
    "next_visit": "book for the next planned visit",
    "routine": "monitor only",
}
HELD_TEMPLATES = [
    "SHIFT LOG {date} | {site} | {tag} {asset} | {symptom} | {cue} | rdg {reading}",
    "Callback from control room: {symptom} on {tag} ({asset}), site {site}, latest figure {reading}. {cue}.",
    "{reading} recorded on {tag}. Engineer on site reports {symptom}. Location {site}, asset class {asset}. {cue}.",
]

OOD_PROMPTS = [
    "Write a haiku about pine forests.",
    "What is the capital of Portugal?",
    "Give me a recipe for lentil soup.",
    "Translate good morning into German.",
    "Explain how a sourdough starter works.",
    "Summarise the rules of chess in three bullet points.",
    "Write a limerick about a cat who likes trains.",
    "Suggest three names for a bakery.",
    "How many legs does a spider have?",
    "Write a short product description for a bamboo toothbrush.",
    "Plan a three-day walking route in the Lake District.",
    "Explain the difference between a noun and a verb.",
    "What is the boiling point of water at sea level in Fahrenheit?",
    "Draft a polite email declining a meeting invitation.",
    "List five houseplants that tolerate low light.",
    "Convert 25 kilometres into miles.",
    "Write a two-line poem about autumn leaves.",
    "What were the main causes of the French Revolution?",
    "Describe a simple way to sort a list of numbers.",
    "Which planet has the most moons?",
]


def system_prompt() -> str:
    allowed = "; ".join(f"{field}: {', '.join(values)}" for field, values in VOCABULARIES.items())
    return (
        "You triage fault reports for Norrvik Fjärrvärme. Reply with one JSON object that has the keys "
        "category, urgency, asset_class and next_action. Allowed values: " + allowed + "."
    )


def next_action_for(category: str, urgency: str) -> str:
    if urgency == "immediate":
        return "isolate_section" if category == "leak" else "dispatch_crew"
    if category == "meter_fault":
        return "remote_reset"
    if category in ("pump_fault", "valve_fault") and urgency == "same_day":
        return "order_part"
    if urgency == "routine":
        return "log_only"
    return "schedule_visit"


def draw_labels(rng: random.Random) -> dict[str, str]:
    category = rng.choice(VOCABULARIES["category"])
    urgency = rng.choice(URGENCY_FOR_CATEGORY[category])
    asset_class = rng.choice(ASSETS_FOR_CATEGORY[category])
    return {
        "asset_class": asset_class,
        "category": category,
        "next_action": next_action_for(category, urgency),
        "urgency": urgency,
    }


def report_text(rng: random.Random, family: str, labels: dict[str, str]) -> str:
    if family == "heldout":
        templates, symptoms, cues = HELD_TEMPLATES, HELD_SYMPTOMS, HELD_CUES
    else:
        templates, symptoms, cues = TRAIN_TEMPLATES, TRAIN_SYMPTOMS, TRAIN_CUES
    asset_name = labels["asset_class"].replace("_", " ")
    tag = f"{ASSET_PREFIX[labels['asset_class']]}-{rng.randint(1, 30):02d}"
    return rng.choice(templates).format(
        site=f"SUB-{rng.randint(100, 999)}",
        asset=asset_name,
        tag=tag,
        symptom=symptoms[labels["category"]],
        cue=cues[labels["urgency"]][0].upper() + cues[labels["urgency"]][1:],
        reading=f"{rng.uniform(10.0, 95.0):.1f}",
        date=f"2026-{rng.randint(1, 10):02d}-{rng.randint(1, 28):02d}",
    )


def labelled_record(text: str, labels: dict[str, str]) -> dict:
    assistant = json.dumps(labels, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return {
        "messages": [
            {"role": "system", "content": system_prompt()},
            {"role": "user", "content": text},
            {"role": "assistant", "content": assistant},
        ]
    }


def build_split(name: str, count: int, seed: int, seen: set[str]) -> list[dict]:
    rng = random.Random(f"{seed}:{name}")
    records: list[dict] = []
    if name == "ood":
        prompts = OOD_PROMPTS[:]
        rng.shuffle(prompts)
        for index in range(count):
            base = prompts[index % len(prompts)]
            text = base if index < len(prompts) else f"{base} (variant {index // len(prompts) + 1})"
            records.append({"messages": [
                {"role": "system", "content": system_prompt()},
                {"role": "user", "content": text},
            ]})
        return records
    family = "heldout" if name == "heldout" else "train"
    while len(records) < count:
        labels = draw_labels(rng)
        text = report_text(rng, family, labels)
        if text in seen:
            continue
        seen.add(text)
        records.append(labelled_record(text, labels))
    return records


def serialise(records: list[dict]) -> bytes:
    lines = [json.dumps(r, ensure_ascii=False, sort_keys=True, separators=(",", ":")) for r in records]
    return ("\n".join(lines) + "\n").encode("utf-8")


def build_splits(seed: int, counts: dict[str, int]) -> dict[str, list[dict]]:
    seen: set[str] = set()
    return {name: build_split(name, counts[name], seed, seen) for name in ("train", "eval", "heldout", "ood")}


def content_characters(records: list[dict]) -> int:
    return sum(len(m["content"]) for r in records for m in r["messages"])


def label_distribution(records: list[dict]) -> dict[str, dict[str, int]]:
    counts: dict[str, Counter] = {field: Counter() for field in VOCABULARIES}
    for record in records:
        labels = json.loads(record["messages"][-1]["content"])
        for field in VOCABULARIES:
            counts[field][labels[field]] += 1
    return {field: {value: counts[field].get(value, 0) for value in VOCABULARIES[field]} for field in VOCABULARIES}


def is_labelled(records: list[dict]) -> bool:
    return records[0]["messages"][-1]["role"] == "assistant"


def self_test() -> int:
    checks: list[dict] = []

    def record(name: str, ok: bool, detail: str = "") -> None:
        checks.append({"check": name, "passed": ok, "detail": detail})

    small = {"train": 40, "eval": 10, "heldout": 10, "ood": 5}
    first = build_splits(DEFAULT_SEED, small)
    second = build_splits(DEFAULT_SEED, small)
    different = build_splits(DEFAULT_SEED + 1, small)
    same_bytes = all(serialise(first[n]) == serialise(second[n]) for n in first)
    record("same seed gives identical bytes", same_bytes)
    record("different seed changes the train split", serialise(first["train"]) != serialise(different["train"]))

    allowed_ok = True
    for name in ("train", "eval", "heldout"):
        for rec in first[name]:
            roles = [m["role"] for m in rec["messages"]]
            if roles != ["system", "user", "assistant"]:
                allowed_ok = False
            labels = json.loads(rec["messages"][-1]["content"])
            if set(labels) != set(VOCABULARIES):
                allowed_ok = False
            for field, values in VOCABULARIES.items():
                if labels.get(field) not in values:
                    allowed_ok = False
    record("every label is in its vocabulary and every record has three roles", allowed_ok)

    ood_ok = all([m["role"] for m in r["messages"]] == ["system", "user"] for r in first["ood"])
    record("ood records have no assistant message", ood_ok)

    train_texts = {m["content"] for r in first["train"] + first["eval"] for m in r["messages"] if m["role"] == "user"}
    held_texts = {m["content"] for r in first["heldout"] for m in r["messages"] if m["role"] == "user"}
    record("held-out reports share no text with train or eval", not (train_texts & held_texts))

    template_overlap = set(TRAIN_TEMPLATES) & set(HELD_TEMPLATES)
    record("held-out templates differ from training templates", not template_overlap)

    counts_ok = all(len(first[n]) == small[n] for n in small)
    record("split sizes match the requested counts", counts_ok)

    failed = [c for c in checks if not c["passed"]]
    print(json.dumps({"self_test": "passed" if not failed else "failed", "checks": checks}, indent=2, ensure_ascii=False))
    return 1 if failed else 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="Output folder. Default: ./.byow-work/dataset.")
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED, help="Seed for every split. Default: 20261023.")
    parser.add_argument("--train", type=int, default=DEFAULT_COUNTS["train"], help="Records in train.jsonl (at least 1).")
    parser.add_argument("--eval", type=int, default=DEFAULT_COUNTS["eval"], help="Records in eval.jsonl (at least 1).")
    parser.add_argument("--heldout", type=int, default=DEFAULT_COUNTS["heldout"], help="Records in heldout.jsonl (at least 1).")
    parser.add_argument("--ood", type=int, default=DEFAULT_COUNTS["ood"], help="Records in ood.jsonl (at least 0).")
    parser.add_argument("--epochs", type=int, default=1, help="Epochs for the token estimate. Default: 1.")
    parser.add_argument("--self-test", action="store_true", help="Check determinism, vocabularies and split separation, then exit.")
    args = parser.parse_args(argv)

    if args.self_test:
        return self_test()

    counts = {"train": args.train, "eval": args.eval, "heldout": args.heldout, "ood": args.ood}
    if min(args.train, args.eval, args.heldout) < 1 or args.ood < 0 or args.epochs < 1:
        print(json.dumps({"error": "train, eval and heldout must be at least 1, ood at least 0, epochs at least 1"}))
        return 2

    splits = build_splits(args.seed, counts)
    out: Path = args.out
    out.mkdir(parents=True, exist_ok=True)

    manifest_splits: dict[str, dict] = {}
    for name, records in splits.items():
        data = serialise(records)
        path = out / f"{name}.jsonl"
        path.write_bytes(data)
        entry: dict = {
            "file": path.name,
            "records": len(records),
            "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
            "labelled": is_labelled(records),
        }
        if entry["labelled"]:
            entry["label_distribution"] = label_distribution(records)
        manifest_splits[name] = entry

    characters = content_characters(splits["train"])
    tokens_estimate = characters // 4
    estimate = {
        "basis": "characters of message content in train.jsonl divided by four; an estimate, not a tokenizer count",
        "train_characters": characters,
        "train_tokens_estimate": tokens_estimate,
        "epochs": args.epochs,
        "train_tokens_times_epochs_estimate": tokens_estimate * args.epochs,
    }

    manifest = {
        "generator": "make_dataset.py",
        "generator_version": GENERATOR_VERSION,
        "seed": args.seed,
        "counts": counts,
        "organisation": ORGANISATION,
        "description": DESCRIPTION,
        "created_utc": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "vocabularies": VOCABULARIES,
        "splits": manifest_splits,
        "training_token_estimate": estimate,
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8", newline="\n")

    print(json.dumps({
        "out": str(out.resolve()),
        "seed": args.seed,
        "files": {name: {"records": e["records"], "sha256": e["sha256"]} for name, e in manifest_splits.items()},
        "training_token_estimate": estimate,
    }, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
