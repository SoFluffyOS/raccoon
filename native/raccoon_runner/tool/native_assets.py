"""Install Flutter's host code assets for the standalone embedder."""

import json
from pathlib import Path
import shutil
import sys


def install(output, app):
    output, app = Path(output).resolve(), Path(app).resolve()
    manifest_path = output / 'App.framework/Resources/flutter_assets/NativeAssetsManifest.json'
    built, installed = output / 'native_assets', app / 'native_assets'
    if installed.exists():
        shutil.rmtree(installed)
    # Projects without hooks may not produce a native asset manifest.
    if not manifest_path.is_file():
        return
    manifest = json.loads(manifest_path.read_text())
    if built.is_dir():
        shutil.copytree(built, installed, symlinks=True)
    count = 0
    for assets in manifest.get('native-assets', {}).values():
        for asset, location in assets.items():
            if len(location) != 2 or location[0] != 'absolute':
                continue
            original = location[1]
            if original.startswith('@rpath/'):
                target = installed / original[len('@rpath/'):]
            elif not Path(original).is_absolute():
                target = installed / original
            else:
                try:
                    target = installed / Path(original).relative_to(built)
                except ValueError:
                    target = Path(original)
            if not target.is_file():
                raise FileNotFoundError('native asset %s not found: %s' % (asset, target))
            assets[asset] = ['absolute', str(target)]
            count += 1
    (app / 'flutter_assets/NativeAssetsManifest.json').write_text(json.dumps(manifest))
    print('raccoon-device: native assets, %d for this host' % count, file=sys.stderr)


if __name__ == '__main__':
    install(*sys.argv[1:])
