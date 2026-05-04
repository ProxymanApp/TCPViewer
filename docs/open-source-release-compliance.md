# Open Source Release Compliance

This is an engineering checklist for publishing TCP Viewer with Wireshark
libraries. It is not a substitute for legal review.

## License Position

- TCP Viewer is licensed as GPL-2.0-or-later.
- The app links and bundles Wireshark `libwireshark`, `libwiretap`, and
  `libwsutil`.
- Wireshark distributes these libraries under GPL terms, not LGPL terms, so TCP
  Viewer source and binary releases must preserve GPL rights for recipients.

## Source Release Checklist

- Publish the matching TCP Viewer source for every binary release.
- Include `.gitmodules`, `scripts/bootstrap-wireshark.sh`,
  `scripts/bootstrap-pcapplusplus.sh`, and the exact pinned submodule commits.
- Include `LICENSE`, `COPYING`, `SOURCE_CODE_OFFER.md`, and
  `THIRD_PARTY_NOTICES.md`.
- Do not publish generated-only artifacts as the only source release. Recipients
  need the preferred source form and the scripts used to build the executable.

## Binary Release Checklist

- Bundle `Contents/Resources/OpenSourceLicenses` from the Xcode build output.
- Include either the complete corresponding source code or the written source
  offer in `SOURCE_CODE_OFFER.md`.
- Do not ship an EULA, updater rule, or distribution channel term that prevents
  recipients from copying, modifying, or redistributing TCP Viewer under the GPL.
- Inspect `Contents/Resources/OpenSourceLicenses/RUNTIME_LIBRARIES.txt` and add
  notices for every non-system dynamic library included in the app bundle.

## Verification

After creating a release build, verify the notice bundle exists:

```sh
find "TCP Viewer.app/Contents/Resources/OpenSourceLicenses" -maxdepth 1 -type f -print
```

The folder should include TCP Viewer's license, the GPL text, the source offer,
third-party notices, and license files for Wireshark, PcapPlusPlus, and HexFiend.
