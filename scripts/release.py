#!/usr/bin/env python3
"""Build and publish notarized fork releases using this Mac's private Keychain."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

APP = "Stats"
REPOSITORY = "iTvX/stats"
BUNDLE_ID = "eu.exelban.Stats"
ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build"


def run(*args, **kwargs):
    return subprocess.run(list(map(str, args)), check=True, **kwargs)


def output(*args):
    return run(*args, capture_output=True, text=True).stdout.strip()


def version():
    project = json.loads(output("plutil", "-convert", "json", "-o", "-", ROOT / f"{APP}.xcodeproj/project.pbxproj"))
    declared = next(item["buildSettings"]["MARKETING_VERSION"] for item in project["objects"].values()
                    if item.get("name") == "Release" and item.get("buildSettings", {}).get("PRODUCT_BUNDLE_IDENTIFIER") == BUNDLE_ID)
    if not re.fullmatch(r"\d+\.\d+\.\d+", declared):
        raise ValueError("The release branch must declare a stable major.minor.patch version")
    candidate = tuple(map(int, declared.split(".")))
    tags = output("git", "ls-remote", "--tags", "origin")
    published = [tuple(map(int, match)) for match in re.findall(r"refs/tags/v?(\d+)\.(\d+)\.(\d+)$", tags, re.M)]
    if published and max(published) >= candidate:
        major, minor, patch = max(published)
        candidate = major, minor, patch + 1
    value = ".".join(map(str, candidate))
    metadata = {"version": value, "tag": f"v{value}", "build_number": datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d%H%M%S")}
    for key, value in metadata.items():
        print(f"{key}={value}")
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
            stream.writelines(f"{key}={value}\n" for key, value in metadata.items())


def release_metadata():
    value = os.environ["RELEASE_VERSION"]
    number = os.environ["BUILD_NUMBER"]
    tag = os.environ["RELEASE_TAG"]
    if not re.fullmatch(r"\d+\.\d+\.\d+", value) or not number.isdecimal() or tag != f"v{value}":
        raise ValueError("Invalid release version, build number, or tag")
    if os.environ.get("GITHUB_REPOSITORY", REPOSITORY) != REPOSITORY:
        raise ValueError("This release pipeline only publishes to the configured fork")
    return value, number, tag


def notarize(path):
    result = run("xcrun", "notarytool", "submit", path,
                 "--keychain-profile", os.environ["NOTARY_PROFILE"], "--keychain", os.environ["NOTARY_KEYCHAIN"],
                 "--wait", "--timeout", "30m", "--output-format", "json", capture_output=True, text=True)
    data = json.loads(result.stdout)
    (BUILD / f"{path.stem}-{path.suffix[1:]}-notary.json").write_text(result.stdout)
    if data.get("status") != "Accepted":
        raise ValueError(f"Apple rejected {path.name}; inspect the notarization result in build/")
    print(f"Apple notarization accepted: {path.name}", flush=True)


def build():
    value, number, tag = release_metadata()
    keychain = os.environ["KEYCHAIN_DB"]
    password_file = Path(os.environ["KEYCHAIN_PASSWORD_FILE"])
    if password_file.is_symlink() or password_file.stat().st_mode & 0o077:
        raise ValueError("The Keychain password file must be private and must not be a symlink")
    unlocked = subprocess.run(["security", "unlock-keychain", "-p", password_file.read_text().strip(), keychain], capture_output=True)
    if unlocked.returncode:
        raise ValueError("Unable to unlock the signing Keychain")
    identity = os.environ["SIGN_IDENTITY"]
    team = os.environ["SIGN_TEAM_ID"]
    if identity not in output("security", "find-identity", "-v", "-p", "codesigning", keychain):
        raise ValueError("The configured Developer ID signing identity is unavailable")
    output("xcrun", "notarytool", "history", "--keychain-profile", os.environ["NOTARY_PROFILE"],
           "--keychain", os.environ["NOTARY_KEYCHAIN"], "--output-format", "json")
    BUILD.mkdir(exist_ok=True)
    archive = BUILD / f"{APP}.xcarchive"
    if archive.exists():
        shutil.rmtree(archive)
    print(f"Building universal {APP} {value} ({number})", flush=True)
    with (BUILD / "xcodebuild.log").open("w") as log:
        result = subprocess.run([
            "xcodebuild", "archive", "-project", f"{APP}.xcodeproj", "-scheme", APP,
            "-configuration", "Release", "-destination", "generic/platform=macOS",
            "-archivePath", str(archive), "-derivedDataPath", str(BUILD / "DerivedData"),
            "-clonedSourcePackagesDirPath", str(BUILD / "SourcePackages"), "-jobs", "6",
            "ARCHS=arm64 x86_64", "ONLY_ACTIVE_ARCH=NO", f"MARKETING_VERSION={value}",
            f"CURRENT_PROJECT_VERSION={number}", f"DEVELOPMENT_TEAM={team}", "CODE_SIGN_STYLE=Manual",
            f"CODE_SIGN_IDENTITY={identity}", f"OTHER_CODE_SIGN_FLAGS=--keychain {keychain} --timestamp",
            "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO", "ENABLE_HARDENED_RUNTIME=YES",
        ], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        print("\n".join((BUILD / "xcodebuild.log").read_text().splitlines()[-100:]))
        raise ValueError("Xcode archive failed; see build/xcodebuild.log")
    package(value, number, tag, keychain, identity, team, archive)


def package(value, number, tag, keychain, identity, team, archive):
    app = BUILD / f"{APP}.app"
    if app.exists():
        shutil.rmtree(app)
    run("ditto", archive / f"Products/Applications/{APP}.app", app)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if (info["CFBundleShortVersionString"], info["CFBundleVersion"]) != (value, number):
        raise ValueError("The built app version does not match the release")
    for architecture in ("arm64", "x86_64"):
        run("lipo", app / f"Contents/MacOS/{APP}", "-verify_arch", architecture)
    if APP == "Stats":
        widget = app / "Contents/PlugIns/WidgetsExtension.appex"
        widget_info = plistlib.loads((widget / "Contents/Info.plist").read_bytes())
        if (widget_info["CFBundleShortVersionString"], widget_info["CFBundleVersion"]) != (value, number) or info["TeamId"] != team:
            raise ValueError("Widget version or shared preferences signing team is incorrect")
        run("codesign", "--verify", "--strict", widget)
        helper = app / "Contents/Library/LaunchServices/eu.exelban.Stats.SMC.Helper"
        run("codesign", "--verify", "--strict", "-R", f'=anchor apple generic and certificate leaf[subject.OU] = "{team}"', helper)
    else:
        expected_feed = f"https://github.com/{REPOSITORY}/releases/download/appcast/appcast.xml"
        key = output(Path(os.environ["SPARKLE_BIN_DIR"]) / "generate_keys", "--account", os.environ["SPARKLE_ACCOUNT"], "-p")
        if info["SUFeedURL"] != expected_feed or info["SUPublicEDKey"] != key:
            raise ValueError("The update feed or public signing key is incorrect")
    run("codesign", "--verify", "--deep", "--strict", app)
    zip_path = BUILD / f"{APP}.zip"
    zip_path.unlink(missing_ok=True)
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, zip_path)
    notarize(zip_path)
    run("xcrun", "stapler", "staple", app)
    run("xcrun", "stapler", "validate", app)
    run("spctl", "--assess", "--type", "execute", "--verbose=4", app)
    zip_path.unlink()
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, zip_path)
    staging = BUILD / "dmg-root"
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir()
    run("ditto", app, staging / app.name)
    (staging / "Applications").symlink_to("/Applications")
    shutil.copy2(ROOT / "LICENSE", staging / "LICENSE")
    dmg = BUILD / f"{APP}.dmg"
    run("hdiutil", "create", "-volname", APP, "-srcfolder", staging, "-format", "UDZO", "-ov", dmg)
    run("codesign", "--force", "--timestamp", "--keychain", keychain, "--sign", identity, dmg)
    notarize(dmg)
    run("xcrun", "stapler", "staple", dmg)
    run("xcrun", "stapler", "validate", dmg)
    if APP == "Thaw":
        appcast(tag, zip_path)
    (BUILD / "SHA256SUMS").write_text("".join(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n" for path in (dmg, zip_path)))
    (BUILD / "RELEASE_NOTES.md").write_text(
        f"{APP} {value} — iTvX fork\n\nUniversal macOS build for Apple silicon and Intel. "
        "Signed with Developer ID and notarized by Apple.\n\n"
        f"Future in-app updates are delivered from [{REPOSITORY}](https://github.com/{REPOSITORY}/releases). "
        "Install this fork's DMG once to switch from the upstream distribution.\n\n"
        f"Source commit: {output('git', 'rev-parse', 'HEAD')}\n"
    )
    print(f"Verified release artifacts: {BUILD}", flush=True)


def appcast(tag, zip_path):
    feed = BUILD / "feed"
    if feed.exists():
        shutil.rmtree(feed)
    feed.mkdir()
    shutil.copy2(zip_path, feed / zip_path.name)
    releases = json.loads(output("gh", "api", f"repos/{REPOSITORY}/releases?per_page=100"))
    if any(item["tag_name"] == "appcast" for item in releases):
        run("gh", "release", "download", "appcast", "--repo", REPOSITORY, "--pattern", "appcast.xml", "--dir", feed)
    tools = Path(os.environ["SPARKLE_BIN_DIR"])
    account = os.environ["SPARKLE_ACCOUNT"]
    run(tools / "generate_appcast", "--account", account, "--maximum-versions", "0", "--maximum-deltas", "0",
        "--download-url-prefix", f"https://github.com/{REPOSITORY}/releases/download/{tag}/", "--link", f"https://github.com/{REPOSITORY}/releases", feed)
    run(tools / "sign_update", "--account", account, feed / "appcast.xml")
    run(tools / "sign_update", "--account", account, "--verify", feed / "appcast.xml")


def publish():
    value, _, tag = release_metadata()
    commit = output("git", "rev-parse", "HEAD")
    run("git", "tag", tag, commit)
    run("git", "push", "origin", f"refs/tags/{tag}")
    assets = [BUILD / f"{APP}.dmg", BUILD / f"{APP}.zip", BUILD / "SHA256SUMS", ROOT / "LICENSE"]
    run("gh", "release", "create", tag, *assets, "--repo", REPOSITORY, "--verify-tag", "--draft",
        "--title", f"{APP} {value}", "--notes-file", BUILD / "RELEASE_NOTES.md")
    run("gh", "release", "edit", tag, "--repo", REPOSITORY, "--draft=false", "--latest")
    if APP == "Thaw":
        releases = json.loads(output("gh", "api", f"repos/{REPOSITORY}/releases?per_page=100"))
        if not any(item["tag_name"] == "appcast" for item in releases):
            run("gh", "release", "create", "appcast", BUILD / "feed/appcast.xml", "--repo", REPOSITORY,
                "--target", commit, "--title", "Thaw update feed", "--notes", "Signed update feed for iTvX/Thaw.", "--prerelease", "--latest=false")
        else:
            run("gh", "release", "upload", "appcast", BUILD / "feed/appcast.xml", "--repo", REPOSITORY, "--clobber")
        with tempfile.TemporaryDirectory() as directory:
            run("gh", "release", "download", "appcast", "--repo", REPOSITORY, "--pattern", "appcast.xml", "--dir", directory)
            if (Path(directory) / "appcast.xml").read_bytes() != (BUILD / "feed/appcast.xml").read_bytes():
                raise ValueError("Published update feed does not match the verified appcast")
    print(output("gh", "release", "view", tag, "--repo", REPOSITORY, "--json", "url", "--jq", ".url"))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("version", "build", "publish"))
    arguments = parser.parse_args()
    os.chdir(ROOT)
    {"version": version, "build": build, "publish": publish}[arguments.action]()
