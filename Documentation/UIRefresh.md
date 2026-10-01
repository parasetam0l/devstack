# Interface verification

DevStack is a compact macOS utility. It opens at 920 × 620 points, supports 820 × 540, and caps ordinary windows at 1100 points wide. Old oversized saved frames are reduced on launch; native Zoom respects the cap. Full-screen participation is disabled. The sidebar uses a single compact toggle.

The native SwiftUI Liquid Glass panels and interactive controls sample an AppKit behind-window desktop backdrop. Spacing is 8–10 points, panel padding is 12 points, and controls use the small size. Neutral surfaces, icons and status badges replace the teal accent and tinted gradient. Primary buttons share one compact interactive glass style across the toolbar, pages and sheets. Warning/error colors remain semantic. Ellipsis menus hide the redundant chevron.

Dashboard services are aligned rows with selectors and independent controls. MySQL and PostgreSQL are separate rows with No MySQL / No PostgreSQL options. Start Stack uses the selected engines. Apache/Nginx share one selector; each site retains its own PHP version.

Sites and PHP extensions use compact lists. The site editor uses a compact grid; advanced PHP overrides expand on demand. Database credentials use two columns, with socket details collapsed. Mail has real individual service controls. Logs use a compact control strip and readable monospaced output. Doctor defaults to warnings/errors and exposes left-aligned evidence and recovery actions through expandable rows. Intentionally omitted, unselected legacy runtimes are informational. Settings uses one compact panel.

SSL shows one row per certificate with expiry, validity, Renew and actions. Clicking its hostname opens metadata in a sheet; CA details use the same sheet. All six existing certificates fit in the default window. Issue, export, reveal, protected deletion and live renewal retain their real backend behavior.

The app icon stays simple and solid. Its menu-bar template uses separate outlined stack layers and a small terminal mark, so the silhouette does not merge into a filled blob at 19 points. macOS supplies the appropriate monochrome appearance.

Inspected through native accessibility and screenshots on macOS 27.0.1: all nine pages, compact toolbar, site editor with expanded settings, six certificate rows, database selections, and light/system appearance.

Installed resource and runtime paths resolve within the app and Application Support. Successful installed-app startup did not request Desktop access. The ad-hoc build reports unavailable privileged integration honestly; CA trust requires native macOS authorization.
