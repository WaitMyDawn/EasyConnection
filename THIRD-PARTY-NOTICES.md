# Third-party licensing

EasyConnection's own source code and original artwork in `assets/branding` are
licensed under the [MIT License](LICENSE). Third-party code, fonts and runtime
components retain their original licenses; the project license does not relicense
those components.

- [Windows runtime notices](third_party/windows/NOTICE.txt) preserve the licenses
  and notices from the exact .NET, ASP.NET Core and Windows Desktop runtime
  packages resolved for the self-contained build.
- [Android notices](third_party/android/NOTICE.txt) preserve the declared pub
  runtime dependency licenses, Flutter engine aggregate notices, font licenses,
  and license/notice entries present in the resolved Android dependency archives.
- [Dependency manifest](third_party/manifest.json) records versions, source text
  hashes, POM declarations and missing declarations. The pub closure includes
  federated packages for other platforms; it is not a list of files proven to be
  included in the APK. Flutter engine Maven POMs omit license declarations;
  Flutter's BSD license and the installed engine's aggregate notices are included.

Both platform output directories contain `LICENSE.txt` and
`THIRD-PARTY-NOTICES.txt`. The EXE embeds its notices, and the APK bundles its
notices as assets. Both applications expose an open-source license viewer.

The previous Android launcher was the unchanged Flutter template logo. It has
been replaced with original monitor/phone artwork; Flutter's trademarks are not
the product's identity. See the [Flutter brand guidelines](https://docs.flutter.dev/brand).

## Updating notices

Use the resolved package configuration and dependency metadata produced by the
current toolchain. Export pub's graph with `flutter pub deps --json` to
`.test-state/pub-dependencies.json`. Export external Gradle
`releaseRuntimeClasspath` components to
`.test-state/android-runtime-modules.json` as an array of
`{group,name,version}`, using `ModuleComponentIdentifier` to exclude local
projects. Then run `python scripts/generate-notices.py` and review the resulting
manifest and source declarations. Missing declarations must remain explicit.

The build checks the pub lockfile hash against the manifest. Regenerate notices
after dependency or runtime changes; copying an older notice collection is not a
substitute for checking newly resolved dependencies.
