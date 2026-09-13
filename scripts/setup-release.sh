#!/usr/bin/env bash
# One-time release setup for regex-parity, run by the repository owner from a clone.
#
#   bash scripts/setup-release.sh                    every registry, asking before each
#   bash scripts/setup-release.sh pypi nuget         only these: go pypi rubygems nuget npm crates maven
#   bash scripts/setup-release.sh status             what is set up already
#   DRY_RUN=1 bash scripts/setup-release.sh          show what would change, change nothing
#
# For each registry it opens the page where only you can act, shows the exact values to enter and
# waits. Then it stores what .github/workflows/release.yml needs, as GitHub variables and environment
# secrets. At the end it offers to tag the release.
#
# Secrets are read without echo and handed to gh on standard input, so they never appear on screen,
# in shell history, in process arguments or on disk.
#
# Needs gh, logged in as an admin of the repository; gpg only for Maven Central signing.
# Runs on the bash 3.2 that ships with macOS. NO_BROWSER=1 prints links instead of opening them.
set -euo pipefail

REPO="${REPO:-YauhenBichel/regex-parity}"
OWNER="${REPO%%/*}"
NAME="${REPO#*/}"
WORKFLOW="release.yml"
DRY_RUN="${DRY_RUN:-0}"
NO_BROWSER="${NO_BROWSER:-0}"
ALL="go pypi rubygems nuget npm crates maven"
VERSION=""

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
say() { printf '%s\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
die() {
  printf '\033[31m%s\033[0m\n' "$*" >&2
  exit 1
}

ask_yes() { # ask_yes QUESTION [DEFAULT y|n]
  local default="${2:-y}" answer="" prompt="[Y/n]"
  [ "$default" = n ] && prompt="[y/N]"
  read -r -p "$1 $prompt " answer || true
  answer="${answer:-$default}"
  case "$answer" in
    [Yy]*) return 0 ;;
    *) return 1 ;;
  esac
}

ask() { # ask PROMPT: prints the (non-empty) answer
  local answer=""
  while [ -z "$answer" ]; do
    read -r -p "$1 " answer || die "no answer"
  done
  printf '%s' "$answer"
}

pause() { read -r -p "  Press Enter once that is saved (Ctrl-C stops here) " _ || true; }

open_url() {
  say "  $1"
  [ "$NO_BROWSER" = 1 ] && return 0
  if command -v open >/dev/null 2>&1; then
    open "$1" >/dev/null 2>&1 || true
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$1" >/dev/null 2>&1 || true
  fi
}

lowercase() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

http_ok() { [ "$(curl -s -o /dev/null -w '%{http_code}' -m 20 -A "regex-parity release setup ($REPO)" "$1")" = 200 ]; }

variable() { # prints the variable's value, or nothing when it is not set
  local value
  if value=$(gh api "repos/$REPO/actions/variables/$1" --jq .value 2>/dev/null); then
    printf '%s' "$value"
  fi
}

set_variable() { # set_variable NAME VALUE
  if [ "$DRY_RUN" = 1 ]; then
    say "  (dry run) would set variable $1 = $2"
  else
    gh variable set "$1" --body "$2" --repo "$REPO" >/dev/null
    say "  variable $1 = $2"
  fi
}

secret_exists() { gh api "repos/$REPO/environments/$1/secrets/$2" >/dev/null 2>&1; }

store_secret() { # store_secret ENVIRONMENT NAME PROMPT: reads it without echo
  local value=""
  while [ -z "$value" ]; do
    IFS= read -r -s -p "  $3: " value || die "no answer"
    printf '\n'
    [ -z "$value" ] && warn "  That was empty; try again."
  done
  if [ "$DRY_RUN" = 1 ]; then
    say "  (dry run) would store secret $2 in environment $1 (${#value} characters)"
  else
    printf '%s' "$value" | gh secret set "$2" --env "$1" --repo "$REPO" >/dev/null
    say "  secret $2 stored in environment $1"
  fi
  value=""
}

store_piped_secret() { # store_piped_secret ENVIRONMENT NAME: the value arrives on stdin
  if [ "$DRY_RUN" = 1 ]; then
    cat >/dev/null
    say "  (dry run) would store secret $2 in environment $1"
  else
    gh secret set "$2" --env "$1" --repo "$REPO" >/dev/null
    say "  secret $2 stored in environment $1"
  fi
}

