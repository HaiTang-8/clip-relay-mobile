# clip-relay Protocol v1 — Encryption Format

This document is the normative description of the end-to-end encryption format used by pickup-code relay transfers between PC (Electron) and mobile (Flutter) devices of the same subscription. The relay server only ever sees ciphertext, ciphertext sizes, frame/block counts, device IDs and timestamps.

Implementations:

| Language | Path | Notes |
|---|---|---|
| Node (reference) | `src/relay/crypto.cjs` | CommonJS, Node built-in `crypto` only, Node ≥ 18.18 (Electron 28) |
| Dart | `packages/relay_crypto` in [clip-relay-mobile](https://github.com/HaiTang-8/clip-relay-mobile) | `package:cryptography`, streaming via `Stream<List<int>>` |

Byte compatibility is locked by `test-vectors/v1.json` (see [§12](#12-test-vectors)).

## 1. Conventions

* **Binary in JSON / URLs**: base64url (RFC 4648 §5) **without padding**. Decoders reject characters outside `[A-Za-z0-9_-]`, lengths with `len % 4 == 1`, padding, and non-canonical encodings (non-zero unused trailing bits), so every byte string has exactly one accepted encoding.
* **`‖`**: byte concatenation. Strings inside byte concatenations are UTF-8.
* **HKDF**: HKDF-SHA256 (RFC 5869), output length 32 bytes. Written `HKDF(ikm, salt, info)`.
* **AES-GCM**: AES-256-GCM, 12-byte nonce, 16-byte tag. Output is always `ciphertext ‖ tag`.
* **Canonical JSON** (`canonicalJson`): used for everything that is signed or must be byte-identical across languages.
  * Object keys sorted by UTF-16 code units (JS `Array.prototype.sort` / Dart `String.compareTo`), no whitespace.
  * Strings escaped exactly like ECMAScript `JSON.stringify` (well-formed): `\"` `\\` `\b` `\f` `\n` `\r` `\t`, other code units `< 0x20` as `\u00xx` (lowercase hex), lone surrogates as `\udxxx`; everything else (including non-ASCII, U+2028/U+2029, U+007F) emitted raw.
  * Numbers must be integers with `|n| ≤ 2^53 − 1`; fractional numbers are rejected. `null`, `true`, `false` as usual. Keys with JS `undefined` values are omitted.
* **Constants**

| Name | Value |
|---|---|
| `FRAME_SIZE` | 65 536 (64 KiB) plaintext bytes per frame |
| `TAG_BYTES` | 16 |
| `FRAME_CIPHERTEXT_SIZE` | 65 552 |
| `BLOCK_FRAMES` | 128 |
| `BLOCK_SIZE` | 8 390 656 (= 128 × 65 552, ≈ 8 MiB) |
| `INLINE_MAX_BYTES` | 65 536 (total ciphertext) |
| `REQUEST_MAX_SKEW_MS` | 300 000 (±5 min) |

* **Domain-separation labels** (ASCII, no terminator)

| Purpose | Label |
|---|---|
| Fingerprint | `clip-relay/v1/fpr` |
| Key wrap | `clip-relay/v1/wrap` |
| Payload key | `clip-relay/v1/payload` |
| Manifest key | `clip-relay/v1/meta` |
| Bind proof | `clip-relay/v1/bind` |

## 2. Device keys and fingerprint

Each device generates, locally and once:

* an **X25519** key pair (key agreement), and
* an **Ed25519** key pair (signatures).

Private keys are the 32-byte RFC 7748 / RFC 8032 seeds and never leave the device's secure storage (Electron `safeStorage`, iOS Keychain, Android Keystore). Public keys are the raw 32-byte encodings, base64url in JSON (43 chars).

```
fingerprint = SHA-256("clip-relay/v1/fpr" ‖ x25519Pub[32] ‖ ed25519Pub[32])[0..16]
```

* Machine form: 32 lowercase hex chars (used in the QR URI and APIs).
* Display form: 8 groups of 4 hex chars separated by spaces.

Example (`devices.pc` in the vectors):

```
x25519Pub  = 6U8fS8i3xeYl4VLDixlgSHOYncl5d_ZFcmdCx_KKp2g
ed25519Pub = 6mgFNCmylbb4evFfeuYJhgbS1BVOg1s77BUzHueIGkk
fingerprint = d98a65a639bcac63230df3cd036e9f5f
display     = d98a 65a6 39bc ac63 230d f3cd 036e 9f5f
```

## 3. Item overview

Sender:

1. `itemId` — assigned by the server when the upload session is created (opaque string, non-empty). It is bound into every AEAD as AAD, so the sender must know it before encrypting.
2. `fileKey` ← 32 random bytes; `salt` ← 16 random bytes (both per item).
3. For every **active device with a registered public key** in the subscription (including the sender itself): one stanza ([§4](#4-key-wrapping-stanza)).
4. Manifest → `encManifest` ([§7](#7-manifest)).
5. Payload → STREAM frames ([§5](#5-payload-stream)) → inline ciphertext ([§6.2](#62-inline-ciphertext)) or 8 MiB storage blocks ([§6.1](#61-storage-blocks)).
6. Header ([§8](#8-header-and-signature)), signed with the sender's Ed25519 key.

Receiver:

1. Fetch the sender's Ed25519 public key from the device directory (pinned / verified per [§9](#9-bind-proof-and-qr-uri)), verify the header signature. **Never unwrap before verifying.**
2. Find the stanza whose `deviceId` is its own, unwrap `fileKey`. No stanza → "this device cannot decrypt, ask the sender to resend".
3. Decrypt `encManifest`, then the payload, and check each entry's `sha256`.

## 4. Key wrapping (stanza)

```
ephPriv, ephPub ← fresh X25519 key pair (one per stanza)
shared   = X25519(ephPriv, recipientPub)            // reject if all-zero (low-order point)
wrapKey  = HKDF(ikm = shared, salt = ephPub ‖ recipientPub, info = "clip-relay/v1/wrap")
wrapped  = AES-256-GCM(key = wrapKey, nonce = 0x00 × 12, plaintext = fileKey, aad = empty)
stanza   = { deviceId, ephPub: b64u(ephPub), wrappedKey: b64u(wrapped) }
```

The zero nonce is safe because `wrapKey` is derived from a fresh ephemeral key and used exactly once.

Unwrap: `shared = X25519(recipientPriv, ephPub)`, `recipientPub` is derived from `recipientPriv`, then the same HKDF and AES-GCM open.

Byte layout:

```
ephPub      : 32 bytes
wrappedKey  : 48 bytes = encrypted fileKey (32) ‖ tag (16)
```

Example stanza (`wrap[0]`): `{"deviceId":"dev-phone","ephPub":"l6bssinVzfWC02x-SQ0LzEJF0vsnbIC6KqxMTj5H5Bk","wrappedKey":"QWir2MOrlpZlAqcrMp63plAaDt54kqlQ1G2QS1bf-ZypPZQMRlqGFPzMaPhamYBL"}`.

## 5. Payload (STREAM)

age-style STREAM construction over AES-256-GCM.

```
payloadKey = HKDF(ikm = fileKey, salt = salt, info = "clip-relay/v1/payload")
aad        = UTF-8(itemId)
```

The plaintext stream (for multiple files: the files concatenated in manifest order, see `offset`) is split into frames of `FRAME_SIZE` bytes. Frame `i` (0-based) is

```
nonce_i = BE88(i) ‖ lastFlag          // 11-byte big-endian counter, 1-byte flag
          lastFlag = 0x01 for the final frame, 0x00 otherwise
frame_i = AES-256-GCM(payloadKey, nonce_i, plaintextFrame_i, aad)   // len + 16 bytes
```

Nonce layout:

```
byte:  0  1  2  3  4  5  6  7  8  9  10 | 11
       ---------- counter (BE) ---------  | flag
frame 0 of 3 : 00 00 00 00 00 00 00 00 00 00 00 | 00
frame 2 of 3 : 00 00 00 00 00 00 00 00 00 00 02 | 01
```

Rules:

* All frames except the final one carry exactly `FRAME_SIZE` plaintext bytes.
* The final frame carries `1 … FRAME_SIZE` bytes; it carries 0 bytes **only** if the whole payload is empty (then the payload is exactly one 16-byte frame).
* A payload whose size is an exact multiple of `FRAME_SIZE` ends with a full final frame (no trailing empty frame).
* Ciphertext size: `ciphertextSize(n) = n + 16 × max(1, ceil(n / 65536))`.

Decoding (stream): buffer input; while more than `FRAME_CIPHERTEXT_SIZE` bytes are buffered, open the next `FRAME_CIPHERTEXT_SIZE` bytes as a non-final frame. At end of input the remaining `16 … 65552` bytes are opened as the final frame. Receivers **must** reject:

* any AEAD failure (tampering, wrong key/salt/itemId, reordered frames);
* end of input with fewer than 16 bytes remaining (including an empty stream);
* truncation at a frame boundary (the new last frame was sealed with flag `0x00`);
* extra data after the real final frame (that frame was sealed with flag `0x01` but is opened as non-final);
* an empty final frame when the counter is > 0.

Example (`payload/one-byte`, `itemId = "item-one-byte"`):

```
fileKey    = a661f7d0d6d682d1260b9bc73b962868d6cbb5b589541c75b62e7c703c0865d2
salt       = 32f1050cfd1a62930babc51abc71ae52
plaintext  = 07
nonce_0    = 000000000000000000000001
ciphertext = 1d | 9a768eeae3c9899c2f084622c71f5fb1      (1 byte ‖ 16-byte tag)
```

## 6. Transport of the payload

### 6.1 Storage blocks

The ciphertext (frames concatenated) is split into storage blocks of `BLOCK_SIZE` bytes; the last block may be shorter. Each block is one object in storage. Because `BLOCK_SIZE` is a whole number of ciphertext frames, block `k` starts at frame `128 × k` and can be decrypted on its own:

```
block k: offset = k × 8 390 656, size = min(BLOCK_SIZE, total − offset),
         firstFrame = 128 × k, last = (k == count − 1)
```

Decrypting one block uses the stream decoder starting at counter `firstFrame`; for non-last blocks every frame is non-final and the block must contain exactly `BLOCK_FRAMES` (128) whole frames — a shorter or misaligned non-last block is rejected, so frames dropped from the end of a middle block cannot go unnoticed.

A 100 MiB plaintext → 104 883 200 bytes ciphertext → 13 blocks (12 × 8 390 656 + 4 195 328). Note that ciphertext is slightly larger than plaintext (16 bytes per 64 KiB); size limits enforced by the server are on ciphertext.

### 6.2 Inline ciphertext

If the total ciphertext is `≤ INLINE_MAX_BYTES` (65 536 bytes, i.e. plaintext ≤ 65 520 bytes), the sender may put `b64u(ciphertext)` in the `inlineCiphertext` field of the item instead of uploading storage blocks. The format is identical to §5.

## 7. Manifest

```
metaKey     = HKDF(ikm = fileKey, salt = salt, info = "clip-relay/v1/meta")
nonce       ← 12 random bytes
encManifest = b64u( nonce[12] ‖ AES-256-GCM(metaKey, nonce, UTF-8(canonicalJson(manifest)), aad = UTF-8(itemId)) )
```

Manifest JSON:

```json
{
  "v": 1,
  "kind": "text" | "image" | "files",
  "entries": [
    { "name": "photo.jpg", "mime": "image/jpeg", "size": 123456, "sha256": "<hex>", "offset": 0 }
  ],
  "text": "optional plaintext preview for list rendering",
  "thumbnail": "optional base64 JPEG, ≤ 32 KB",
  "createdAt": "2026-10-13T08:00:00.000Z"
}
```

* `entries[i].offset` / `size` locate entry `i` in the decrypted payload stream; entries are contiguous and in order. `sha256` is lowercase hex of the entry's plaintext.
* `kind = "text"`: the payload is the UTF-8 text, one entry with `name = ""`. `text` is only a preview (recommended ≤ 200 chars); the full text is the payload.
* `thumbnail` is generated and encrypted by the sender (server cannot generate previews).
* Optional fields are omitted, not `null`. Unknown fields must be ignored by readers. `v` other than `1` is rejected.

Layout: `nonce (12) ‖ encrypted canonical JSON (n) ‖ tag (16)`.

## 8. Header and signature

```json
{
  "v": 1,
  "itemId": "…",
  "senderDeviceId": "…",
  "salt": "<b64u 16 bytes>",
  "frameSize": 65536,
  "plaintextSize": 31,
  "recipients": [ { "deviceId": "…", "ephPub": "…", "wrappedKey": "…" } ],
  "encManifest": "<b64u>"
}
```

```
signature = b64u( Ed25519.sign(senderEd25519Priv, UTF-8(canonicalJson(header))) )     // 64 bytes
```

* Verifiers reject headers with `v ≠ 1` or `frameSize ≠ 65536`, then verify the signature against the sender's registered Ed25519 key.
* The signature covers **all** stanzas in order. The server must store the header verbatim and return the complete header (all stanzas) together with `signature`; it must not drop other devices' stanzas, or the signature cannot be verified. (It may additionally index stanzas per device.)
* `plaintextSize` must equal the decrypted payload length; `ciphertextSize(plaintextSize)` must equal the uploaded ciphertext size.

Canonical example (`header[0].canonical`, abbreviated):

```
{"encManifest":"BJU4…","frameSize":65536,"itemId":"item-text","plaintextSize":31,"recipients":[{"deviceId":"dev-pc","ephPub":"kqid…","wrappedKey":"a0Yc…"},{"deviceId":"dev-phone",…}],"salt":"38_-HR29rVZPb0T09m9MrA","senderDeviceId":"dev-pc","v":1}
```

## 9. Bind proof and QR URI

The PC generates `pairingSecret` (32 random bytes). It appears **only** in the QR code and is never sent to the server.

QR URI (parameters in this order, values encoded with ECMAScript `encodeURIComponent` / Dart `Uri.encodeComponent`):

```
cliprelay://bind?v=1&s=<server URL>&t=<bindToken>&d=<pcDeviceId>&f=<pcFingerprintHex>&p=<b64u(pairingSecret)>
```

Example:

```
cliprelay://bind?v=1&s=https%3A%2F%2Frelay.example.com%3A8443%2Fapi&t=bt_q85TUDJ3U92I73KA_ixKoQDikjIh8t4P&d=dev-pc&f=d98a65a639bcac63230df3cd036e9f5f&p=G8l_homwKQSJ2SrZZxQAGQmf_nu3Hpz4C5qWpSuBzRo
```

Parsers reject: other schemes/hosts, `v ≠ 1`, missing `s`/`t`/`d`, `f` not 32 lowercase hex chars, `p` not 32 bytes.

The phone proves its keys to the PC:

```
bindProof = b64u( HMAC-SHA256(key = pairingSecret, "clip-relay/v1/bind" ‖ x25519Pub[32] ‖ ed25519Pub[32]) )
```

* Phone: after binding, compares `f` with `fingerprint()` of the PC keys returned by the server; mismatch ⇒ abort.
* PC: recomputes `bindProof` over the phone keys returned by the server and compares in constant time; mismatch ⇒ mark the phone untrusted.
* License-key binding (no QR): trust on first use; both sides display the fingerprint for manual comparison.

## 10. Device request signing

Every `/relay/*` request is signed with the device's Ed25519 key.

```
signingString = METHOD "\n" PATH "\n" hex(SHA-256(body)) "\n" timestamp "\n" nonce
signature     = b64u( Ed25519.sign(devicePriv, UTF-8(signingString)) )
```

* `METHOD`: HTTP method, 1–16 ASCII letters, upper-cased before signing.
* `PATH`: request target as sent on the wire — path plus query string exactly (`/relay/items?since=…`), starting with `/`, printable ASCII `0x21–0x7e` only (no spaces, newlines or raw non-ASCII; percent-encode). Signers and verifiers reject anything else, which keeps the newline-separated signing string unambiguous.
* `body`: the raw request body bytes; empty body → SHA-256 of the empty string (`e3b0c442…b855`).
* `timestamp`: Unix time in milliseconds, decimal string (1–16 digits).
* `nonce`: 16 random bytes, base64url (22 chars); verifiers accept `[A-Za-z0-9_-]{16,128}`.

Headers (all required): `X-Relay-Device` (deviceId), `X-Relay-Subscription` (subscriptionId from the entitlement; device IDs are only unique within a subscription), `X-Relay-Timestamp`, `X-Relay-Nonce`, `X-Relay-Signature`. `PATH` is the request target as received by the license server, i.e. relative to the configured server base URL (`/relay/...`), not including any reverse-proxy prefix.

Server checks: device active with that Ed25519 key, `|now − timestamp| ≤ 5 min` (boundary inclusive), signature valid, nonce not seen within the skew window (replay cache is server state, not part of the library).

Example (`request[0]`):

```
POST
/relay/items?since=2026-10-13T00%3A00%3A00Z
84f6e7272726a0c1949ec24a564399c1e17d7ff75f21c824bc9a2adda577091d
1791849600000
fin-fEeTspATZoJC3a3kIQ
```

## 11. Error handling summary

| Situation | Result |
|---|---|
| Header `v`/`frameSize` unsupported, signature invalid, wrong signer key, any header field changed or stanzas reordered | header rejected |
| No stanza for this device | "cannot decrypt" UI state (not an error) |
| Wrong recipient key, tampered `ephPub`/`wrappedKey`, all-zero shared secret | unwrap failure |
| Manifest tampered, wrong itemId/fileKey/salt, `v ≠ 1` | manifest failure |
| Payload tampered, truncated, extended, frames reordered, wrong final flag, empty non-first final frame | payload failure; partially written output must be discarded |
| Request signature invalid or timestamp outside ±5 min | request rejected |

## 12. Test vectors

* `test-vectors/v1.json` is generated by `scripts/generate-vectors.cjs` (`npm run relay:vectors`) from deterministic seeds; generation is reproducible byte-for-byte. Payload plaintexts follow `byte[i] = ((start + i) × 31 + 7) & 0xff`.
* Sections: `devices`, `canonicalJson`, `wrap`, `payload` (0, 1, 65 535, 65 536, 65 537, 131 172 bytes), `ciphertextSize`, `storageBlocks`, `manifest`, `header`, `bindProof`, `request`, `bindUri`, `items` (full end-to-end text + multi-file items), and `mustFail` cases for every section. Payload `mustFail` entries either embed `ciphertext` or describe a `mutation` (`flipByte`, `truncate`, `append`, `swapFrames`) of a base vector, optionally overriding `itemId` / `fileKey` / `salt`.
* Randomness is injectable in both implementations (`random(length)`), for vector generation and tests only.
* Node → Dart: `packages/relay_crypto/test/vectors_test.dart` ([clip-relay-mobile](https://github.com/HaiTang-8/clip-relay-mobile)) verifies every vector (decrypt and byte-identical re-encrypt). The mobile repo keeps a copy of `PROTOCOL.md` and `test-vectors/`; sync them after any change.
* Dart → Node: `test/node_interop_test.dart` writes Dart-produced items, requests and bind data to a temp dir and runs `scripts/verify-dart-output.cjs <dir>`. It is skipped unless `RELAY_PROTOCOL_DIR` points at this directory.

Commands:

```bash
npm run test:relay                                   # Node unit + vector tests
npm run relay:vectors                                # regenerate vectors
# in clip-relay-mobile/packages/relay_crypto: Dart vectors + Dart→Node interop
RELAY_PROTOCOL_DIR=/path/to/clipboard/relay-protocol dart test
```

API map:

| Node (`src/relay/crypto.cjs`) | Dart (`package:relay_crypto`) |
|---|---|
| `generateDeviceKeys({random})` | `generateDeviceKeys(random:)` → `DeviceKeys` |
| `fingerprint(x, ed)` / `formatFingerprint(hex)` | `fingerprint(x, ed)` / `formatFingerprint(hex)` |
| `wrapKey(fileKey, {deviceId, x25519PublicKey}, {random})` / `unwrapKey(stanza, priv)` | `wrapKey(fileKey, deviceId:, recipientPublicKey:, random:)` / `unwrapKey(Stanza, priv)` |
| `createEncryptStream(opts)` / `createDecryptStream({…, firstFrame, last})` (Transform) | `encryptStream(stream, …)` / `decryptStream(stream, …, firstFrame:, last:)` |
| `encryptPayload` / `decryptPayload` | `encryptPayload` / `decryptPayload` |
| `ciphertextSize` / `splitStorageBlocks` | `ciphertextSize` / `splitStorageBlocks` |
| `encryptManifest` / `decryptManifest` | `encryptManifest` / `decryptManifest` |
| `canonicalJson` / `signHeader` / `verifyHeader` | `canonicalJson` / `signHeader` / `verifyHeader` |
| `bindProof` / `verifyBindProof` | `bindProof` / `verifyBindProof` |
| `requestSigningString` / `signRequest` / `verifyRequest` | `requestSigningString` / `signRequest` / `verifyRequest` |
| `buildBindUri` / `parseBindUri` | `buildBindUri(BindUri)` / `parseBindUri` |
