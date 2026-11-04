#!/usr/bin/env python3
"""Export only distributable project sources, never local diagnostics/user data."""
from pathlib import Path
import hashlib, json, shutil, sys, zipfile, re
root = Path(__file__).resolve().parents[1]
destination = root / 'dist' / 'Orbit-3.0.0-source'
if destination.exists():
    # Confined generated export only; never remove the working project or user files.
    assert destination.parent == root / 'dist'
    shutil.rmtree(destination)
destination.mkdir(parents=True)
directories = ['DynamicIsland', 'OrbitShared', 'OrbitWidgets', 'DynamicIslandTests', 'DynamicIslandUITests',
               'Orbit.xcodeproj', 'LowPowerHelper', 'Contents', 'Frameworks', 'mediaremote-adapter',
               'LottieAnimations', 'scripts', 'tests']
files = ['README.md', 'PRIVACY.md', 'RELEASE_NOTES.md', 'LICENSE', 'NOTICE', 'COPYRIGHT_ASSETS', 'TRADEMARKS',
         'CODE_OF_CONDUCT.md', 'CONTRIBUTING.md', 'Localizable.xcstrings', 'VERSION', '.gitattributes', '.gitignore',
         '.github/workflows/ci.yml', '.github/assets/orbit-icon.png']
def ignore(directory, names):
    return [n for n in names if n in {'.DS_Store', '.build', '.git', 'xcuserdata', '__pycache__'}
            or n.endswith(('.xcuserstate', '.profraw', '.log', '.pyc'))]
for name in directories:
    source = root / name
    if source.exists():shutil.copytree(source, destination / name, symlinks=True, ignore=ignore)
for name in files:
    source = root / name
    if source.exists():
        target = destination / name; target.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(source, target)
# Publish a concise changelog, without historical local paths/diagnostics.
(destination / 'CHANGELOG.md').write_text('# Changelog\n\n' + (root / 'RELEASE_NOTES.md').read_text())
patterns = {'private_key': rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
            'github_token': rb'(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})',
            'service_token': rb'(?:sk-[A-Za-z0-9]{30,}|xox[baprs]-[A-Za-z0-9-]{20,})'}
findings = []
manifest = []
for path in sorted(destination.rglob('*')):
    if path.is_symlink():
        if not path.resolve().is_relative_to(destination.resolve()):raise RuntimeError('Export symlink escapes source: ' + str(path.relative_to(destination)))
        continue
    if not path.is_file():continue
    data = path.read_bytes()
    for kind, pattern in patterns.items():
        if re.search(pattern, data):findings.append({'file':str(path.relative_to(destination)), 'kind':kind})
    manifest.append({'path':str(path.relative_to(destination)), 'bytes':len(data), 'sha256':hashlib.sha256(data).hexdigest()})
report = root / '.build/diagnostics/orbit-3.0.0'
report.mkdir(parents=True, exist_ok=True)
(report / 'public-export-review.json').write_text(json.dumps({'files':len(manifest),'bytes':sum(x['bytes'] for x in manifest),'findings':findings}, indent=2))
if findings:raise RuntimeError('Review possible credentials before publishing; see local report')
(destination / 'SOURCE_MANIFEST.json').write_text(json.dumps(manifest, indent=2) + '\n')
archive = destination.parent / (destination.name + '.zip')
# Preserve framework symlinks and executable bits in the source archive.
with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED) as package:
    for path in sorted(destination.rglob('*')):
        relative = str(Path(destination.name) / path.relative_to(destination))
        if path.is_symlink():
            import os
            item = zipfile.ZipInfo(relative)
            item.create_system = 3
            item.external_attr = (0o120777 << 16)
            package.writestr(item, os.readlink(path))
        elif path.is_file():
            package.write(path, relative)
print(json.dumps({'source':str(destination), 'archive':str(archive), 'files':len(manifest),'bytes':sum(x['bytes'] for x in manifest)}))
