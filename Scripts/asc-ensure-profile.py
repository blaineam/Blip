#!/usr/bin/env python3
"""Ensure a MAC_APP_STORE provisioning profile exists for com.blainemiller.Blip,
create it via the App Store Connect API if missing, install it into
~/Library/MobileDevice/Provisioning Profiles/, and print "NAME\\tUUID\\tPATH".

Requires env: ASC_API_KEY_ID, ASC_API_ISSUER_ID and the matching .p8 key in
~/.appstoreconnect/private_keys/. Uses only the stdlib + `cryptography`.
"""
import json, time, base64, os, sys, urllib.request, urllib.error
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.asymmetric import ec, utils

BUNDLE = "com.blainemiller.Blip"
PROFILE_NAME = "Blip Stats App Store (CI)"
PROFILE_TYPE = "MAC_APP_STORE"

kid = os.environ["ASC_API_KEY_ID"]; iss = os.environ["ASC_API_ISSUER_ID"]
key = open(os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{kid}.p8")).read()
pk = serialization.load_pem_private_key(key.encode(), password=None)

def b64u(b): return base64.urlsafe_b64encode(b).rstrip(b"=")
def jwt():
    hdr = b64u(json.dumps({"alg":"ES256","kid":kid,"typ":"JWT"}).encode())
    now = int(time.time())
    pay = b64u(json.dumps({"iss":iss,"iat":now,"exp":now+300,"aud":"appstoreconnect-v1"}).encode())
    der = pk.sign(hdr+b"."+pay, ec.ECDSA(hashes.SHA256()))
    r,s = utils.decode_dss_signature(der)
    return (hdr+b"."+pay+b"."+b64u(r.to_bytes(32,"big")+s.to_bytes(32,"big"))).decode()
def api(method, path, body=None):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com"+path,
        data=json.dumps(body).encode() if body else None,
        headers={"Authorization":"Bearer "+jwt(),"Content-Type":"application/json"}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        sys.stderr.write(f"API {method} {path} -> {e.code}: {e.read().decode()[:500]}\n")
        sys.exit(1)

def install(profile_data):
    name = profile_data["attributes"]["name"]
    uuid = profile_data["attributes"]["uuid"]
    content = base64.b64decode(profile_data["attributes"]["profileContent"])
    dest = os.path.expanduser(f"~/Library/MobileDevice/Provisioning Profiles/{uuid}.provisionprofile")
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    open(dest, "wb").write(content)
    print(f"{name}\t{uuid}\t{dest}")

# Reuse our existing profile if present (avoids duplicate-name 409s). The list
# route doesn't reliably populate the bundleId relationship, so match by the
# name we own for this bundle, then fetch profileContent from the detail route.
_, profs = api("GET", f"/v1/profiles?filter[profileType]={PROFILE_TYPE}"
                       "&fields[profiles]=name,profileState&limit=200")
for p in profs.get("data", []):
    if p["attributes"]["profileState"] == "ACTIVE" and p["attributes"]["name"] == PROFILE_NAME:
        _, d = api("GET", f"/v1/profiles/{p['id']}?fields[profiles]=name,uuid,profileContent")
        install(d["data"]); sys.exit(0)

# Resolve bundleId id.
_, bids = api("GET", f"/v1/bundleIds?filter[identifier]={BUNDLE}&fields[bundleIds]=identifier")
if not bids.get("data"):
    sys.stderr.write(f"no bundleId registered for {BUNDLE}\n"); sys.exit(1)
bundle_id = bids["data"][0]["id"]

# Pick a distribution certificate (must have its private key locally to sign).
_, certs = api("GET", "/v1/certificates?filter[certificateType]=DISTRIBUTION&fields[certificates]=displayName,certificateType")
if not certs.get("data"):
    sys.stderr.write("no DISTRIBUTION certificate visible to this API key\n"); sys.exit(1)
cert_id = certs["data"][0]["id"]

# Create the profile.
body = {"data": {"type":"profiles",
    "attributes": {"name": PROFILE_NAME, "profileType": PROFILE_TYPE},
    "relationships": {
        "bundleId": {"data": {"type":"bundleIds","id": bundle_id}},
        "certificates": {"data": [{"type":"certificates","id": cert_id}]}}}}
_, created = api("POST", "/v1/profiles", body)
install(created["data"])
