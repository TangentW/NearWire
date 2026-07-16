# Visual validation

The offscreen Viewer render suite exported workspace screenshots from:

```text
/tmp/nearwire-tail-split-class/Logs/Test/Test-NearWireViewer-2026.07.17_01-10-38-+0800.xcresult
```

Inspected:

- light and dark standard workspace renders;
- minimum, standard, and wide frame measurements from the render test;
- the populated Timeline row presentation attachment.

Observed:

- Timeline occupies approximately 70% and Inspector approximately 30% of the initial horizontal
  Event workspace;
- the native divider remains visually present;
- neither panel is clipped at maintained sizes;
- no synthetic blank Timeline item is present after the final Event;
- light and dark appearances remain consistent.
