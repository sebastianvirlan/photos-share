"""Which of Photos' own fields tells HDR photos and videos apart? Compares the library's
HDR field with what the files really contain, for a sample of recent items.

    uv run python scripts/check_hdr.py "/Volumes/.../Some.photoslibrary" [how-many]

Read-only: it only reads the library and its original files.
"""

import sys
from collections import Counter

import osxphotos
import Quartz
from AVFoundation import AVMediaCharacteristicContainsHDRVideo, AVURLAsset
from Foundation import NSURL


def photo_is_hdr(path: str) -> bool:
    src = Quartz.CGImageSourceCreateWithURL(NSURL.fileURLWithPath_(path), None)
    if src is None:
        return False
    return any(Quartz.CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, t)
               for t in ("kCGImageAuxiliaryDataTypeHDRGainMap", "kCGImageAuxiliaryDataTypeISOGainMap"))


def video_is_hdr(path: str) -> bool:
    asset = AVURLAsset.URLAssetWithURL_options_(NSURL.fileURLWithPath_(path), None)
    return bool(asset.tracksWithMediaCharacteristic_(AVMediaCharacteristicContainsHDRVideo))


def main() -> None:
    lib = sys.argv[1]
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 400
    photos = [p for p in osxphotos.PhotosDB(lib).photos() if p.path]
    photos.sort(key=lambda p: p.date, reverse=True)
    rows = Counter()
    for p in photos[:n]:
        kind = "video" if p.ismovie else "photo"
        try:
            real = video_is_hdr(p.path) if p.ismovie else photo_is_hdr(p.path)
        except Exception:
            real = "?"
        rows[(kind, p._info.get("customRenderedValue"), p.hdr, real)] += 1
    print(f"{'kind':6} {'db HDR field':>12} {'osxphotos hdr':>14} {'file is HDR':>12} {'count':>6}")
    for (kind, field, flag, real), c in sorted(rows.items(), key=str):
        print(f"{kind:6} {field!s:>12} {flag!s:>14} {real!s:>12} {c:>6}")


if __name__ == "__main__":
    main()
