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
from collections import Counter

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
    """Dynamically map an Android version string (e.g. '12.1.0', 'Android12L', '15.0.0') to an API level."""
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
_ref_cache = {
    "loaded": False,
    "api_map": {},
    "prefix_api_map": {},
    "build_patch_map": {},
    "table_html": "",
    "img_html": ""
}

def load_reference_pages():
    if _ref_cache["loaded"]:
        return
    _ref_cache["loaded"] = True
    api_map = _ref_cache["api_map"]
    prefix_api_map = _ref_cache["prefix_api_map"]
    build_patch_map = _ref_cache["build_patch_map"]

    try:
        req = urllib.request.Request(
            "https://source.android.com/docs/setup/reference/build-numbers",
            headers={'User-Agent': 'Mozilla/5.0'}
        )
        html = urllib.request.urlopen(req, timeout=15).read().decode('utf-8')

        for row in re.findall(r'<tr[^>]*>(.*?)</tr>', html, re.DOTALL | re.I):
            cols = [re.sub(r'<[^>]+>', '', c).strip() for c in re.findall(r'<td[^>]*>(.*?)</td>', row, re.DOTALL | re.I)]
            if len(cols) >= 2:
                m_api = re.search(r'API\s*level\s*(\d+)', " ".join(cols), re.I)
                if m_api:
                    api_val = int(m_api.group(1))
                    for col_text in cols[:2]:
                        if "api" in col_text.lower():
                            continue
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

        # Learn build ID prefixes and exact security patch mappings from source-code-tags-and-builds
        for row in re.findall(r'<tr[^>]*>(.*?)</tr>', table_html, re.DOTALL | re.I):
            cols = [re.sub(r'<[^>]+>', '', c).strip() for c in re.findall(r'<td[^>]*>(.*?)</td>', row, re.DOTALL | re.I)]
            if len(cols) >= 3:
                build_id, tag_str, ver_str = cols[0], cols[1], cols[2]
                api = version_str_to_api(ver_str, api_map) or version_str_to_api(tag_str, api_map)
                m_bid = re.match(r'^([A-Z0-9]{3,4})\.(\d{6})', build_id, re.I)
                if api and m_bid:
                    p = m_bid.group(1).upper()
                    prefix_api_map[p] = api
                    prefix_api_map[p[:3]] = api

                # Extract security patch date (YYYY-MM-DD) if present in the row
                m_patch = re.search(r'(\d{4}-\d{2}-\d{2})', " ".join(cols))
                if m_patch and m_bid:
                    patch_date = m_patch.group(1)
                    build_patch_map[build_id.upper()] = patch_date
                    build_patch_map[f"{m_bid.group(1).upper()}.{m_bid.group(2)}"] = patch_date
    except Exception as e:
        print(f"Warning: Failed to fetch/parse source.android.com: {e}", file=sys.stderr)

    try:
        req = urllib.request.Request(
            "https://developers.google.com/android/images",
            headers={'User-Agent': 'Mozilla/5.0', 'Cookie': 'devsite_wall_acks=nexus-image-tos'}
        )
        img_html = urllib.request.urlopen(req, timeout=15).read().decode('utf-8')
        _ref_cache["img_html"] = img_html

        # Dynamically learn all (Version -> Build Prefix -> API) mappings across all factory images.
        # Beta builds (e.g. AP41, BP11, BP22) share their 3-char prefix (AP4, BP1, BP2) with stable (AP4A, BP1A, BP2A).
        for td_text in re.findall(r'<td>\s*([0-9][^<]*?\([A-Z0-9]+\.\d{6}[^<]*?\))\s*</td>', img_html, re.I):
            m_entry = re.search(r'^([^\(]+)\(\s*([A-Z0-9]{3,4})\.\d{6}', td_text.strip(), re.I)
            if m_entry:
                ver_part, bid_prefix = m_entry.group(1).strip(), m_entry.group(2).upper()
                api = version_str_to_api(ver_part, api_map)
                if api:
                    prefix_api_map[bid_prefix] = api
                    prefix_api_map[bid_prefix[:3]] = api
    except Exception as e:
        print(f"Warning: Failed to fetch/parse factory images page: {e}", file=sys.stderr)

def build_id_to_api(build_id):
    """Map a build ID (e.g. 'AP41.240726.009', 'AD1A.240530.030') to an API level dynamically."""
    prefix_api_map = _ref_cache["prefix_api_map"]
    m = re.match(r'^([A-Z0-9]{3,4})\.\d{6}', build_id.strip(), re.I)
    if not m:
        return None
    p = m.group(1).upper()
    if p in prefix_api_map:
        return prefix_api_map[p]
    if p[:3] in prefix_api_map:
        return prefix_api_map[p[:3]]
    return None

