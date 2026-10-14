# SwiftMath (vendored)

Copy of [SwiftMath](https://github.com/mgriebling/SwiftMath) 1.7.3 (commit `fa8244e`), MIT license (see `LICENSE`).

Local changes for LLM Designer:

- `MathBundle/ResourceBundle.swift` (new): finds the resource bundle in `Contents/Resources` of the app.
  `MathFont.swift` and `MTFont.swift` use it instead of `Bundle.module`, which only checks the
  .app root, a place codesign forbids.
- Only the Latin Modern math font is kept in `mathFonts.bundle` (the app does not use the others).
- Test target and docs removed.
