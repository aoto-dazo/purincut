"""App Store Connect API で Bundle ID を登録する（すでにあれば何もしない）"""
import json, os, sys, time, urllib.request, urllib.error
import jwt  # pyjwt

KEY_ID = os.environ["ASC_KEY_ID"]; ISSUER = os.environ["ASC_ISSUER_ID"]
KEY = open(os.environ["ASC_KEY_PATH"]).read()
BUNDLE = os.environ.get("BUNDLE_ID", "com.aotodazo.purincut")
NAME = os.environ.get("BUNDLE_NAME", "PurinCut")

def token():
    now = int(time.time())
    return jwt.encode({"iss": ISSUER, "iat": now, "exp": now + 1000, "aud": "appstoreconnect-v1"},
                      KEY, algorithm="ES256", headers={"kid": KEY_ID, "typ": "JWT"})

def api(method, path, body=None):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path, method=method,
                                 data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        print("API エラー", e.code, e.read().decode()[:2000]); sys.exit(1)

found = api("GET", f"/v1/bundleIds?filter[identifier]={BUNDLE}&limit=5")
if any(d["attributes"]["identifier"] == BUNDLE for d in found.get("data", [])):
    print("Bundle ID は登録済み:", BUNDLE)
else:
    api("POST", "/v1/bundleIds", {"data": {"type": "bundleIds", "attributes": {"identifier": BUNDLE, "name": NAME, "platform": "IOS"}}})
    print("Bundle ID を登録しました:", BUNDLE)

apps = api("GET", f"/v1/apps?filter[bundleId]={BUNDLE}&limit=5")
if apps.get("data"):
    print("App Store Connect のアプリ登録あり:", apps["data"][0]["attributes"].get("name"))
else:
    print("::warning::App Store Connect にまだアプリが作られていません。マイApp → ＋ → 新規App で Bundle ID", BUNDLE, "のアプリを作ってください。")
    open(os.environ.get("GITHUB_OUTPUT", "/dev/null"), "a").write("app_missing=1\n")
