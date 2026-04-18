#!/usr/bin/env python3
import sys
import io
import tarfile
import json
import yaml
import jsonschema

# ----------------------------
# Embedded JSON Schema
# ----------------------------
SCHEMA = {
    "type": "object",
    "required": ["files"],
    "properties": {
        "files": {
            "type": "array",
            "items": {
                "type": "object",
                "required": ["name", "content"],
                "properties": {
                    "name": {
                        "type": "string",
                        "minLength": 1
                    },
                    "content": {
                        "type": "string"
                    },
                    "mode": {
                        "type": "string",
                        "pattern": "^[0-7]{3,4}$"
                    }
                },
                "additionalProperties": False
            }
        }
    },
    "additionalProperties": False
}

# ----------------------------
# Helpers
# ----------------------------
def fail(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)

def load_yaml(path):
    try:
        with open(path, "r") as f:
            return yaml.safe_load(f)
    except Exception as e:
        fail(f"Failed to read YAML: {e}")

def validate_yaml(data):
    try:
        jsonschema.validate(instance=data, schema=SCHEMA)
    except jsonschema.exceptions.ValidationError as e:
        fail(f"Schema validation failed:\n{e}")

def parse_mode(mode_str):
    if mode_str is None:
        return 0o644
    return int(mode_str, 8)

# ----------------------------
# Main
# ----------------------------
def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <input.yaml>", file=sys.stderr)
        sys.exit(1)

    path = sys.argv[1]
    # ------------------------
    # First pass: validation
    # ------------------------
    data = load_yaml(path)
    validate_yaml(data)

    # ------------------------
    # Second pass: validation
    # ------------------------
    tar_stream = tarfile.open(fileobj=sys.stdout.buffer, mode="w|")

    for entry in data["files"]:
        name = entry["name"].lstrip("/")  # safety: no absolute paths
        content = entry["content"].encode("utf-8")
        mode = parse_mode(entry.get("mode"))

        info = tarfile.TarInfo(name=name)
        info.size = len(content)
        info.mode = mode

        tar_stream.addfile(info, io.BytesIO(content))

    tar_stream.close()

if __name__ == "__main__":
    main()

