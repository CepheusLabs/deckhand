# Deckhand desktop app

The thin Flutter shell that wires together the `deckhand_*` packages.

## Bringing up the native platform shells

This directory doesn't yet contain `windows/`, `macos/`, or `linux/`
platform folders. Generate them once with:

```powershell
cd D:\git\3dprinting\deckhand\app
D:\git\flutter\bin\flutter.bat create --platforms=windows,macos,linux --project-name=deckhand .
```

That pulls in the standard Flutter desktop embedders. Commit the new
directories as their own commit so the history stays focused.

## Running in development

```powershell
D:\git\flutter\bin\flutter.bat pub get
D:\git\flutter\bin\flutter.bat run -d windows
```

(Linux/macOS: `-d linux` / `-d macos` respectively.)

## Release build

Handled by CI — see `.github/workflows/release.yml`.
