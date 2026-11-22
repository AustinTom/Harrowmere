#!/usr/bin/env python3
"""Validates data/character/*.json (and the sheets in data/actors.json)
against docs/schema/character.schema.json. Needs: pip install jsonschema

Run from the repo root:  python3 tools/validate_character_data.py
"""
import json
import sys
from pathlib import Path

from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parent.parent
SCHEMA = json.loads((ROOT / "docs/schema/character.schema.json").read_text())

FILES = {
    "races.json": "race", "traits.json": "trait", "backgrounds.json": "background",
    "skills.json": "skill", "disciplines.json": "discipline", "abilities.json": "ability",
    "statuses.json": "status", "archetypes.json": "archetype",
}


def validator(defname):
    return Draft202012Validator({"$ref": f"#/$defs/{defname}", "$defs": SCHEMA["$defs"]})


def main():
    errors = 0
    for fname, defname in FILES.items():
        data = json.loads((ROOT / "data/character" / fname).read_text())
        v = validator(defname)
        for key, entry in data.items():
            for e in v.iter_errors(entry):
                errors += 1
                print(f"{fname} {key}: {'/'.join(map(str, e.path))} {e.message}")
        print(f"{fname}: {len(data)} entries")
    actors = json.loads((ROOT / "data/actors.json").read_text())
    sv, gv = validator("sheet"), validator("gen")
    for key, tpl in actors.items():
        for field, v in (("sheet", sv), ("gen", gv)):
            if field in tpl:
                for e in v.iter_errors(tpl[field]):
                    errors += 1
                    print(f"actors.json {key}.{field}: {e.message}")
    print("OK" if errors == 0 else f"{errors} errors")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
