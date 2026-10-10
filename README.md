# MATE Fingerprint Login

A traditional Vala and GTK 3 fingerprint utility for the MATE desktop. It talks directly to fprintd over D-Bus and does not use XApps or client-side decorations.

## Requirements

- Vala 0.56 or newer
- GTK 3 development files
- fprintd and a libfprint-supported reader
- Meson 0.59 or newer

## Build and run

```sh
meson setup build
meson compile -C build
./build/mate-fprint
```

To preview every screen without fingerprint hardware:

```sh
MATE_FPRINT_DEMO=1 ./build/mate-fprint
```

Install with `meson install -C build`. The application can enable or disable its PAM profile through PolicyKit and `pam-auth-update`.

## Design

The finger grid and focused scan workflow follow the interaction model used by Linux Mint's Fingwit, while the application uses only GTK 3 and standard server-side window decorations for a native MATE appearance.

## License

GPL-3.0-or-later
