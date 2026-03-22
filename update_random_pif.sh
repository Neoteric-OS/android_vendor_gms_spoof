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

try:
    with open(out_file, "r") as f:
        existing_meta = json.load(f)
except Exception as e:
    print(f"Could not load existing {out_file}! Make sure it exists in the same folder as the script.")
    sys.exit(1)

print("Fetching latest Android versions...")
versions_html = get_html("https://developer.android.com/about/versions")
links = re.findall(r'https://developer\.android\.com/about/versions/[0-9]+', versions_html)
latest_build_url = sorted(links)[-1]

print("Fetching latest factory image info...")
latest_html = get_html(latest_build_url)
factory_url_match = re.search(r'href="(.*download.*)"', latest_html)
if not factory_url_match:
    print("Could not find factory image download link.")
    sys.exit(1)
    
factory_html = get_html("https://developer.android.com" + factory_url_match.group(1))

devices = {}
for m in re.finditer(r'<tr\s+id="([^"]+)"[^>]*>\s*<td>([^<]+)</td>', factory_html, re.I):
    devices[m.group(2).strip()] = m.group(1).strip() + "_beta"

if not devices:
    print("No beta devices found.")
    sys.exit(1)

device_name = random.choice(list(devices.keys()))
product = devices[device_name]
device = product.replace("_beta", "")

print(f"Selected random device: {device_name} ({device})")

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
for rc, bi in zip(re.finditer(r'"releaseCandidateName"\s*:\s*"([^"]+)"', station_json),
                  re.finditer(r'"buildId"\s*:\s*"([^"]+)"', station_json)):
    build_id = rc.group(1)
    build_inc = bi.group(1)

release_version = existing_meta.get("VERSION.RELEASE", "CANARY")

fingerprint = f"google/{product}/{device}:CANARY/{build_id}/{build_inc}:user/release-keys"

existing_meta["MANUFACTURER"] = "Google"
existing_meta["MODEL"] = device_name
existing_meta["FINGERPRINT"] = fingerprint
existing_meta["BRAND"] = "google"
existing_meta["PRODUCT"] = product
existing_meta["DEVICE"] = device
existing_meta["ID"] = build_id
existing_meta["VERSION.INCREMENTAL"] = build_inc
existing_meta["TYPE"] = "user"
existing_meta["TAGS"] = "release-keys"

with open(out_file, "w") as f:
    json.dump(existing_meta, f, indent=4)
    
print(f"\nSuccessfully generated random PIF and updated file:\n{os.path.abspath(out_file)}")
print("\nNew injected mock configurations:")
print(json.dumps(existing_meta, indent=4))
EOF
