# Offline Package Bundle

Run `prepare-offline.sh` on an internet-connected machine **before** transferring to the air-gapped host.

The script downloads:
- Python wheel files → `packages/python/`
- Vue.js 3 CDN file → `../lib/vue.global.prod.js`
- (Optional) apt .deb files for Ubuntu 24.04 dependencies

Transfer the entire repo directory (or the tarball it creates) to the target host and run `install.sh`.
The install script automatically detects offline mode and uses these local packages.
