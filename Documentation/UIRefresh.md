# Interface verification

DevStack uses native SwiftUI Liquid Glass panels, interactive glass controls, a glass sidebar, and an AppKit behind-window desktop backdrop. The title bar follows the same surface. Appearance follows System, Light, or Dark through native window appearance; colors use a dynamic teal accent matching the solid icon. The menu-bar symbol uses the icon's three-layer stack and terminal glyph. Window content is capped at 1400 points, with a 1040-point page column.

The dashboard has four service controls: Web Server, PHP, Database, and Mail. Apache/Nginx and PHP versions are selected with native menus. Individual Start/Stop, Restart and Logs actions operate on real services. PHP extensions share one selected-runtime panel. Each site retains its own PHP selection.

Verified through native accessibility and screenshots on macOS 27.0.1: app launch, stack startup, Apache/Nginx switching, Mailpit/PHP individual controls, PHP selection, live HTTPS site creation/removal, navigation, validation, and theme handling. See HANDOVER.md for runtime evidence and limitations.

The packaged app resolves resources from Contents/Resources and never falls back to SwiftPM files on Desktop. Runtime configuration and MySQL client resources also use installed paths. The successful installed-app startup did not display a Desktop permission prompt.

An ad-hoc build reports unavailable privileged integration honestly; registration does not imply that the helper authenticated. Browser CA trust remains a separate macOS authorization action.
