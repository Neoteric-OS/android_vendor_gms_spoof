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

def get_html(url, timeout=15, extra_headers=None):
    headers = {'User-Agent': 'Mozilla/5.0'}
    if extra_headers:
        headers.update(extra_headers)
    req = urllib.request.Request(url, headers=headers)
    try:
        return urllib.request.urlopen(req, timeout=timeout).read().decode('utf-8')
    except Exception as e:
        print(f"Error fetching {url}: {e}", file=sys.stderr)
        sys.exit(1)

out_file = "gms_certified_props.json"

# Hardcoded security patch level
SECURITY_PATCH = "2026-10-05"

# Minimum required DEVICE_INITIAL_SDK_INT (API 32 = Android 12L)
MIN_INITIAL_SDK = 32

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

def version_str_to_api(v_str, api_map):
    """Dynamically map an Android version string (e.g. '12.1.0', 'Android12L', '14.0.0') to an API level."""
    s = v_str.strip().lower().replace(" ", "")
    if s in api_map:
        return api_map[s]

    # Normalize 'android-12.1.0_r12' or '12.1.0 (SD2A...)' -> '12.1' or '12l'
    if "12l" in s or re.search(r'(?:^|\D)12\.1(?:\D|$)', s):
        return api_map.get("12l", 32)

    m = re.search(r'(\d+)\.(\d+)', s)
    if m:
        major, minor = int(m.group(1)), int(m.group(2))
        if f"{major}.{minor}" in api_map:
            return api_map[f"{major}.{minor}"]
        if str(major) in api_map and minor == 0:
            return api_map[str(major)]
        # Algorithmic mapping for Android 13+ (API = Major + 20) and 10-12 (API = Major + 19)
        if major >= 13:
            return major + 20
        if 10 <= major <= 12:
            return 32 if (major == 12 and minor >= 1) else major + 19

    m_maj = re.search(r'(\d+)', s)
    if m_maj:
        major = int(m_maj.group(1))
        if str(major) in api_map:
            return api_map[str(major)]
        if major >= 13:
            return major + 20
        if 10 <= major <= 12:
            return major + 19

    return None

# Cache reference pages once so checking multiple candidate devices is fast
_ref_cache = {"loaded": False, "api_map": {}, "table_html": "", "img_html": ""}

def load_reference_pages():
    if _ref_cache["loaded"]:
        return
    _ref_cache["loaded"] = True
    api_map = _ref_cache["api_map"]

    try:
        req = urllib.request.Request(
            "https://source.android.com/docs/setup/reference/build-numbers",
            headers={'User-Agent': 'Mozilla/5.0'}
        )
        html = urllib.request.urlopen(req, timeout=15).read().decode('utf-8')

        for row in re.findall(r'<tr[^>]*>(.*?)</tr>', html, re.DOTALL | re.I):
            cols = [re.sub(r'<[^>]+>', '', c).strip() for c in re.findall(r'<td[^>]*>(.*?)</td>', row, re.DOTALL | re.I)]
            if len(cols) >= 3:
                m_api = re.search(r'API\s*level\s*(\d+)', " ".join(cols), re.I)
                if m_api:
                    api_val = int(m_api.group(1))
                    for col_text in cols[:2]:
                        key = col_text.lower().replace(" ", "")
                        api_map[key] = api_val
                        api_map[key.replace("android", "")] = api_val
                        for ver_tok in re.findall(r'\d+(?:\.\d+)?l?', key):
                            api_map[ver_tok] = api_val

        pos = html.find('id="source-code-tags-and-builds"')
        table_html = html[pos:] if pos != -1 else html
        end_pos = table_html.find('</table>')
        if end_pos != -1:
            table_html = table_html[:end_pos]
        _ref_cache["table_html"] = table_html
    except Exception as e:
        print(f"Warning: Failed to fetch/parse source.android.com: {e}", file=sys.stderr)

    try:
        req = urllib.request.Request(
            "https://developers.google.com/android/images",
            headers={'User-Agent': 'Mozilla/5.0', 'Cookie': 'devsite_wall_acks=nexus-image-tos'}
        )
        _ref_cache["img_html"] = urllib.request.urlopen(req, timeout=15).read().decode('utf-8')
    except Exception as e:
        print(f"Warning: Failed to fetch/parse factory images page: {e}", file=sys.stderr)

