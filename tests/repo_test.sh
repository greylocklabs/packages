#!/usr/bin/env bash
# Checks build-repo.sh end to end with throwaway packages and a throwaway key:
#
#   tests/repo_test.sh build <dir>   in Debian: builds repositories into <dir>
#                                    and installs from them with apt
#   tests/repo_test.sh dnf <dir>     in Fedora: installs from <dir> with dnf
#
# <dir> must be the same absolute path in both, as the repository files name it.
# Needs root, as it installs packages; meant for CI containers.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

mode="${1:-}"
dir="${2:-}"
case "$mode" in build | dnf) ;; *)
    echo "usage: repo_test.sh <build|dnf> <dir>" >&2
    exit 2
    ;;
esac
case "$dir" in /*) ;; *)
    echo "repo_test: <dir> must be absolute" >&2
    exit 2
    ;;
esac
here="$(cd "$(dirname "$0")/.." && pwd)"

fail() {
    echo "repo_test: $*" >&2
    exit 1
}

# A deb named <file name>, holding /usr/share/<package>/<text>.
fake_deb() {
    local package="$1" version="$2" file="$3" text="$4" root
    root="$(mktemp -d)"
    mkdir -p "$root/DEBIAN" "$root/usr/share/$package"
    echo "$text" >"$root/usr/share/$package/$text"
    cat >"$root/DEBIAN/control" <<EOF
Package: $package
Version: $version
Architecture: amd64
Maintainer: Greylock Labs <hello@greylocklabs.org>
Description: repository test package
EOF
    dpkg-deb --root-owner-group --build "$root" "$file" >/dev/null
}

fake_rpm() {
    local package="$1" version="$2" out="$3" top
    top="$(mktemp -d)"
    mkdir -p "$top/SPECS"
    cat >"$top/SPECS/$package.spec" <<EOF
Name: $package
Version: $version
Release: 1
Summary: repository test package
License: MIT
BuildArch: x86_64
%description
repository test package
%install
mkdir -p %{buildroot}/usr/share/$package
echo rpm >%{buildroot}/usr/share/$package/rpm
%files
/usr/share/$package
EOF
    rpmbuild --quiet --define "_topdir $top" -bb "$top/SPECS/$package.spec" >/dev/null 2>&1 ||
        rpmbuild --define "_topdir $top" -bb "$top/SPECS/$package.spec"
    cp "$top"/RPMS/x86_64/*.rpm "$out/"
}

if [ "$mode" = build ]; then
    export GNUPGHOME
    GNUPGHOME="$(mktemp -d)"
    gpg --batch --quiet --passphrase '' --quick-generate-key \
        "Repo test <test@example.org>" rsa3072 sign never
    key="$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr/ { print $10; exit }')"

    packages="$(mktemp -d)"
    fake_deb greylock-test 1.0-1 "$packages/greylock-test_1.0-1_amd64.deb" debian
    fake_deb greylock-test 1.0-1~ubuntu26.04 \
        "$packages/greylock-test-ubuntu_1.0-1~ubuntu26.04_amd64.deb" ubuntu
    fake_rpm greylock-test 1.0 "$packages"
    # An app without an Ubuntu build, whose Debian one goes in both suites.
    fake_deb debian-only-test 1.0-1 "$packages/debian-only-test_1.0-1_amd64.deb" debian

    rm -rf "$dir"
    REPO_URL="file://$dir/greylocklabs" "$here/scripts/build-repo.sh" \
        "$packages" "$dir/greylocklabs" "$key"
    REPO_NAME=callie REPO_TITLE=Callie REPO_URL="file://$dir/callie" \
        "$here/scripts/build-repo.sh" "$packages" "$dir/callie" "$key"

    for file in greylocklabs/greylocklabs.asc greylocklabs/rpm/greylocklabs.repo \
        greylocklabs/rpm/repodata/repomd.xml.asc greylocklabs/deb/greylocklabs.sources \
        greylocklabs/deb/greylocklabs-ubuntu.sources greylocklabs/deb/dists/stable/InRelease \
        greylocklabs/deb/dists/ubuntu/InRelease callie/callie.asc callie/rpm/callie.repo \
        callie/deb/callie.sources callie/deb/callie-ubuntu.sources; do
        [ -s "$dir/$file" ] || fail "missing $file"
    done
    grep -q '^Origin: Greylock Labs$' "$dir/greylocklabs/deb/dists/stable/Release" ||
        fail "the shared repository's Origin is not Greylock Labs"
    grep -q '^Origin: Callie$' "$dir/callie/deb/dists/stable/Release" ||
        fail "the callie repository's Origin changed, which apt refuses"
    grep -q '^\[callie\]$' "$dir/callie/rpm/callie.repo" || fail "callie.repo has the wrong id"
    gpg --verify "$dir/greylocklabs/deb/dists/stable/InRelease" 2>/dev/null ||
        fail "InRelease is not signed"
    gpg --verify "$dir/greylocklabs/rpm/repodata/repomd.xml.asc" \
        "$dir/greylocklabs/rpm/repodata/repomd.xml" 2>/dev/null || fail "repomd.xml is not signed"

    # Each apt suite installs its own build, checked through the signature.
    for sources in greylocklabs.sources greylocklabs-ubuntu.sources; do
        rm -f /etc/apt/sources.list.d/greylocklabs*.sources
        cp "$dir/greylocklabs/greylocklabs.asc" /usr/share/keyrings/
        cp "$dir/greylocklabs/deb/$sources" /etc/apt/sources.list.d/
        # Root reads the repository, which apt's sandbox user may not be able to.
        apt-get update -qq -o APT::Sandbox::User=root
        apt-get install -y -qq --reinstall greylock-test >/dev/null
        case "$sources" in
        *ubuntu*) want=ubuntu ;;
        *) want=debian ;;
        esac
        [ -e "/usr/share/greylock-test/$want" ] || fail "$sources did not install the $want build"
        apt-get install -y -qq debian-only-test >/dev/null ||
            fail "$sources does not carry the app without an Ubuntu build"
        apt-get remove -y -qq greylock-test debian-only-test >/dev/null
    done
    rm -f /etc/apt/sources.list.d/greylocklabs*.sources
    echo "the apt repositories install"
else
    for name in greylocklabs callie; do
        cp "$dir/$name/rpm/$name.repo" /etc/yum.repos.d/
        dnf install -y -q --disablerepo='*' --enablerepo="$name" greylock-test >/dev/null
        [ -e /usr/share/greylock-test/rpm ] || fail "the $name dnf repository did not install"
        dnf remove -y -q greylock-test >/dev/null
        rm "/etc/yum.repos.d/$name.repo"
    done
    echo "the dnf repositories install"
fi
