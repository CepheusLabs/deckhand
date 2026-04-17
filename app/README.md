# Deckhand desktop app

The thin Flutter shell that wires together the `deckhand_*` packages.

## Running in development

```powershell
cd D:\git\3dprinting\deckhand\app
D:\git\flutter\bin\flutter.bat pub get
D:\git\flutter\bin\flutter.bat run -d windows
```

(Linux/macOS: `-d linux` / `-d macos` respectively.)

## Release build

Handled by CI — see `.github/workflows/release.yml`.
