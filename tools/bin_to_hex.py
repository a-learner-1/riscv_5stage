#!/usr/bin/env python3
"""Convert a little-endian RV32 binary image to $readmemh 32-bit words."""

from pathlib import Path
import argparse


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    data = args.input.read_bytes()
    if len(data) % 4:
        data += bytes(4 - len(data) % 4)

    words = []
    for offset in range(0, len(data), 4):
        words.append(f"{int.from_bytes(data[offset:offset + 4], 'little'):08x}")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(words) + "\n", encoding="ascii")
    print(f"wrote {len(words)} words to {args.output}")


if __name__ == "__main__":
    main()
