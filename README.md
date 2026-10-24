# SortMyMac

A native macOS notch companion that groups related files and lets you drop the resulting folders into Finder.

Requires macOS 14+ and Xcode with Swift 6.

```sh
./scripts/build.sh
open build/SortMyMac.app
swift test
```

The app uses your Cloudflare account with Clef. Credentials belong in Settings; the API token is stored in macOS Keychain. Source files remain in place until you drop the organized folders into a destination.

See [UI practices](docs/UI-Practices.md) for the interface specification.