delete_secret() { # delete_secret ENVIRONMENT NAME
  if [ "$DRY_RUN" = 1 ]; then
    say "  (dry run) would delete secret $2 from environment $1"
  else
    gh secret delete "$2" --env "$1" --repo "$REPO" >/dev/null
    say "  secret $2 deleted from environment $1"
  fi
}

skip_if_done() { # skip_if_done VARIABLE: succeeds (skip) when it is already true and you keep it
  [ "$(variable "$1")" = true ] || return 1
  if ask_yes "  $1 is already true. Go through this registry again?" n; then
    return 1
  fi
  say "  Kept as it is."
  return 0
}

form_values() { # form_values ENVIRONMENT
  say "  Enter exactly:"
  say "    Repository owner       $OWNER"
  say "    Repository name        $NAME"
  say "    Workflow file          $WORKFLOW"
  say "    Environment            $1"
}

# ------------------------------------------------------------------------------------ registries --

setup_go() {
  bold "Go  (github.com/$REPO/go)"
  say "  Nothing to set up: a tag go/vX.Y.Z is the release, and the release workflow creates it."
  local escaped
  escaped=$(printf '%s' "$REPO" | sed 's/[A-Z]/!&/g' | tr '[:upper:]' '[:lower:]')
  say "  On proxy.golang.org now: $(curl -s -m 20 "https://proxy.golang.org/github.com/$escaped/go/@v/list" | tr '\n' ' ')"
}

setup_pypi() {
  bold "PyPI  (regex-parity)"
  skip_if_done PUBLISH_PYPI && return 0
  say "  Log in to PyPI and add a pending trusted publisher (choose GitHub):"
  open_url "https://pypi.org/manage/account/publishing/"
  say "    PyPI project name      regex-parity"
  form_values pypi
  pause
  set_variable PUBLISH_PYPI true
}

setup_rubygems() {
  bold "RubyGems  (regex-parity)"
  skip_if_done PUBLISH_RUBYGEMS && return 0
  say "  Log in to RubyGems and create a pending trusted publisher (GitHub Actions):"
  open_url "https://rubygems.org/profile/oidc/pending_trusted_publishers/new"
  say "    Gem name               regex-parity"
  form_values rubygems
  pause
  set_variable PUBLISH_RUBYGEMS true
}

