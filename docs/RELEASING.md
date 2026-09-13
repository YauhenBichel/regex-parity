# Releasing

One tag publishes every package:

```bash
python3 scripts/check-versions.py 0.2.0     # every package must already say 0.2.0
git tag v0.2.0 && git push origin v0.2.0
```

[`release.yml`](../.github/workflows/release.yml) then:

- checks that every package carries the tag's version;
- creates the GitHub release from the matching `CHANGELOG.md` section;
- tags the Go module (`go/v0.2.0`) and has the Go proxy fetch it;
- publishes to each registry whose repository variable is `true`.

A registry with its variable unset is skipped, so one that is not set up yet never blocks the others.

## The quick way

```bash
bash scripts/setup-release.sh              # every registry, asking before each
bash scripts/setup-release.sh status       # what is set up already
```

For each registry the script opens the page where you have to act, shows the exact values to enter,
then stores the variables and secrets below for you. For Maven Central it also creates, uploads and
stores a signing key. At the end it offers to tag the release. Secrets are read without echo and passed
to `gh` on standard input, never shown or written to disk. `DRY_RUN=1` shows what it would change.

For npm and crates.io, run it once more after the first release (`bash scripts/setup-release.sh npm crates`):
it switches them to trusted publishing and deletes the tokens.

## One-time setup, per registry

Everything below is done once, by the repository owner, on the registry's website and in
**GitHub → Settings → Secrets and variables → Actions**. The GitHub environments (`npm`, `pypi`,
`crates-io`, `nuget`, `rubygems`, `maven-central`) already exist.

Values the trusted-publisher forms ask for:

| Field | Value |
|---|---|
| Owner / organisation | `YauhenBichel` |
| Repository | `regex-parity` |
| Workflow file | `release.yml` |
| Environment | the one named in each section below |

### Go: nothing to set up

The module path is `github.com/YauhenBichel/regex-parity/go`. A tag `go/vX.Y.Z` is the release.

### PyPI (`regex-parity`)

1. On pypi.org: **Your account → Publishing → Add a new pending publisher**. Enter PyPI project name
   `regex-parity`, the values above, and environment `pypi`.
2. Set the repository variable `PUBLISH_PYPI` to `true`.

### RubyGems (`regex-parity`)

1. On rubygems.org: **Settings → Trusted publishers → Create a pending trusted publisher**, for gem
   `regex-parity`, with the values above and environment `rubygems`.
2. Set `PUBLISH_RUBYGEMS` to `true`.

### NuGet (`RegexParity`)

1. On nuget.org: **your account menu → Trusted Publishing → Create policy**, with the values above
   and environment `nuget`.
2. Set the repository variable `NUGET_USER` to your nuget.org user name, and `PUBLISH_NUGET` to
   `true`.

### npm (`regex-parity`)

npm can only add a trusted publisher to a package that already exists, so the first release uses a
token:

1. On npmjs.com: **Access Tokens → Generate New Token → Granular**, with permission to publish, and
   store it as the secret `NPM_TOKEN` in the `npm` environment.
2. Set `PUBLISH_NPM` to `true` and release.
3. After the first release: **package settings → Trusted Publisher → GitHub Actions**, with the
   values above and environment `npm`. Then delete `NPM_TOKEN`.

### crates.io (`regex-parity`)

crates.io, too, adds a trusted publisher only after the first release:

1. On crates.io: **Account Settings → API Tokens → New Token**, scoped to `publish-new` and
   `publish-update`. Store it as the secret `CARGO_REGISTRY_TOKEN` in the `crates-io` environment.
2. Set `PUBLISH_CRATES` to `true` and release.
3. After the first release, add the trusted publisher on the crate's **Settings** page (values
   above, environment `crates-io`). Then delete `CARGO_REGISTRY_TOKEN`.

### Maven Central (`io.github.yauhenbichel:regex-parity`)

Maven Central has no OIDC publishing and requires signed artifacts:

1. Sign in at central.sonatype.com with GitHub. The namespace `io.github.yauhenbichel` is verified
   from the GitHub account.
2. **View Account → Generate User Token**. Store the two halves as the secrets
   `MAVEN_CENTRAL_USERNAME` and `MAVEN_CENTRAL_PASSWORD` in the `maven-central` environment.
3. Create a signing key (`gpg --quick-generate-key "Yauhen Bichel <address>" ed25519 sign never`) and
   publish its public half (`gpg --keyserver keys.openpgp.org --send-keys KEYID`). Store the
   armoured private key (`gpg --armor --export-secret-keys KEYID`) as `SIGNING_KEY` and its
   passphrase as `SIGNING_PASSWORD`.
4. Set `PUBLISH_MAVEN` to `true`.

## After a release

The workflow's summary shows each registry job. A skipped job means its variable is not `true` yet;
a failed one names the registry step that refused.
