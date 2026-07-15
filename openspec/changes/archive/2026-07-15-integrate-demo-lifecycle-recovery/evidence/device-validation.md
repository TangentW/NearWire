# Device Validation

Device discovery found the booted iPhone 17 Pro simulator and the physical iPhone 17 Pro named `Tangent 🤪` (`00008150-001074510E88401C`). Simulator unit, launch, and build validation passed.

The physical-device smoke could not be started because Xcode could not prepare the Wi-Fi-connected phone while it was locked. The exact terminal condition was:

`Tangent 🤪 may need to be unlocked to recover from previously reported preparation errors`

No signing setting was changed, and the device limitation did not block deterministic lifecycle, fresh-route, or Viewer replacement regressions. A physical background/foreground smoke remains useful after the phone is unlocked, but it is not represented as completed evidence here.
