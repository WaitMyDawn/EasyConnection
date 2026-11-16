"""Collect installed dependency license texts without changing their terms.

Inputs are pub's dependency graph and Gradle's resolved external module list.
Missing declarations remain explicit in the manifest; a package name is never
used to infer a license. Development tools are not application dependencies.
"""
import hashlib
import io
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET
from urllib.parse import urlparse
from urllib.request import url2pathname
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parent.parent
THIRD = ROOT / "third_party"
FLUTTER = ROOT / ".tools/flutter"
MAVEN = ROOT / ".tools/gradle/caches/modules-2/files-2.1"
NS = {"m": "http://maven.apache.org/POM/4.0.0"}


def text(path):
    return path.read_text(encoding="utf-8-sig")


def write_changed(path, value):
    if not path.exists() or text(path) != value:
        path.write_text(value, encoding="utf-8")


def section(title, body):
    return f"\n{'=' * 72}\n{title}\n{'=' * 72}\n\n{body.rstrip()}\n"


def archive_notices(archive, prefix=""):
    found = []
    with ZipFile(archive) as zipped:
        for name in zipped.namelist():
            if re.fullmatch(r"(?:LICENSE|NOTICE|COPYING)(?:[._-].*)?", Path(name).name, re.I):
                found.append((prefix + name, zipped.read(name).decode("utf-8-sig")))
            elif name == "classes.jar":
                found.extend(archive_notices(io.BytesIO(zipped.read(name)), prefix + name + "/"))
    return found


def pom_declarations(path, visited=None):
    visited = set() if visited is None else visited
    if path in visited:
        return []
    visited.add(path)
    tree = ET.parse(path).getroot()
    licenses = [{"name": e.findtext("m:name", namespaces=NS), "url": e.findtext("m:url", namespaces=NS)}
                for e in tree.findall("m:licenses/m:license", NS)]
    parent = tree.find("m:parent", NS)
    if not licenses and parent is not None:
        coordinates = [parent.findtext("m:" + n, namespaces=NS) for n in ("groupId", "artifactId", "version")]
        if all(coordinates):
            for inherited in MAVEN.joinpath(*coordinates).glob("*/*.pom"):
                licenses.extend(pom_declarations(inherited, visited))
    return licenses


