#!/usr/bin/env python3
"""Validate visible keys, bilingual coverage and matching printf placeholders."""
import json,re,sys
from pathlib import Path
root=Path(__file__).resolve().parents[1]
cat=json.loads((root/'CodexM/Resources/Localizable.xcstrings').read_text())
strings=cat['strings']; errors=[]
for key,entry in strings.items():
    values=[]
    for lang in ['en','zh-Hans']:
        try:
            unit=entry['localizations'][lang]['stringUnit']
            assert unit['state']=='translated' and unit['value']
            values.append(unit['value'])
        except (KeyError,AssertionError): errors.append(f'{key}: missing {lang}')
    if len(values)==2:
        fmt=lambda value: re.findall(r'%(?:\d+\$)?[df@]',value)
        if fmt(values[0])!=fmt(values[1]): errors.append(f'{key}: format mismatch')
keys=set()
for file in (root/'CodexM').rglob('*.swift'):
    source=file.read_text()
    keys.update(re.findall(r'(?:text|menuButton)\("([^"\\]+)"',source))
    for match in re.finditer(r'\b(?:Text|Button|Label|TextField|Picker|Toggle|Section)\("([^"\\]+)"',source):
        if match.group(1)!='CodexM': errors.append(f'{file.name}: hardcoded UI string {match.group(1)}')
keys.update('state.'+s for s in ['stopped','launching','running','terminating','crashed','error'])
keys.update('auth.'+s for s in ['unknown','signedOut','signingIn','signedIn'])
keys.update('handoff.status.'+s for s in ['ready','launched','failed'])
keys.update('native.stage.'+s for s in ['load','initialize','resume','read','page','restart','compare','rollout','schema'])
keys.update('native.status.'+s for s in ['prepared','importing','verified','failed','restoring','rolledBack'])
keys.update('native.error.'+s for s in ['runtime','capability','busy','conflict','incompatible','unsupported','changed','invalid','helper','rollbackChanged','recovery'])
errorSource=(root/'CodexM/Utilities/Errors.swift').read_text().split('var errorDescription')[0]
for line in errorSource.splitlines():
    if line.strip().startswith('case '): keys.update('error.'+e.strip() for e in line.strip()[5:].split(','))
for key in sorted(keys):
    if key not in strings: errors.append('Missing key: '+key)
if errors:
    print('\n'.join(errors));sys.exit(1)
print(f'Localization validated: {len(strings)} keys, English + Simplified Chinese, format placeholders match.')
