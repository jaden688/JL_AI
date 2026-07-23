const UI_HTML = read(joinpath(@__DIR__, "ui.html"), String)

# PWA install assets — served so Chrome/Edge can install the console as a
# desktop app. These files are OPTIONAL and untracked (they can get cleaned
# away). Read them defensively so a missing asset degrades the install
# feature instead of crashing engine boot.
_ui_safe_bytes(path) = isfile(path) ? read(path) : UInt8[]
_ui_safe_str(path)   = isfile(path) ? read(path, String) : ""

const UI_MANIFEST = _ui_safe_str(joinpath(@__DIR__, "manifest.webmanifest"))
const UI_ICON_192 = _ui_safe_bytes(joinpath(@__DIR__, "icon-192.png"))
const UI_ICON_512 = _ui_safe_bytes(joinpath(@__DIR__, "icon-512.png"))
