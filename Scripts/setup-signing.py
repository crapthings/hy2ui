#!/usr/bin/env python3
"""Create or reuse the private Hy2UI signing identity outside the checkout."""
from signing_identity import main, signing_lock

if __name__ == '__main__':
    with signing_lock():
        main()