def main():
    graph = json.loads(text(ROOT / ".test-state/pub-dependencies.json"))
    packages = {p["name"]: p for p in graph["packages"]}
    pending = [p["name"] for p in packages.values() if p["kind"] == "direct"]
    runtime = set()
    while pending:
        name = pending.pop()
        if name in runtime:
            continue
        runtime.add(name)
        pending.extend(packages[name].get("dependencies", []))
    config_file = ROOT / "apps/mobile/.dart_tool/package_config.json"
    config = json.loads(text(config_file))
    locations = {p["name"]: p["rootUri"] for p in config["packages"]}
    android = ["EasyConnection Android third-party notices\n\n"
               "Third-party components retain their original licenses. This collection covers\n"
               "the declared pub runtime dependency closure, including federated packages for\n"
               "other platforms, and Gradle's resolved external release modules. Presence in\n"
               "the closure does not prove inclusion in the final APK. Missing POM license\n"
               "declarations are recorded in the manifest, not inferred from module names.\n"]
    manifest = {"pubRuntime": [], "androidModules": [], "sourceHashes": {
        "pubspecLock": hashlib.sha256((ROOT / "apps/mobile/pubspec.lock").read_bytes()).hexdigest()}}
    for name in sorted(runtime):
        package = packages[name]
        uri = locations[name]
        directory = Path(url2pathname(urlparse(uri).path)) if uri.startswith("file:") else (config_file.parent / uri).resolve()
        files = [p for p in directory.iterdir() if p.is_file() and p.name.upper() in
                 {"LICENSE", "LICENSE.TXT", "LICENSE.MD", "COPYING", "COPYING.TXT", "NOTICE", "NOTICE.TXT"}]
        if not files and package["source"] == "sdk" and directory.is_relative_to(FLUTTER.resolve()):
            for parent in directory.parents:
                if (parent / "LICENSE").is_file():
                    files = [parent / "LICENSE"]
                    break
                if parent == FLUTTER.resolve():
                    break
        if not files:
            raise RuntimeError(f"License text missing for {name}")
        bodies = [text(p) for p in files]
        android.append(section(f"pub: {name} {package['version']}", "\n\n".join(bodies)))
        manifest["pubRuntime"].append({"name": name, "version": package["version"],
            "licenseTextHashes": [hashlib.sha256(p.read_bytes()).hexdigest() for p in files]})
    for path in (FLUTTER / "bin/cache/artifacts/material_fonts").iterdir():
        if path.is_file() and "LICENSE" in path.name.upper():
            android.append(section("Flutter font asset: " + path.name, text(path)))
    for module in json.loads(text(ROOT / ".test-state/android-runtime-modules.json")):
        coordinate = ":".join(module[n] for n in ("group", "name", "version"))
        directory = MAVEN.joinpath(*(module[n] for n in ("group", "name", "version")))
        declarations = [entry for p in directory.glob("*/*.pom") for entry in pom_declarations(p)]
        notices = []
        for artifact in directory.glob("*/*"):
            if artifact.suffix in (".jar", ".aar"):
                for filename, body in archive_notices(artifact):
                    notices.append(filename)
                    android.append(section(coordinate + " / " + filename, body))
        module["declaredLicenses"] = declarations
        module["archiveNoticeEntries"] = notices
        module["declarationCoverage"] = "declared in POM or cached parent" if declarations else "not stated in available POM; see aggregate SDK notices"
        manifest["androidModules"].append(module)
    apache = ROOT / ".tools/pub-cache/hosted/pub.dev/material_color_utilities-0.13.0/LICENSE"
    android.append(section("Apache License 2.0 — license text for modules declaring these terms", text(apache)))
    windows = ["EasyConnection Windows third-party notices\n\nLicenses from resolved self-contained .NET runtime packages.\n"]
    assets = json.loads(text(ROOT / "src/EasyConnection.Host/obj/project.assets.json"))
    manifest["windowsRuntime"] = []
    dependencies = [d for framework in assets["project"]["frameworks"].values() for d in framework.get("downloadDependencies", [])]
    for dependency in dependencies:
        exact = re.fullmatch(r"\[([^,]+),\s*\1\]", dependency["version"])
        if not exact:
            raise RuntimeError("Unresolved runtime version: " + dependency["name"])
        version = exact.group(1)
        candidates = [Path(root) / dependency["name"].lower() / version for root in assets["packageFolders"]]
        package = next((p for p in candidates if p.is_dir()), None)
        if package is None:
            raise RuntimeError("Runtime package missing: " + dependency["name"])
        files = [p for p in package.iterdir() if p.is_file() and (p.name.upper() in {"LICENSE", "LICENSE.TXT", "LICENSE.MD"} or "NOTICE" in p.name.upper())]
        if not files:
            raise RuntimeError("Runtime license missing: " + dependency["name"])
        for path in files:
            windows.append(section(f"{dependency['name']} {version} / {path.name}", text(path)))
        manifest["windowsRuntime"].append({"name": dependency["name"], "version": version,
            "licenseTextHashes": [hashlib.sha256(p.read_bytes()).hexdigest() for p in files]})
    for platform, pieces in (("android", android), ("windows", windows)):
        target = THIRD / platform / "NOTICE.txt"
        target.parent.mkdir(parents=True, exist_ok=True)
        write_changed(target, "".join(pieces))
    write_changed(THIRD / "manifest.json", json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    assets = ROOT / "apps/mobile/assets/licenses"
    assets.mkdir(parents=True, exist_ok=True)
    write_changed(assets / "LICENSE", text(ROOT / "LICENSE"))
    write_changed(assets / "THIRD-PARTY-NOTICES.txt", "".join(android))
    print(f"Collected {len(runtime)} pub package notices and {len(manifest['androidModules'])} Android module records")


if __name__ == "__main__":
    main()