def find_initial_sdk(device_name, codename, flash_key, fallback_sdk=None):
    load_reference_pages()
    clean_code = codename.lower().replace("_beta", "").strip()
    target_norm = re.sub(r'\s+', ' ', device_name.lower().replace('google', '')).strip()
    api_map = _ref_cache["api_map"]
    table_html = _ref_cache["table_html"]
    img_html = _ref_cache["img_html"]
    candidates = []

    # 1. Check Source Code Tags and Builds table
    if table_html:
        for row in re.findall(r'<tr[^>]*>(.*?)</tr>', table_html, re.DOTALL | re.I):
            cols = [re.sub(r'<[^>]+>', '', c).strip() for c in re.findall(r'<td[^>]*>(.*?)</td>', row, re.DOTALL | re.I)]
            if len(cols) >= 4:
                tag_str, ver_str, dev_col = cols[1], cols[2], cols[3]
                api = version_str_to_api(ver_str, api_map) or version_str_to_api(tag_str, api_map)
                if not api:
                    continue
                for dev in dev_col.split(','):
                    dev_norm = re.sub(r'\s+', ' ', dev.lower().replace('google', '')).strip()
                    if dev_norm == target_norm:
                        candidates.append(api)

    # 2. Check official Factory Images page by exact codename (first entry = launch build)
    if img_html:
        pattern = rf'<tr\s+id="{re.escape(clean_code)}[^"]*"[^>]*>\s*<td>([^<]+)</td>'
        ver_matches = re.findall(pattern, img_html, re.I)
        if ver_matches:
            launch_api = version_str_to_api(ver_matches[0], api_map)
            if launch_api:
                candidates.append(launch_api)

    # 3. Check Android Flash Station production builds API level
    if flash_key:
        try:
            station_req = urllib.request.Request(
                f"https://content-flashstation-pa.googleapis.com/v1/builds?product={clean_code}&key={flash_key}",
                headers={'Referer': 'https://flash.android.com/'}
            )
            data = json.loads(urllib.request.urlopen(station_req, timeout=10).read().decode('utf-8'))
            builds = data.get("flashstationBuild", [])
            apis = []
            for b in builds:
                for k in ("apiLevel", "releaseTrackVersion"):
                    val = b.get(k)
                    if isinstance(val, int) and val >= 21:
                        apis.append(val)
                    elif isinstance(val, str) and val.isdigit() and int(val) >= 21:
                        apis.append(int(val))
            if apis:
                candidates.append(min(apis))
        except Exception as e:
            print(f"Warning: Failed to fetch flash station builds for {clean_code}: {e}", file=sys.stderr)

    if candidates:
        return min(candidates)

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

print("Getting flash station key...")
flash_html = get_html("https://flash.android.com/")
flash_key_match = re.search(r'data-client-config\s*=\s*"(?:[^,]*?,){2}\s*&quot;([^&]+)&quot;', flash_html, re.I)
if not flash_key_match:
    print("Failed to get flash key.")
    sys.exit(1)

flash_key = flash_key_match.group(1).replace("&quot;", '"').replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")

candidate_names = list(devices.keys())
random.shuffle(candidate_names)

device_name = None
product = None
device = None
initial_sdk = None

for cand_name in candidate_names:
    cand_product = devices[cand_name]
    cand_device = cand_product.replace("_beta", "")
    print(f"Checking initial SDK for {cand_name} ({cand_device})...")
    sdk = find_initial_sdk(cand_name, cand_device, flash_key, existing_meta.get("VERSION.DEVICE_INITIAL_SDK_INT"))
    if sdk >= MIN_INITIAL_SDK:
        device_name = cand_name
        product = cand_product
        device = cand_device
        initial_sdk = sdk
        break
    print(f"Skipping {cand_name} ({cand_device}): initial SDK {sdk} is less than {MIN_INITIAL_SDK}.")

if not device_name:
    print(f"Could not find any device with DEVICE_INITIAL_SDK_INT >= {MIN_INITIAL_SDK}.")
    sys.exit(1)

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