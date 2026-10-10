# MATE Fingerprint Login

A traditional Vala and GTK 3 fingerprint utility for the MATE desktop. It talks directly to fprintd over D-Bus.

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