def resolve_security_patch(build_id):
    """
    Resolve VERSION.SECURITY_PATCH (YYYY-MM-05) from a build ID.
    1. Checks exact build ID match from source.android.com build-numbers table.
    2. Parses YYMMDD from the build ID:
       - If DD <= 10 (standard monthly release stamp, e.g. CP2A.260605.016), patch is YYYY-MM-05.
       - If DD > 10 (Canary/Beta mid-to-late month branch cutoff, e.g. ZP11.260918.007 -> 2026-10-05,
         ZP11.261016.008 -> 2026-11-05), patch rolls forward to the next month's 05.
    """
    load_reference_pages()
    bid_clean = build_id.strip().upper()
    build_patch_map = _ref_cache["build_patch_map"]

    if bid_clean in build_patch_map:
        return build_patch_map[bid_clean]

    m = re.search(r'(?:^|\b)([A-Z0-9]{3,4})\.(\d{2})(\d{2})(\d{2})\.\d+', bid_clean)
    if m:
        prefix, yy, mm, dd = m.group(1), int(m.group(2)), int(m.group(3)), int(m.group(4))
        short_key = f"{prefix}.{yy:02d}{mm:02d}{dd:02d}"
        if short_key in build_patch_map:
            return build_patch_map[short_key]

        year = 2000 + yy
        month = mm
        if 1 <= month <= 12:
            # Canary & Beta builds stamped after the 10th ship with the upcoming month's security patch
            if dd > 10:
                if month == 12:
                    year += 1
                    month = 1
                else:
                    month += 1
            return f"{year:04d}-{month:02d}-05"

    return existing_meta.get("VERSION.SECURITY_PATCH", "")

def select_primary_initial_sdk(api_counts):
    """
    Given a Counter({api_level: build_count}), filter out brief pre-release factory
    stopgaps (e.g. caiman shipping with 2 AD1A Android 14 builds in Aug-Sep 2024
    right before its full Android 15 generation cycle).
    """
    if not api_counts:
        return None
    sorted_apis = sorted(api_counts.keys())
    if len(sorted_apis) >= 2:
        first_api, second_api = sorted_apis[0], sorted_apis[1]
        # If the earliest API only had 1-2 stopgap builds while the next API had a full cycle (>= 3)
        if api_counts[first_api] < 3 and api_counts[second_api] >= 3:
            return second_api
    return sorted_apis[0]

def find_initial_sdk(device_name, codename, flash_key):
    load_reference_pages()
    clean_code = codename.lower().replace("_beta", "").strip()
    target_norm = re.sub(r'\s+', ' ', device_name.lower().replace('google', '')).strip()
    api_map = _ref_cache["api_map"]
    table_html = _ref_cache["table_html"]
    img_html = _ref_cache["img_html"]

    # 1. Check official Factory Images page scoped strictly to this codename's build rows
    if img_html:
        pattern = rf'<tr\s+id="{re.escape(clean_code)}(?:[a-z0-9]+\.\d+)[^"]*"[^>]*>\s*<td>([^<]+)</td>'
        ver_matches = re.findall(pattern, img_html, re.I)
        if ver_matches:
            img_counts = Counter()
            for v_str in ver_matches:
                api = version_str_to_api(v_str, api_map)
                if api:
                    img_counts[api] += 1
            sdk = select_primary_initial_sdk(img_counts)
            if sdk:
                return sdk

    # 2. Check Android Flash Station (_beta track first, then production) via dynamic build ID decoding
    if flash_key:
        for query_prod in (f"{clean_code}_beta", clean_code):
            try:
                station_req = urllib.request.Request(
                    f"https://content-flashstation-pa.googleapis.com/v1/builds?product={query_prod}&key={flash_key}",
                    headers={'Referer': 'https://flash.android.com/'}
                )
                data = json.loads(urllib.request.urlopen(station_req, timeout=10).read().decode('utf-8'))
                builds = data.get("flashstationBuild", [])
                fs_counts = Counter()
                for b in builds:
                    rc_name = str(b.get("releaseCandidateName", ""))
                    api = build_id_to_api(rc_name)
                    if api and api >= 21:
                        fs_counts[api] += 1
                if fs_counts:
                    return min(fs_counts.keys()) if query_prod.endswith("_beta") else select_primary_initial_sdk(fs_counts)
            except Exception as e:
                print(f"Warning: Failed to fetch flash station builds for {query_prod}: {e}", file=sys.stderr)

    # 3. Fallback to Source Code Tags and Builds table
    if table_html:
        tag_counts = Counter()
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
                        tag_counts[api] += 1
        sdk = select_primary_initial_sdk(tag_counts)
        if sdk:
            return sdk

    return None

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
    sdk = find_initial_sdk(cand_name, cand_device, flash_key)
    if sdk is not None and sdk >= MIN_INITIAL_SDK:
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

security_patch = resolve_security_patch(build_id)
if not security_patch:
    print(f"Could not resolve security patch for build ID: {build_id}")
    sys.exit(1)

print(f"Resolved build {build_id} ({build_inc}) -> security patch {security_patch}")

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
existing_meta["VERSION.SECURITY_PATCH"] = security_patch
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
