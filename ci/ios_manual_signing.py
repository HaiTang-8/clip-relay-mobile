#!/usr/bin/env python3
"""Switch the Release configs of Runner and Share Extension to manual signing and write ExportOptions.plist.

Usage: ios_manual_signing.py <pbxproj> <export_options_out> <method> <identity> <profile.mobileprovision>...
"""
import plistlib
import re
import subprocess
import sys

KEYS = ('CODE_SIGN_STYLE', 'DEVELOPMENT_TEAM', 'PROVISIONING_PROFILE_SPECIFIER', 'CODE_SIGN_IDENTITY', '"CODE_SIGN_IDENTITY[sdk=iphoneos*]"')


def read_profile(path):
    data = plistlib.loads(subprocess.run(['security', 'cms', '-D', '-i', path], check=True, capture_output=True).stdout)
    team = data['TeamIdentifier'][0]
    bundle_id = data['Entitlements']['application-identifier'].removeprefix(f'{team}.')
    return bundle_id, team, data['Name']


def main():
    pbxproj, export_options, method, identity, *profile_paths = sys.argv[1:]
    profiles = {}
    teams = set()
    for path in profile_paths:
        bundle_id, team, name = read_profile(path)
        profiles[bundle_id] = name
        teams.add(team)
    if len(teams) != 1:
        sys.exit(f'profiles must belong to one team, got {sorted(teams)}')
    team = teams.pop()

    source = open(pbxproj).read()
    patched = set()

    def patch(match):
        block = match.group(0)
        bundle = re.search(r'\n\t+PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);', block)
        if 'name = Release;' not in block or not bundle or bundle.group(1) not in profiles:
            return block
        bundle_id = bundle.group(1)
        patched.add(bundle_id)
        block = re.sub(r'\n\t+(%s) = [^\n]*;' % '|'.join(re.escape(k) for k in KEYS), '', block)
        settings = ''.join(
            f'\n\t\t\t\t{k} = {v};'
            for k, v in (
                ('CODE_SIGN_STYLE', 'Manual'),
                ('DEVELOPMENT_TEAM', team),
                ('PROVISIONING_PROFILE_SPECIFIER', f'"{profiles[bundle_id]}"'),
                ('CODE_SIGN_IDENTITY', f'"{identity}"'),
                ('"CODE_SIGN_IDENTITY[sdk=iphoneos*]"', f'"{identity}"'),
            )
        )
        return block.replace('buildSettings = {', 'buildSettings = {' + settings, 1)

    source = re.sub(r'\t\t[0-9A-F]{24} /\* Release \*/ = \{\n\t\t\tisa = XCBuildConfiguration;.*?\n\t\t\};', patch, source, flags=re.S)
    missing = set(profiles) - patched
    if missing:
        sys.exit(f'no Release config found for {sorted(missing)}')
    open(pbxproj, 'w').write(source)

    with open(export_options, 'wb') as f:
        plistlib.dump({
            'method': method,
            'teamID': team,
            'signingStyle': 'manual',
            'signingCertificate': identity,
            'provisioningProfiles': profiles,
            'uploadSymbols': False,
        }, f)
    print(f'manual signing: team {team}, profiles {profiles}')


if __name__ == '__main__':
    main()
