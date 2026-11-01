#!/usr/bin/env python3
"""compute.py — a small deterministic compute step for the teleport demo."""
import hashlib

total = sum(i * i for i in range(1000))
print(f"sum of squares 0..999 = {total}")
print("sha256 of that:", hashlib.sha256(str(total).encode()).hexdigest())
