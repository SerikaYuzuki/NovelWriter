# Snapshot Sync v2 LAN staging trust

This procedure is for the isolated staging deployment only:

```text
https://192.168.11.5:8443
project: fuminiwa-sync-v2
edge: fuminiwa-sync-v2-edge
```

The edge uses Caddy's internal CA. The CA certificate is public material, but
it is not a production trust anchor. Do not copy a private key, weaken
certificate validation, or add `-k` to application requests.

## Export and verify the CA

The export script reads only the public root from the exact v2 edge container.
It also checks the leaf certificate SAN, prints SHA-256 fingerprints, and
performs an HTTPS auth-capabilities read-back with the exported CA:

```sh
# The script requires a sudo timestamp that is valid for non-interactive SSH.
# It never reads or stores a password.
Scripts/export-sync-v2-staging-ca.sh \
  --output "$HOME/Downloads/fuminiwa-sync-v2-root.crt"
```

Record the printed root fingerprint before installing trust. A successful
run must report all of the following:

```text
leaf SAN: IP Address:192.168.11.5
HTTPS auth capabilities: HTTP 200 (v2 namespaces verified)
```

If the host's sudo policy does not retain a timestamp across SSH sessions,
run the export from an operator shell that has the approved v2-only sudo
policy, or have an administrator provide the public CA file. Never grant the
script access to the old `fuminiwa-sync-dev-*` containers or volumes.

## macOS trust (explicit, manual opt-in)

Inspect the fingerprint printed by the export script and compare it through a
separate trusted channel. Only after that comparison, install the public CA
into the login keychain:

```sh
security add-trusted-cert \
  -d -r trustRoot \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  "$HOME/Downloads/fuminiwa-sync-v2-root.crt"
```

This command is intentionally not run by the export script. Remove the
staging trust after testing with Keychain Access or:

```sh
security delete-certificate \
  -c "FUMINIWA" \
  "$HOME/Library/Keychains/login.keychain-db"
```

The exact certificate and fingerprint must be checked before removal if more
than one certificate has the same display name.

## iPhone / iPad trust (explicit, manual opt-in)

1. Transfer the verified `.crt` file to the device using AirDrop or Files.
2. Open it and approve the configuration-profile installation in Settings.
3. In **Settings > General > About > Certificate Trust Settings**, enable full
   trust for the FUMINIWA Snapshot Sync v2 staging root.
4. Confirm the displayed certificate fingerprint matches the export output.

This is a device-wide staging trust. Disable it and remove the profile after
the physical test. The app must continue to use normal URLSession certificate
validation; it must not ship a pinned staging root or an unverified transport.

## Device read-back

After trust is installed, run the app against the v2 URL and verify the
capabilities request succeeds without a certificate warning. The server's
`8092` listener must remain private to the Compose network. A healthy Docker
container alone is not sufficient evidence: the device-facing TLS chain and
the authenticated capabilities response must both be read back.
