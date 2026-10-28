---
name: release
description: Release a new MemStats version end to end. Bumps the version, dates the CHANGELOG, runs the checks, builds the zip and tag with scripts/release.sh, publishes the GitHub Release, and updates the landing page on the `page` branch. Use when the user asks to release, ship or publish a version (for example "release 1.3.0").
argument-hint: "<x.y.z>"
---

# /release

Releases MemStats `<x.y.z>` from `main`. `docs/RELEASING.md` is the manual version of the same
process. `scripts/release.sh` builds the artifacts and creates the tag; this skill wraps it with
the steps around it. Write all prose without the em dash character.

## 0. Preconditions

Stop and report if any of these fail:

- The version is three-part `x.y.z` and greater than the current `MARKETING_VERSION` in
  `MemStats/MemStats.xcodeproj/project.pbxproj`.
- On `main`, working tree clean, and up to date with `origin/main` (`git pull --ff-only`). Feature
  PRs for this release are already merged.
- Tag `v<x.y.z>` does not exist locally or on `origin`, and `gh release view v<x.y.z>` fails.
- `CHANGELOG.md` has an `## [Unreleased]` section with entries.

## 1. Prepare the release commit

1. In `project.pbxproj`, set every `MARKETING_VERSION` to `<x.y.z>` and raise every
   `CURRENT_PROJECT_VERSION` by one. All build configurations must end up with the same values.
2. In `CHANGELOG.md`, rename `## [Unreleased]` to `## [<x.y.z>] - DD/MM/YYYY` with today's date,
   and add a one-sentence summary below the heading, like earlier releases. Keep only Added,
   Changed and Fixed sections. Never add a `Distribution` section: first-launch steps live in the
   README only.
3. If a `docs/PLAN_*.md` file tracks this release, tick its release item.
4. Run the checks from the repository root:

   ```bash
   xcrun swift-format lint --recursive MemStats/MemStats MemStats/MemStatsTests
   xcodebuild -project MemStats/MemStats.xcodeproj -scheme MemStats -destination 'platform=macOS' test
   ```

5. Commit as `chore(release): prepare v<x.y.z>`, with a body naming the new version and build
   number. No `Co-Authored-By` line.

## 2. Build and tag

```bash
./scripts/release.sh --tag
```

It needs a clean tree. It writes `dist/MemStats-<x.y.z>.zip`, `.sha256` and
`-RELEASE_NOTES.md`, and creates the local annotated tag `v<x.y.z>`. Then verify:

```bash
(cd dist && shasum -a 256 -c MemStats-<x.y.z>.sha256)
unzip -l dist/MemStats-<x.y.z>.zip | head   # MemStats.app/ must be at the top level
```

Unzip to a temporary folder and check that `CFBundleShortVersionString` and `CFBundleVersion` in
`MemStats.app/Contents/Info.plist` match the new version and build number.

## 3. Publish

Pushing and publishing are visible to everyone. Unless the user already asked to publish this
release, show the version, build number, release notes and checksum, and wait for a go.

```bash
git push origin main
git push origin v<x.y.z>
gh release create v<x.y.z> dist/MemStats-<x.y.z>.zip \
  --title 'MemStats <x.y.z>' \
  --notes-file dist/MemStats-<x.y.z>-RELEASE_NOTES.md
```

Check `gh release view v<x.y.z>`: it is marked Latest and lists the zip. Download the asset and
compare its SHA-256 with the notes.

## 4. Update the landing page

The site (https://memstats.chungxon.dev/) is the `page` branch, deployed by Cloudflare Pages.
Work in a temporary worktree outside the repo, for example
`git worktree add <scratch>/page origin/page -B page`.

1. `index.html`: set `"softwareVersion"` in the JSON-LD and the `Version x.y.z.` note under the
   download buttons.
2. `sitemap.xml`: set the `<lastmod>` of `/` to today (`YYYY-MM-DD`).
3. Describe the user-visible changes from the CHANGELOG in the matching feature cards, and in the
   FAQ when users would ask about them. Do not add claims about other apps to the comparison
   table unless checked against their public pages.
4. Screenshots, only when the UI changed: dark appearance, fake data (users alice, bob and carol),
   one section cropped to 732 px wide, saved as WebP with `cwebp -q 85`. Give every `<img>` its
   real `width` and `height`, `loading="lazy"`, `decoding="async"` and a descriptive `alt`.
   To render the popover with fake data, add a temporary Swift Testing file to `MemStatsTests`
   that hosts `PopoverRootView` in a borderless window with a stub `ProcessTerminating` and a
   process provider that never returns, so no real `top` output reaches the image. Capture the
   window with `screencapture -l <windowNumber>`, then delete the file before committing.
5. Commit as `docs(site): update for v<x.y.z>` with a body listing what changed, and push
   `page`.
6. Verify the deploy, not just the live page: the Cloudflare Pages check-run on the pushed commit
   (`gh api repos/sown-oss/MemStats/commits/<sha>/check-runs`) must succeed, then the live
   page must show the new version (`curl -s https://memstats.chungxon.dev/ | rg 'Version x.y.z'`).
7. Remove the worktree with `git worktree remove <path>` and `git worktree prune`, never with
   `--force`. Keep the `page` branch.

## 5. Report

List the release URL, tag, zip checksum, the landing page commit and its deploy status, and
anything left for the user. Smoke-testing the downloaded app on a Mac is in
`docs/RELEASING.md` section 5. Keep that and any unchecked on-device tasks from the plan docs in
the report until they are done.
