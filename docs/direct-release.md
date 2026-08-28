# Signed Direct Release Setup

The signed build workflow uses the paid Apple Developer Program's Developer ID and notarization services:

- Every push to `main` uploads a 14-day Actions artifact and creates a public GitHub Release.
- A manual run uploads an Actions artifact without changing a public release.
- Pull requests never receive signing or notarization secrets.

The workflow uses the Xcode `MARKETING_VERSION` as the user-facing version and GitHub's monotonically increasing workflow `run_number` as `CFBundleVersion`. For example, marketing version `1.0` and run number `42` produce app version `1.0 (42)` and release tag `v1.0-build.42`. The generated tag is an implementation detail; maintainers do not create or push release tags manually.

Releases are public only while the GitHub repository itself is public.

## Public project metadata

The Apple Team ID and product bundle identifier checked into the Xcode project are identifiers, not credentials. They do not grant access to the developer account and cannot sign software without the corresponding private key.

Contributors outside the maintained team can select their own Team and use a unique bundle identifier in their local Xcode settings.

## 1. Create the Developer ID certificate

1. Sign in to [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/certificates/list) as the Apple Developer Program Account Holder.
2. Click the add button, select **Developer ID**, then **Developer ID Application**.
3. If requested, create a certificate signing request in Keychain Access with **Certificate Assistant > Request a Certificate From a Certificate Authority**, then upload it.
4. Download the `.cer` file and open it to install it in your login keychain.
5. In Keychain Access, open **My Certificates**, find `Developer ID Application: ...`, and confirm that it expands to show a private key.
6. Export that identity and its private key as a password-protected `.p12` file. Record the export password for `DEVELOPER_ID_P12_PASSWORD`.

Do not export an `Apple Development`, `Apple Distribution`, or `Mac App Distribution` identity. They cannot replace `Developer ID Application` for direct distribution.

## 2. Create the notarization API key

1. Open [App Store Connect > Users and Access > Integrations](https://appstoreconnect.apple.com/access/integrations/api).
2. Under **Team Keys**, generate an API key with a role permitted to submit notarization requests.
3. Download the `AuthKey_<KEY_ID>.p8` file immediately. Apple allows this file to be downloaded only once.
4. Record the displayed **Key ID** and **Issuer ID**.

The workflow uses a team API key, so all three values are required: the `.p8` content, Key ID, and Issuer ID.

## 3. Find the account identifiers

- Find the 10-character **Team ID** under [Apple Developer Account > Membership details](https://developer.apple.com/account#MembershipDetailsCard).
- Choose a unique bundle identifier, such as `com.yourcompany.privateai`. Register the same explicit App ID under [Identifiers](https://developer.apple.com/account/resources/identifiers/list) before enabling capabilities that require a Developer ID provisioning profile.

## 4. Encode the private files

Run each command separately on the Mac that holds the files. Each command copies one single-line value to the clipboard:

```bash
base64 -i /path/to/DeveloperID.p12 | tr -d '\n' | pbcopy
base64 -i /path/to/AuthKey_KEYID.p8 | tr -d '\n' | pbcopy
openssl rand -base64 32 | tr -d '\n' | pbcopy
```

The third command creates an independent temporary-keychain password. It is not an Apple account password and not the `.p12` export password.

## 5. Configure the production environment

In the GitHub repository, open **Settings > Environments > New environment**, and create an environment named exactly `production`.

Add these values under **Environment secrets**:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Single-line base64 of the exported `.p12` |
| `DEVELOPER_ID_P12_PASSWORD` | Password chosen while exporting the `.p12` |
| `KEYCHAIN_PASSWORD` | Random value generated for the temporary CI keychain |
| `NOTARY_KEY_P8_BASE64` | Single-line base64 of the App Store Connect `.p8` key |

Add these values under **Environment variables**:

| Variable | Value |
| --- | --- |
| `APPLE_TEAM_ID` | 10-character Apple Developer Team ID |
| `NOTARY_KEY_ID` | App Store Connect API Key ID |
| `NOTARY_ISSUER_ID` | App Store Connect API Issuer ID |
| `PRODUCT_BUNDLE_IDENTIFIER` | Optional; defaults to `com.jacobjiangwei.privateai` |
| `PRIVATEAI_PRIVACY_POLICY_URL` | Optional public privacy-policy URL |

Environment variables are plaintext configuration. Never put the `.p12`, `.p8`, either password, raw private key, or their base64 encodings in Variables.

For fully automatic `main` builds, do not add a required reviewer. Restrict the environment's deployment branch to `main`, and keep branch protection enabled on `main`.

Never commit the unencoded or base64-encoded certificate, private key, password, provisioning profile, API key, temporary keychain, or environment file. Base64 is transport encoding, not encryption.

## Certificate prerequisites

The PKCS#12 export must contain a valid `Developer ID Application` certificate and its private key. Apple Development and Mac App Distribution certificates are not valid substitutes for direct distribution.

## 6. Validate and publish

Run **Signed macOS build** manually once. A successful run produces a signed and notarized Actions artifact without changing the public Releases page.

After validation, every push to `main` creates a public release such as `v1.0-build.42`. GitHub's `/releases/latest` URL resolves to the newest successful build. Change `MARKETING_VERSION` in the Xcode project only when the user-facing version should advance; the CI build number requires no source-code commit.

The workflow creates `PrivateAI.dmg` and `PrivateAI.dmg.sha256`, submits the signed DMG to Apple's notary service, staples the ticket, validates it with Gatekeeper, and then updates the appropriate GitHub Release. A failed signing, notarization, stapling, Gatekeeper, or checksum step prevents publication.