const UI_HTML = read(joinpath(@__DIR__, "ui.html"), String)

# PWA install assets — served so Chrome/Edge can install the console as a
# desktop app (manifest + icons are the installability requirements).
const UI_MANIFEST = read(joinpath(@__DIR__, "manifest.webmanifest"), String)
const UI_ICON_192 = read(joinpath(@__DIR__, "icon-192.png"))
const UI_ICON_512 = read(joinpath(@__DIR__, "icon-512.png"))
