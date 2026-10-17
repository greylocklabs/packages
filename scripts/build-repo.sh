#!/usr/bin/env bash
# Builds a dnf and apt repository from release packages, signed with a key in
# the current GnuPG keyring:
#
#   scripts/build-repo.sh <packages dir> <output dir> <key fingerprint>
#
# The output holds <name>.asc, the public key; rpm/, with the signed packages,
# their metadata and <name>.repo; and deb/, an apt archive with Debian's
# packages in the "stable" suite, named by <name>.sources, and Ubuntu's in the
# "ubuntu" suite, named by <name>-ubuntu.sources: an app's <app>-ubuntu_*.deb
# files where it has them, and its Debian ones where it does not.
# Needs rpmsign, createrepo_c, apt-ftparchive and gpg.
#
# Settings, from the environment:
#   REPO_NAME    file and repository id prefix (default greylocklabs)
#   REPO_TITLE   the repository's name in dnf, and apt's Origin and Label
#                (default "Greylock Labs"); apt refuses updates when these change
#   REPO_URL     where the output is served (default https://packages.greylocklabs.org)
set -euo pipefail

if [ $# -ne 3 ]; then
    echo "usage: build-repo.sh <packages dir> <output dir> <key fingerprint>" >&2
    exit 2
fi
packages="$1"
out="$2"
key="$3"
name="${REPO_NAME:-greylocklabs}"
title="${REPO_TITLE:-Greylock Labs}"
site="${REPO_URL:-https://packages.greylocklabs.org}"

shopt -s nullglob
rpms=("$packages"/*.rpm)
debian=()
ubuntu=()
for deb in "$packages"/*.deb; do
    case "$(basename "$deb")" in
    *-ubuntu_*) ubuntu+=("$deb") ;;
    *) debian+=("$deb") ;;
    esac
done
for deb in "${debian[@]}"; do
    app="$(basename "$deb")"
    app="${app%%_*}"
    built=("$packages/$app-ubuntu_"*.deb)
    [ ${#built[@]} -gt 0 ] || ubuntu+=("$deb")
done
if [ ${#rpms[@]} -eq 0 ] || [ ${#debian[@]} -eq 0 ]; then
    echo "build-repo: $packages needs at least one .rpm and one Debian .deb" >&2
    exit 1
fi

mkdir -p "$out/rpm"
gpg --armor --export "$key" >"$out/$name.asc"

cp "${rpms[@]}" "$out/rpm/"
rpmsign --addsign --define "_gpg_name $key" "$out"/rpm/*.rpm >/dev/null
createrepo_c --quiet "$out/rpm"
gpg --batch --yes --local-user "$key" --armor --detach-sign "$out/rpm/repodata/repomd.xml"
cat >"$out/rpm/$name.repo" <<EOF
[$name]
name=$title
baseurl=$site/rpm/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=$site/$name.asc
EOF

# An apt suite from the debs given, with a pool of its own and the sources file
# that names it: suite <suite> <pool> <sources file> <deb>...
suite() {
    local suite="$1" pool="$2" sources="$3"
    shift 3
    mkdir -p "$out/deb/pool/$pool" "$out/deb/dists/$suite/main/binary-amd64"
    cp "$@" "$out/deb/pool/$pool/"
    (
        cd "$out/deb"
        apt-ftparchive packages "pool/$pool" >"dists/$suite/main/binary-amd64/Packages"
        gzip -9kn "dists/$suite/main/binary-amd64/Packages"
        cd "dists/$suite"
        # Written beside, as the listing would otherwise take in its own empty file.
        apt-ftparchive \
            -o "APT::FTPArchive::Release::Origin=$title" \
            -o "APT::FTPArchive::Release::Label=$title" \
            -o "APT::FTPArchive::Release::Suite=$suite" \
            -o "APT::FTPArchive::Release::Codename=$suite" \
            -o APT::FTPArchive::Release::Architectures=amd64 \
            -o APT::FTPArchive::Release::Components=main \
            release . >../Release.new
        mv ../Release.new Release
        gpg --batch --yes --local-user "$key" --clearsign -o InRelease Release
        gpg --batch --yes --local-user "$key" --armor --detach-sign -o Release.gpg Release
    )
    cat >"$out/deb/$sources" <<EOF
Types: deb
URIs: $site/deb
Suites: $suite
Components: main
Architectures: amd64
Signed-By: /usr/share/keyrings/$name.asc
EOF
}

suite stable main "$name.sources" "${debian[@]}"
suite ubuntu ubuntu "$name-ubuntu.sources" "${ubuntu[@]}"
