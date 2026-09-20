#!/usr/bin/env bash
set -euo pipefail
sed -i $'s/\t-\t-$/\t2035-04-05T06:07:08Z\t-/' "$1"
