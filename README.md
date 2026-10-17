# greylocklabs/packages

The signed dnf and apt repository for Greylock Labs apps on Linux, served at
[packages.greylocklabs.org](https://packages.greylocklabs.org).

- `scripts/fetch-packages.sh` downloads the installable packages from each app's last 10
  releases on GitHub.
- `scripts/build-repo.sh` signs them and builds the repository: an rpm repository with
  `greylocklabs.repo`, and an apt archive with Debian's packages in the `stable` suite and
  Ubuntu's, the `*-ubuntu_*.deb` files, in the `ubuntu` suite. `REPO_NAME`, `REPO_TITLE` and
  `REPO_URL` change its file names, origin and address; callieapp.org uses them to keep serving
  the `callie` repository that existing machines know.
- `.github/workflows/pages.yml` rebuilds it hourly, and publishes when a release has come or
  gone. Run it from the Actions tab to publish right away.
- `tests/repo_test.sh` builds a repository from throwaway packages and installs from it with
  apt in Debian and dnf in Fedora, as CI does.

Packages are signed with the key `09361156310986845012EA9E3E6A2C1FAFEEECEC`, from the
`GREYLOCK_REPO_SIGNING_KEY` and `GREYLOCK_REPO_SIGNING_PASSPHRASE` organization secrets.

Commit messages follow the shared conventional style, with a scope always required. Run
`npm install` and `git config core.hooksPath .githooks` to check them locally.
