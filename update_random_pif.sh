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

def find_initial_sdk(device_name, codename, flash_key, fallback_sdk=None):
    candidates = []

    # 1. Check official AOSP tags from source.android.com build-numbers
    try:
        req = urllib.request.Request(
            "https://source.android.com/docs/setup/reference/build-numbers",
            headers={'User-Agent': 'Mozilla/5.0'}
        )
        html = urllib.request.urlopen(req, timeout=5).read().decode('utf-8')

        version_to_api = {
            "pie": 28, "oreo": 26, "nougat": 24, "marshmallow": 23,
            "android10": 29, "android11": 30, "android12": 31, "android12l": 32,
            "android13": 33, "android14": 34, "android15": 35, "android16": 36, "android17": 37
        }
        for m in re.finditer(r'<tr>\s*<td>([^<]+)</td>\s*<td>([^<]+)</td>\s*<td>API level ([0-9]+)', html, re.I):
            vname = m.group(1).strip().lower().replace(' ', '')
            api = int(m.group(3))
            version_to_api[vname] = api

        pos = html.find('id="source-code-tags-and-builds"')
        if pos != -1:
            end_pos = html.find('</table>', pos)
            table_html = html[pos:end_pos] if end_pos != -1 else html[pos:]
            target_norm = re.sub(r'\s+', ' ', device_name.lower().replace('google', '')).strip()

            device_min_api = {}
            for row in re.findall(r'<tr>(.*?)</tr>', table_html, re.DOTALL):
                cols = re.findall(r'<td[^>]*>(.*?)</td>', row, re.DOTALL)
                if len(cols) >= 4:
                    v_str = re.sub(r'<[^>]+>', '', cols[2]).strip().lower().replace(' ', '')
                    d_str = re.sub(r'<[^>]+>', '', cols[3]).strip()
                    api = version_to_api.get(v_str)
                    if not api:
                        digits = re.findall(r'\d+', v_str)
                        if digits and digits[0] in version_to_api:
                            api = version_to_api[digits[0]]
                    if not api:
                        continue
                    for dev in d_str.split(','):
                        dev_norm = re.sub(r'\s+', ' ', dev.lower().replace('google', '')).strip()
                        if not dev_norm:
                            continue
                        if dev_norm not in device_min_api or api < device_min_api[dev_norm]:
                            device_min_api[dev_norm] = api

            if target_norm in device_min_api:
                candidates.append(device_min_api[target_norm])
    except Exception as e:
        print(f"Warning: Failed to fetch/parse source.android.com: {e}", file=sys.stderr)

    # 2. Check Android Flash Station production builds API level
    if flash_key:
        try:
            station_req = urllib.request.Request(
                f"https://content-flashstation-pa.googleapis.com/v1/builds?product={codename}&key={flash_key}",
                headers={'Referer': 'https://flash.android.com/'}
            )
            data = json.loads(urllib.request.urlopen(station_req, timeout=5).read().decode('utf-8'))
            builds = data.get("flashstationBuild", [])
            apis = [b.get("apiLevel") for b in builds if isinstance(b.get("apiLevel"), int)]
            if apis:
                candidates.append(min(apis))
        except Exception as e:
            print(f"Warning: Failed to fetch flash station builds for {codename}: {e}", file=sys.stderr)

    if candidates:
        return min(candidates)

    # 3. Heuristic fallback based on device naming convention
    dlower = device_name.lower()
    if "tablet" in dlower:
        return 33
    if "fold" in dlower and not any(k in dlower for k in ["9", "10", "11", "12"]):
        return 33
    m = re.search(r'pixel\s*(\d+)', dlower)
    if m:
        gen = int(m.group(1))
        is_a = bool(re.search(r'pixel\s*\d+a', dlower))
        if gen == 1: return 25
        if gen == 2: return 26
        if gen == 3: return 28
        if gen == 4: return 29
        if gen == 5: return 30
        if gen == 6: return 31
        if gen == 7: return 33
        if gen == 8: return 34
        if gen == 9: return 35 if is_a else 34
        if gen >= 10: return gen + 26

    # 4. Final safety net
    if fallback_sdk:
        try:
            return int(fallback_sdk)
        except (ValueError, TypeError):
            pass

    return 33

devices = {}
for m in re.finditer(r'<tr\s+id="([^"]+)"[^>]*>\s*<td>([^<]+)</td>', factory_html, re.I):
    codename = m.group(1).strip()
    name = m.group(2).strip()
    devices[name] = codename + "_beta"

if not devices:
    print("Could not find any devices in the latest factory images.")
    sys.exit(1)

device_name = random.choice(list(devices.keys()))
product = devices[device_name]
device = product.replace("_beta", "")

print("Getting flash station key...")
flash_html = get_html("https://flash.android.com/")
flash_key_match = re.search(r'data-client-config\s*=\s*"(?:[^,]*?,){2}\s*&quot;([^&]+)&quot;', flash_html, re.I)
if not flash_key_match:
    print("Failed to get flash key.")
    sys.exit(1)

flash_key = flash_key_match.group(1).replace("&quot;", '"').replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")

print(f"Determining initial SDK for {device_name} ({device})...")
initial_sdk = find_initial_sdk(device_name, device, flash_key, existing_meta.get("VERSION.DEVICE_INITIAL_SDK_INT"))

print(f"Selected random device: {device_name} ({device}), initial SDK {initial_sdk}")

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
