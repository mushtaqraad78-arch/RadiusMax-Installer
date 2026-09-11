# RadiusMax MikroTik Installer

This repository distributes the reviewed RadiusMax Phase 7F.1 MikroTik installer only. It contains no RadiusMax application source code, database, customer data, or deployment credentials.

## Immutable release

- Installer release: `v0.7.5-installer1`
- Installer SHA-256: `1B1FD0ED257EA063CCFA7A870AB8C8E49651EB89BB1AE2339F195B853C3DC4FA`
- Agent image: `ghcr.io/mushtaqraad78-arch/radiusmax-agent:v0.7.5@sha256:b8ad981e42d17dbdc9c4e71b91a7d00bddecff1687bd076bd5d67cf02141557d`

## Install

Run on a supported RouterOS device only after reviewing the installer and confirming the Container prerequisites:

```routeros
/tool fetch url="https://raw.githubusercontent.com/mushtaqraad78-arch/RadiusMax-Installer/v0.7.5-installer1/radiusmax-agent-install.rsc" dst-path="radiusmax-agent-install.rsc" check-certificate=yes; /import file-name="radiusmax-agent-install.rsc" verbose=yes
```

The installer requires RouterOS 7.23 or newer, a matching Container package, enabled container device-mode, supported `arm`, `arm64`, or `x86_64` architecture, configured DNS, and sufficient storage. It performs a read-only preflight before adding its dedicated RadiusMax network, API account, persistent state mount, and Agent container.

The Agent uses automatic enrollment and appears as Pending until approved by the RadiusMax Owner. The installer does not embed an Agent token, Owner key, license secret, Central secret, NAS secret, customer credential, or MikroTik password.

Review `radiusmax-agent-install.rsc` before importing it. Preserve its `/var/lib/radiusmax` enrollment state across reinstall and upgrade operations.

## Security notice

The configured Central WebSocket endpoint uses plaintext `ws://`, so enrollment traffic is not protected from an on-path network observer. Use the installer only in an approved controlled environment until Central supports TLS/WSS.

RouterOS containers increase the device attack surface. Use current RouterOS security updates, restrict administrative access, and do not expose the Agent container publicly.
