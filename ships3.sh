#!/bin/sh
printf '\033c\033]0;%s\a' ships3
base_path="$(dirname "$(realpath "$0")")"
"$base_path/ships3.x86_64" "$@"