setup_nuget() {
  bold "NuGet  (RegexParity)"
  skip_if_done PUBLISH_NUGET && return 0
  say "  Log in to NuGet and create a Trusted Publishing policy (GitHub Actions):"
  open_url "https://www.nuget.org/account/trustedpublishing"
  form_values nuget
  pause
  set_variable NUGET_USER "$(ask "  Your nuget.org user name (the policy's owner):")"
  set_variable PUBLISH_NUGET true
}

setup_npm() {
  bold "npm  (regex-parity)"
  if http_ok "https://registry.npmjs.org/regex-parity"; then
    say "  regex-parity is on npm, so it can switch to trusted publishing:"
    open_url "https://www.npmjs.com/package/regex-parity/access"
    say "  Trusted Publisher → GitHub Actions:"
    form_values npm
    pause
    if secret_exists npm NPM_TOKEN && ask_yes "  Delete the NPM_TOKEN secret, which is no longer needed?" y; then
      delete_secret npm NPM_TOKEN
    fi
    set_variable PUBLISH_NPM true
    return 0
  fi
  skip_if_done PUBLISH_NPM && return 0
  say "  npm adds a trusted publisher only to a package that exists, so the first release uses a token."
  local user
  user=$(ask "  Your npmjs.com user name:")
  open_url "https://www.npmjs.com/settings/$user/tokens/granular-access-tokens/new"
  say "  Generate a granular access token:"
  say "    Token name             regex-parity first release"
  say "    Expiration             7 days"
  say "    Packages and scopes    Read and write, all packages"
  say "    If your account needs two-factor authentication to publish, allow the token to bypass it."
  store_secret npm NPM_TOKEN "Paste the token"
  set_variable PUBLISH_NPM true
  say "  After the first release, run: bash scripts/setup-release.sh npm  (it switches npm to trusted publishing)"
}

setup_crates() {
  bold "crates.io  (regex-parity)"
  if http_ok "https://crates.io/api/v1/crates/regex-parity"; then
    say "  regex-parity is on crates.io, so it can switch to trusted publishing:"
    open_url "https://crates.io/crates/regex-parity/settings"
    say "  Trusted Publishing → Add → GitHub:"
    form_values crates-io
    pause
    if secret_exists crates-io CARGO_REGISTRY_TOKEN && ask_yes "  Delete the CARGO_REGISTRY_TOKEN secret, which is no longer needed?" y; then
      delete_secret crates-io CARGO_REGISTRY_TOKEN
    fi
    set_variable PUBLISH_CRATES true
    return 0
  fi
  skip_if_done PUBLISH_CRATES && return 0
  say "  crates.io adds a trusted publisher only to a crate that exists, so the first release uses a token."
  open_url "https://crates.io/settings/tokens/new"
  say "  Create an API token:"
  say "    Name                   regex-parity first release"
  say "    Expiration             7 days"
  say "    Scopes                 publish-new, publish-update"
  say "    Crates                 regex-parity"
  store_secret crates-io CARGO_REGISTRY_TOKEN "Paste the token"
  set_variable PUBLISH_CRATES true
  say "  After the first release, run: bash scripts/setup-release.sh crates  (it switches to trusted publishing)"
}

setup_maven() {
  bold "Maven Central  (io.github.$(lowercase "$OWNER"):regex-parity)"
  skip_if_done PUBLISH_MAVEN && return 0
  if ! command -v gpg >/dev/null 2>&1; then
    warn "  Maven Central needs signed releases, and gpg is not installed."
    warn "  Install GnuPG (https://gnupg.org/download/, or: brew install gnupg), then run:"
    warn "    bash scripts/setup-release.sh maven"
    return 0
  fi
  say "  1. Sign in with GitHub. The namespace io.github.$(lowercase "$OWNER") should show as verified:"
  open_url "https://central.sonatype.com/publishing/namespaces"
  pause
  say "  2. Generate a user token (View Account → Generate User Token), then paste its two halves:"
  open_url "https://central.sonatype.com/usertoken"
  store_secret maven-central MAVEN_CENTRAL_USERNAME "Token username"
  store_secret maven-central MAVEN_CENTRAL_PASSWORD "Token password"

  say "  3. A key to sign releases with."
  local fingerprint="" passphrase="" again="" email="" name
  if ask_yes "  Create a new signing key for regex-parity releases?" y; then
    email=$(ask "  Email address for the key:")
    name=$(gh api user --jq '.name // .login')
    while :; do
      IFS= read -r -s -p "  Passphrase for the new key: " passphrase || die "no answer"
      printf '\n'
      IFS= read -r -s -p "  The same passphrase again: " again || die "no answer"
      printf '\n'
      [ -n "$passphrase" ] && [ "$passphrase" = "$again" ] && break
      warn "  Empty, or the two did not match; try again."
    done
    again=""
    if [ "$DRY_RUN" = 1 ]; then
      say "  (dry run) would create an ed25519 signing key for $name <$email>"
      fingerprint="DRY-RUN"
    else
      printf '%s' "$passphrase" | gpg --batch --pinentry-mode loopback --passphrase-fd 0 \
        --quick-generate-key "$name (regex-parity releases) <$email>" ed25519 sign 3y
      fingerprint=$(gpg --list-secret-keys --with-colons "<$email>" | awk -F: '/^fpr:/ { print $10 }' | tail -n 1)
      say "  created key $fingerprint"
    fi
  else
    gpg --list-secret-keys --keyid-format long
    fingerprint=$(ask "  Fingerprint of the key to use:")
    IFS= read -r -s -p "  Its passphrase: " passphrase || die "no answer"
    printf '\n'
  fi

  if [ "$DRY_RUN" = 1 ]; then
    say "  (dry run) would send the public key to keyserver.ubuntu.com and keys.openpgp.org"
  else
    for server in hkps://keyserver.ubuntu.com hkps://keys.openpgp.org; do
      if gpg --keyserver "$server" --send-keys "$fingerprint" >/dev/null 2>&1; then
        say "  public key sent to ${server#hkps://}"
      else
        warn "  could not send the public key to ${server#hkps://}; Maven Central checks signatures against these servers"
      fi
    done
  fi
  printf '%s' "$passphrase" | {
    if [ "$DRY_RUN" = 1 ]; then cat >/dev/null; else
      gpg --batch --pinentry-mode loopback --passphrase-fd 0 --armor --export-secret-keys "$fingerprint"
    fi
  } | store_piped_secret maven-central SIGNING_KEY
  printf '%s' "$passphrase" | store_piped_secret maven-central SIGNING_PASSWORD
  passphrase=""
  set_variable PUBLISH_MAVEN true
}

# -------------------------------------------------------------------------------- status, release --

status() {
  bold "Release setup for $REPO (version $VERSION on main)"
  local name value environment secret
  for name in PUBLISH_PYPI PUBLISH_RUBYGEMS PUBLISH_NUGET NUGET_USER PUBLISH_NPM PUBLISH_CRATES PUBLISH_MAVEN; do
    value=$(variable "$name")
    printf '  %-42s %s\n' "$name" "${value:-not set}"
  done
  for pair in npm:NPM_TOKEN crates-io:CARGO_REGISTRY_TOKEN maven-central:MAVEN_CENTRAL_USERNAME \
    maven-central:MAVEN_CENTRAL_PASSWORD maven-central:SIGNING_KEY maven-central:SIGNING_PASSWORD; do
    environment="${pair%%:*}"
    secret="${pair#*:}"
    if secret_exists "$environment" "$secret"; then value=stored; else value="not stored"; fi
    printf '  %-42s %s\n' "$secret ($environment)" "$value"
  done
  say "  tags: $(gh api "repos/$REPO/tags" --jq '[.[].name] | join(", ")')"
}

offer_release() {
  bold "Release"
  local tag="v$VERSION" ready="" name sha
  if gh api "repos/$REPO/git/ref/tags/$tag" >/dev/null 2>&1; then
    say "  $tag already exists. For a registry set up after that release, re-run its job here:"
    open_url "https://github.com/$REPO/actions/workflows/$WORKFLOW"
    return 0
  fi
  for name in PYPI RUBYGEMS NUGET NPM CRATES MAVEN; do
    [ "$(variable "PUBLISH_$name")" = true ] && ready="$ready $(lowercase "$name")"
  done
  say "  $tag would publish to: GitHub release, Go${ready:+,}${ready}"
  if ! ask_yes "  Tag $tag on main now and start the release?" n; then
    say "  Later: git tag $tag && git push origin $tag"
    return 0
  fi
  sha=$(gh api "repos/$REPO/commits/main" --jq .sha)
  if [ "$DRY_RUN" = 1 ]; then
    say "  (dry run) would tag $tag at ${sha:0:7}"
    return 0
  fi
  gh api "repos/$REPO/git/refs" -f ref="refs/tags/$tag" -f sha="$sha" --silent
  say "  tagged $tag at ${sha:0:7}; the release is running:"
  open_url "https://github.com/$REPO/actions/workflows/$WORKFLOW"
}

preflight() {
  command -v gh >/dev/null 2>&1 || die "gh is not installed: https://cli.github.com"
  gh auth status >/dev/null 2>&1 || die "gh is not logged in; run: gh auth login"
  [ "$(gh api "repos/$REPO" --jq .permissions.admin 2>/dev/null)" = true ] ||
    die "Setting secrets and variables needs admin rights on $REPO."
  VERSION=$(gh api -H "Accept: application/vnd.github.raw" "repos/$REPO/contents/packages/js/package.json" |
    sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' | head -n 1)
  [ -n "$VERSION" ] || die "Could not read the version from packages/js/package.json on main."
  local environment
  for environment in npm pypi crates-io nuget rubygems maven-central; do
    if ! gh api "repos/$REPO/environments/$environment" >/dev/null 2>&1; then
      if [ "$DRY_RUN" = 1 ]; then
        say "(dry run) would create the environment $environment"
      else
        gh api -X PUT "repos/$REPO/environments/$environment" --silent
      fi
    fi
  done
}

main() {
  case "${1:-}" in
    -h | --help | help)
      sed -n '2,19p' "$0"
      return 0
      ;;
  esac
  preflight
  if [ "${1:-}" = status ]; then
    status
    return 0
  fi
  local chosen="${*:-$ALL}" registry
  for registry in $chosen; do
    case " $ALL " in
      *" $registry "*) ;;
      *) die "Unknown registry: $registry (choose from: $ALL)" ;;
    esac
  done
  [ "$DRY_RUN" = 1 ] && warn "Dry run: nothing will be changed."
  say "Release setup for $REPO, version $VERSION. Each registry asks before it changes anything."
  for registry in $chosen; do
    printf '\n'
    if [ "$registry" = go ] || ask_yes "Set up $registry now?" y; then
      "setup_$registry"
    else
      say "  Skipped $registry."
    fi
  done
  printf '\n'
  status
  printf '\n'
  offer_release
}

main "$@"
