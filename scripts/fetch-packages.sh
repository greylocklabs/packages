#!/usr/bin/env bash
# Downloads the installable packages from each app's recent releases, and
# prints the release tags it took, one "<app> <tag>" per line:
#
#   scripts/fetch-packages.sh <packages dir> <app>...
#
# Takes the last 10 releases of greylocklabs/<app>, leaving out drafts,
# pre-releases, source rpms and debug packages. Needs gh, signed in.
set -euo pipefail

if [ $# -lt 2 ]; then
    echo "usage: fetch-packages.sh <packages dir> <app>..." >&2
    exit 2
fi
dir="$1"
shift
mkdir -p "$dir"

for app in "$@"; do
    for tag in $(gh release list --repo "greylocklabs/$app" --limit 10 \
        --exclude-drafts --exclude-pre-releases --json tagName -q '.[].tagName'); do
        gh release download "$tag" --repo "greylocklabs/$app" --dir "$dir" --skip-existing \
            --pattern "$app-[0-9]*.x86_64.rpm" --pattern "${app}_*_amd64.deb" \
            --pattern "$app-ubuntu_*_amd64.deb"
        echo "$app $tag"
    done
done
