"""dmgbuild settings for the .dmg users download.

`hdiutil create -srcfolder` produces a working disk image, but it carries no window
settings, so Finder opens it as a plain list of two names and the drag is not obvious.
The layout below lives in the image's .DS_Store, which dmgbuild writes directly rather
than by scripting Finder, so this works with no Automation grant and no window on screen.

Coordinates are icon centres and must agree with Scripts/dmg-background.py, which draws
the arrow into the gap between them. Change one and re-run the other.

    uv run --with dmgbuild dmgbuild -s Scripts/dmg.py -D app=<path> "AirStats" out.dmg
"""

import os.path

# dmgbuild exec()s this file, so there is no __file__ to locate the repo from. The
# caller passes the checkout root in; release.sh always has it.
application = defines["app"]
appname = os.path.basename(application)
root = defines.get("root", os.getcwd())

# LZMA rather than zlib: the universal app's image is 2.4 MB instead of 3.7.
# Every macOS since 10.15 mounts it, and the app needs 14.
format = "ULMO"
compression_level = 9
size = None

files = [application]
symlinks = {"Applications": "/Applications"}

background = os.path.join(root, "Resources", "dmg-background.tiff")
icon_locations = {appname: (165, 205), "Applications": (475, 205)}

window_rect = ((140, 140), (640, 400))
default_view = "icon-view"
icon_size = 128
text_size = 13
arrange_by = None
grid_offset = (0, 0)
label_pos = "bottom"

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
