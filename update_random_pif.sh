#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: 2026 Neoteric OS
# SPDX-License-Identifier: Apache-2.0
#

cd "$(dirname "$0")" || exit 1

python3 - <<'EOF'
import urllib.request
import re
import json
import random
import sys
import os

def get_html(url):
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
    try:
        return urllib.request.urlopen(req, timeout=10).read().decode('utf-8')
    except Exception as e:
        print(f"Error fetching {url}: {e}", file=sys.stderr)
        sys.exit(1)

out_file = "gms_certified_props.json"

# Hardcoded security patch level
SECURITY_PATCH = "2026-10-05"

try:
    with open(out_file, "r") as f:
        existing_meta = json.load(f)
except Exception as e:
    print(f"Could not load existing {out_file}! Make sure it exists in the same folder as the script.")
    sys.exit(1)

print("Fetching latest Android versions...")
versions_html = get_html("https://developer.android.com/about/versions")
# Only whole-number version links (e.g. /about/versions/17), deduplicated.
nums = sorted({int(n) for n in re.findall(r'/about/versions/([0-9]+)(?=["/#?\']|$)', versions_html)})
if not nums:
    print("Could not find any Android version links.")
    sys.exit(1)
latest_version = str(nums[-1])  # numeric max, used as VERSION.RELEASE (canary tracks the next major)
latest_build_url = f"https://developer.android.com/about/versions/{latest_version}"
print(f"Latest Android version: {latest_version}")

print("Fetching latest factory image info...")
latest_html = get_html(latest_build_url)
factory_url_match = re.search(r'href="([^"]*download[^"]*)"', latest_html)
if not factory_url_match:
    print("Could not find factory image download link.")
    sys.exit(1)

factory_link = factory_url_match.group(1)
if factory_link.startswith("http"):
    factory_url = factory_link
else:
    factory_url = "https://developer.android.com" + factory_link
factory_html = get_html(factory_url)

# Pixel 8 series and older, mapped to the SDK level each device LAUNCHED with
# (value for VERSION.DEVICE_INITIAL_SDK_INT / ro.product.first_api_level).
# Newer devices (Pixel 9+, 9a, 10, ...) are excluded.
ALLOWED_CODENAMES = {
    # Pixel 8 series (Android 14 -> API 34)
    "shiba": 34,      # Pixel 8
    "husky": 34,      # Pixel 8 Pro
    "akita": 34,      # Pixel 8a
    # Pixel 7 series + 2023 foldable/tablet (Android 13 -> API 33)
    "panther": 33,    # Pixel 7
    "cheetah": 33,    # Pixel 7 Pro
    "lynx": 33,       # Pixel 7a
    "felix": 33,      # Pixel Fold
    "tangorpro": 33,  # Pixel Tablet
    # Pixel 6 series (Android 12 -> API 31)
    "oriole": 31,     # Pixel 6
    "raven": 31,      # Pixel 6 Pro
    "bluejay": 31,    # Pixel 6a
    # Pixel 5 / 4a 5G / 5a (Android 11 -> API 30)
    "redfin": 30,     # Pixel 5
    "bramble": 30,    # Pixel 4a (5G)
    "barbet": 30,     # Pixel 5a
    # Pixel 4 series (Android 10 -> API 29)
    "sunfish": 29,    # Pixel 4a
    "coral": 29,      # Pixel 4 XL
    "flame": 29,      # Pixel 4
    # Pixel 3 series (Android 9 -> API 28)
    "bonito": 28,     # Pixel 3a XL
    "sargo": 28,      # Pixel 3a
    "crosshatch": 28, # Pixel 3 XL
    "blueline": 28,   # Pixel 3
}

devices = {}
for m in re.finditer(r'<tr\s+id="([^"]+)"[^>]*>\s*<td>([^<]+)</td>', factory_html, re.I):
    codename = m.group(1).strip()
    if codename not in ALLOWED_CODENAMES:
        continue
    devices[m.group(2).strip()] = codename + "_beta"

if not devices:
    print("No beta devices at or below the Pixel 8 series found in the latest factory images.")
    sys.exit(1)

device_name = random.choice(list(devices.keys()))
product = devices[device_name]
device = product.replace("_beta", "")
initial_sdk = ALLOWED_CODENAMES[device]

