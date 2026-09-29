# Interface refresh verification

Native SwiftUI sidebar, Liquid Glass controls, blue accents, restrained solid content panels, simple app icon and matching template menu bar symbol. App content width is capped at 1400 points with a 1040-point page content column. Site search, inline domain validation, disabled unavailable runtimes, destructive action confirmations, log filtering/pause/copy, diagnostic progress and ZIP support export are wired to actual operations.

Verified on macOS 27.0.1 using the app accessibility tree and screenshots: all eight navigation routes, new-site form, invalid host validation, log filter/pause, theme selection, missing-runtime controls, and real setup failure presentation. Core checks passed after the refresh.

The packaged resource accessor now resolves Contents/Resources. SwiftPM's generated accessor had fallen back to build files on Desktop, blocking first launch behind TCC access. Packaged builds fail explicitly if resources are missing instead of reading the build directory.

The local preview is ad-hoc signed. ServiceManagement registration returns Operation not permitted on this build. The app surfaces this failure and handles requiresApproval by opening Login Items & Extensions. Developer ID signing and notarization remain necessary for the production privileged daemon.
