# MemStats release process

This project publishes a zipped macOS app through GitHub Releases. The app is currently ad hoc
signed and not notarized, so first launch needs the steps in `README.md` (Open Anyway, or removing
the quarantine attribute). Those steps live in the README only: do not repeat them, or a
`Distribution` section, in `CHANGELOG.md` or the release notes.

## 1. Prepare the release

1. Update `MARKETING_VERSION` in `MemStats/MemStats.xcodeproj/project.pbxproj` to the next three-part
   version, for example `1.0.0`.
2. Update `CHANGELOG.md` with the release status and user-visible changes. Before publishing,
   replace `Unreleased` with the actual publication date.
   List only user-visible changes (Added, Changed, Fixed). Do not copy the `Distribution` block
   from an older entry.
3. Update `README.md` or the planning docs if the release changes requirements or installation.
4. Run the checks from the repository root:

   ```bash
   xcrun swift-format lint --recursive MemStats/MemStats MemStats/MemStatsTests
   xcodebuild -project MemStats/MemStats.xcodeproj \
     -scheme MemStats \
     -destination 'platform=macOS' \
     test
   ```

   If the local environment blocks `testmanagerd`, record that as an environment limitation and
   still run the Release archive build.

5. Review the diff and make sure unrelated user changes are not included. The tagging command
   requires a clean worktree by default.

## 2. Build the release artifact

The script reads the version from Xcode, archives the app, verifies the ad hoc signature, creates
the zip with `ditto`, and writes a SHA-256 file to `dist/`.

```bash
./scripts/release.sh
```

Expected files for version `1.0.0`:

```text
dist/MemStats-1.0.0.zip
dist/MemStats-1.0.0.sha256
dist/MemStats-1.0.0-RELEASE_NOTES.md
```

Check the artifact manually before uploading:

```bash
cat dist/MemStats-1.0.0.sha256
(cd dist && shasum -a 256 -c MemStats-1.0.0.sha256)
unzip -l dist/MemStats-1.0.0.zip
```

The zip must contain `MemStats.app/` at its top level. Do not use Finder Compress or plain `zip`.

## 3. Commit and create the tag

After reviewing the artifact, commit the version, changelog and release workflow changes. Then
create the annotated tag with the build script:

```bash
./scripts/release.sh --tag
```

The script creates `v1.0.0` locally. It does not push anything automatically.

Push the branch and tag:

```bash
git push origin main
git push origin v1.0.0
```

## 4. Create the GitHub Release

On `https://github.com/sown-oss/MemStats/releases/new`:

1. Select the pushed tag, for example `v1.0.0`.
2. Set the release title to `MemStats 1.0.0`.
3. Paste the contents of `dist/MemStats-1.0.0-RELEASE_NOTES.md` into the release notes.
4. Upload `dist/MemStats-1.0.0.zip`.
5. Publish the release.

If GitHub CLI is available, the equivalent command is:

```bash
gh release create v1.0.0 \
  dist/MemStats-1.0.0.zip \
  --title 'MemStats 1.0.0' \
  --notes-file dist/MemStats-1.0.0-RELEASE_NOTES.md
```

The script has already selected the `1.0.0` section and appended the checksum to that notes file.

## 5. Verify the published release

1. Download the zip from the published release on a clean Mac.
2. Verify its checksum against the value in the release notes.
3. Unzip it and move `MemStats.app` to `/Applications`.
4. Open the app. If macOS blocks it, use System Settings > Privacy & Security > Open Anyway, or:

   ```bash
   xattr -dr com.apple.quarantine /Applications/MemStats.app
   ```

5. Smoke-test the menu bar item, donut, history, Settings, Open at Login, Show System Users,
   Check for Updates, Report a Bug, About and Quit.
6. Confirm the About or Settings version is the release version and that the latest-release link
   opens the new GitHub release.
