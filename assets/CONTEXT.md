# Assets Context

## Purpose

Central storage for static visual and audio media, icons, illustrations, and brand resources.

## Architecture

Asset collections may be separated into directories such as `images/`, `logos/`, and `audio/` as the project grows.

## Current State

- `icons/AppIcon.icon` is the production Apple Icon Composer document referenced
  by the FreeMount application target.
- `icons/AppIcon-iOS-Default-1024@1x.png` is the exported 1024 x 1024 master icon.
- `icons/icon-composer/` contains the editable 1024 x 1024 vector layers for
  rebuilding the approved FreeMount icon in Apple Icon Composer.
- `icons/FinderSidebarIcon.svg` is the editable monochrome source for the
  outline-cloud `FM` symbol shown beside File Provider domains in Finder.
- `icons/AppLogo-120x120.png` is the 120x120 PNG derivative for cloud OAuth
  consent screens (Google Cloud / OAuth 2.0).
- The small monochrome menu-bar derivative lives in
  `App/Resources/Assets.xcassets/MenuBarIcon.imageset` because it is an app UI
  asset rather than distribution artwork.
- `provider-logos/` stores original provider artwork SVG files directly.
  Runtime copies exist under `Assets.xcassets/ProviderIcons/` only for
  implemented providers.

## Dependencies

- Product UI and documentation may reference files from this directory.

## Known Issues

- None in the base template.
