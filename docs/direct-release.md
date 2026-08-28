# Direct Release Setup

The release workflow runs only when a maintainer pushes a tag matching `v*`. Normal pushes and pull requests do not receive signing or notarization secrets.

## Public project metadata

The Apple Team ID and product bundle identifier checked into the Xcode project are identifiers, not credentials. They do not grant access to the developer account and cannot sign software without the corresponding private key.

Contributors outside the maintained team can select their own Team and use a unique bundle identifier in their local Xcode settings.

## Required GitHub Actions secrets

Configure these encrypted repository secrets before publishing a tag:

- `APPLE_TEAM_ID`: the Developer ID certificate's Apple team identifier.
- `DEVELOPER_ID_P12_BASE64`: a base64 encoding of a Developer ID Application certificate and its private key exported as PKCS#12.
- `DEVELOPER_ID_P12_PASSWORD`: the export password for that PKCS#12 file.
- `KEYCHAIN_PASSWORD`: a random password used only for the temporary CI keychain.
- `NOTARY_KEY_P8_BASE64`: a base64 encoding of an App Store Connect API private key authorized for notarization.
- `NOTARY_KEY_ID`: the API key identifier.
- `NOTARY_ISSUER_ID`: the App Store Connect team issuer UUID.

Optionally set the repository variable `PRODUCT_BUNDLE_IDENTIFIER`. If omitted, the maintained bundle identifier from the project is used.

Never commit the unencoded or base64-encoded certificate, private key, password, provisioning profile, API key, temporary keychain, or environment file. Base64 is transport encoding, not encryption.

## Certificate prerequisites

The PKCS#12 export must contain a valid `Developer ID Application` certificate and its private key. Apple Development and Mac App Distribution certificates are not valid substitutes for direct distribution.

## Publishing

Create an annotated release tag only after updating the app version and validating the intended commit:

```bash
git tag -a v1.0 -m "PrivateAI 1.0"
git push origin v1.0
```

The workflow creates `PrivateAI.dmg` and `PrivateAI.dmg.sha256`, submits the signed DMG to Apple's notary service, staples the ticket, validates the result, and creates the GitHub Release. A failed signing, notarization, stapling, Gatekeeper, or checksum step prevents publication.