#!/usr/bin/env python3
"""Validate the source configuration; --signing requires developer-owned IDs."""
import pathlib, plistlib, re, sys
root=pathlib.Path(__file__).resolve().parents[1]
app=plistlib.loads((root/'Config/App.entitlements').read_bytes())
widget=plistlib.loads((root/'Widget/entitlements.plist').read_bytes())
assert app['com.apple.security.app-sandbox'] and widget['com.apple.security.app-sandbox']
assert app['com.apple.security.application-groups']==widget['com.apple.security.application-groups']==['$(HANJU_APP_GROUP)']
assert app['com.apple.security.files.user-selected.read-write']
# WKWebView needs network.client to render even local pages in the sandbox; nothing else network-related.
assert app.get('com.apple.security.network.client') is True
assert not any(k.startswith('com.apple.security.network') and k!='com.apple.security.network.client' for k in app)
assert not any(k.startswith('com.apple.security.network') for k in widget)
for path in ['Resources/PrivacyInfo.xcprivacy','Widget/PrivacyInfo.xcprivacy']:
 d=plistlib.loads((root/path).read_bytes());assert d['NSPrivacyTracking'] is False and not d['NSPrivacyCollectedDataTypes']
project=(root/'project.yml').read_text()
assert project.count('path: Shared')==2 and project.count('HanjuAppGroup: $(HANJU_APP_GROUP)')==2
assert 'CODE_SIGN_IDENTITY: "-"' not in project and 'ENABLE_HARDENED_RUNTIME: YES' in project
main=(root/'Sources/main.swift').read_text()
assert 'Library/Containers/' not in main and 'modificationDate' not in main and 'setValue(false, forKey:' not in main
assert 'HanjuStore.production()' in main
if '--signing' in sys.argv:
 values={m[1]:m[2].strip() for m in re.finditer(r'^(\w+)\s*=\s*(.*)$',(root/'Config/Signing.xcconfig').read_text(),re.M)}
 if not re.fullmatch(r'[A-Z0-9]{10}',values.get('DEVELOPMENT_TEAM','')):sys.exit('Apple Developer Team ID를 Config/Signing.xcconfig에 입력하세요.')
 bundle=values.get('HANJU_BUNDLE_ID','')
 if bundle.startswith(('com.example.','local.')) or not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+',bundle):sys.exit('직접 등록할 고유 Bundle ID를 설정하세요.')
 if not values.get('HANJU_APP_GROUP',''):sys.exit('App Group ID를 설정하세요.')
print('PASS: sandbox, shared App Group, privacy resources, public WKWebView API and signing configuration'+(' (developer IDs supplied)' if '--signing' in sys.argv else ' (developer IDs pending)'))
