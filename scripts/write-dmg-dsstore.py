#!/usr/bin/env python3
"""Writes the Finder layout for the DevStack installer image.

Usage:
  write-dmg-dsstore.py IMAGE_ROOT BACKGROUND WINDOW_RECT ICON_SIZE TEXT_SIZE [NAME:X:Y ...]

IMAGE_ROOT is the mounted read-write image, BACKGROUND the background PNG on
the build host, WINDOW_RECT is "x,y,width,height" and each NAME:X:Y places an
item in the window. Finder is never involved, so packaging stays scriptable.
"""
import os
import shutil
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "vendor"))

from ds_store import DSStore  # noqa: E402
from mac_alias import Alias, Bookmark  # noqa: E402


def main() -> None:
    if len(sys.argv) < 6:
        raise SystemExit(__doc__)
    image_root = sys.argv[1]
    background = sys.argv[2]
    window_rect = [int(value) for value in sys.argv[3].split(",")]
    icon_size = float(sys.argv[4])
    text_size = float(sys.argv[5])
    locations = []
    for spec in sys.argv[6:]:
        name, x, y = spec.rsplit(":", 2)
        locations.append((name, (int(x), int(y))))
    if len(window_rect) != 4:
        raise SystemExit("WINDOW_RECT must be x,y,width,height")

    x, y, width, height = window_rect
    bounds_string = "{{{%d, %d}, {%d, %d}}}" % (x, y, width, height)

    background_in_image = os.path.join(image_root, ".background" + os.path.splitext(background)[1])
    shutil.copyfile(background, background_in_image)
    alias = Alias.for_file(background_in_image)
    bookmark = Bookmark.for_file(background_in_image)

    bwsp = {
        "ShowStatusBar": False,
        "WindowBounds": bounds_string,
        "ContainerShowSidebar": False,
        "PreviewPaneVisibility": False,
        "SidebarWidth": 0,
        "ShowTabView": False,
        "ShowToolbar": False,
        "ShowPathbar": False,
        "ShowSidebar": False,
    }
    icvp = {
        "viewOptionsVersion": 1,
        "backgroundType": 2,
        "backgroundColorRed": 1.0,
        "backgroundColorGreen": 1.0,
        "backgroundColorBlue": 1.0,
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "gridSpacing": 100.0,
        "arrangeBy": "none",
        "showIconPreview": True,
        "showItemInfo": False,
        "labelOnBottom": True,
        "textSize": text_size,
        "iconSize": icon_size,
        "scrollPositionX": 0.0,
        "scrollPositionY": 0.0,
        "backgroundImageAlias": alias.to_bytes(),
    }

    store_path = os.path.join(image_root, ".DS_Store")
    with DSStore.open(store_path, "w+") as store:
        store["."]["vSrn"] = ("long", 1)
        store["."]["bwsp"] = bwsp
        store["."]["icvp"] = icvp
        store["."]["pBBk"] = bookmark
        for name, point in locations:
            store[name]["Iloc"] = point
    print("wrote %s" % store_path)


if __name__ == "__main__":
    main()