print(f"Selected random device: {device_name} ({device}), initial SDK {initial_sdk}")

print("Getting flash station key...")
flash_html = get_html("https://flash.android.com/")
flash_key_match = re.search(r'data-client-config\s*=\s*"(?:[^,]*?,){2}\s*&quot;([^&]+)&quot;', flash_html, re.I)
if not flash_key_match:
    print("Failed to get flash key.")
    sys.exit(1)

flash_key = flash_key_match.group(1).replace("&quot;", '"').replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")

print("Fetching build information...")
station_req = urllib.request.Request(
    f"https://content-flashstation-pa.googleapis.com/v1/builds?product={product}&key={flash_key}",
    headers={'Referer': 'https://flash.android.com/'}
)
station_json = urllib.request.urlopen(station_req, timeout=10).read().decode('utf-8')

build_id = None
build_inc = None

# Prefer structured parsing so name/id pairs stay aligned and we take the newest
# CANARY entry; fall back to the regex pairing if the shape is unexpected.
def collect_builds(node, acc):
    if isinstance(node, dict):
        if "releaseCandidateName" in node and "buildId" in node:
            acc.append((str(node["releaseCandidateName"]), str(node["buildId"]), node))
        for v in node.values():
            collect_builds(v, acc)
    elif isinstance(node, list):
        for v in node:
            collect_builds(v, acc)

try:
    builds = []
    collect_builds(json.loads(station_json), builds)
    canary = [b for b in builds if "canary" in json.dumps(b[2]).lower()]
    pick = (canary or builds)[-1] if (canary or builds) else None
    if pick:
        build_id, build_inc = pick[0], pick[1]
except ValueError:
    pass

if not build_id or not build_inc:
    for rc, bi in zip(re.finditer(r'"releaseCandidateName"\s*:\s*"([^"]+)"', station_json),
                      re.finditer(r'"buildId"\s*:\s*"([^"]+)"', station_json)):
        build_id = rc.group(1)
        build_inc = bi.group(1)

if not build_id or not build_inc:
    print("Could not parse build id/incremental from flash station response.")
    sys.exit(1)

# Fingerprint keeps the literal "CANARY"; ro.build.version.release is numeric.
RELEASE = latest_version
fingerprint = f"google/{product}/{device}:CANARY/{build_id}/{build_inc}:user/release-keys"

existing_meta["MANUFACTURER"] = "Google"
existing_meta["MODEL"] = device_name
existing_meta["FINGERPRINT"] = fingerprint
existing_meta["BRAND"] = "google"
existing_meta["PRODUCT"] = product
existing_meta["DEVICE"] = device
existing_meta["ID"] = build_id
existing_meta["VERSION.INCREMENTAL"] = build_inc
existing_meta["VERSION.RELEASE"] = RELEASE
existing_meta["VERSION.SECURITY_PATCH"] = SECURITY_PATCH
existing_meta["VERSION.DEVICE_INITIAL_SDK_INT"] = str(initial_sdk)
existing_meta["TYPE"] = "user"
existing_meta["TAGS"] = "release-keys"

with open(out_file, "w") as f:
    json.dump(existing_meta, f, indent=4)

xml_file = "CertifiedPropsOverlay/res/values/config.xml"
os.makedirs(os.path.dirname(xml_file), exist_ok=True)
items_xml = "\n".join([f"        <item>{k}:{v}</item>" for k, v in existing_meta.items()])
xml_content = f"""<?xml version="1.0" encoding="utf-8"?>
<!--
     Copyright (C) 2023 Paranoid Android
     SPDX-License-Identifier: Apache-2.0
-->
<resources>
    <!-- Build properties from a GMS certified device -->
    <string-array name="config_certifiedBuildProperties" translatable="false">
{items_xml}
    </string-array>
</resources>
"""

with open(xml_file, "w") as f:
    f.write(xml_content)

print(f"\nSuccessfully generated random PIF and updated files:\n- {os.path.abspath(out_file)}\n- {os.path.abspath(xml_file)}")
print("\nNew injected mock configurations:")
print(json.dumps(existing_meta, indent=4))
EOF
