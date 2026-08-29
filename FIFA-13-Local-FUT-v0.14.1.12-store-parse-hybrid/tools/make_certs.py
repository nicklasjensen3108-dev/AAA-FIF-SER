#!/usr/bin/env python3
"""Generate the ProtoSSL certificate material the Blaze redirector needs.

    python tools/make_certs.py                 # writes into src/bridge/secrets
    python tools/make_certs.py --out somewhere

This repository ships no keys. Everyone generates their own, and this script is
the whole recipe.

WHY A NORMAL CERTIFICATE DOES NOT WORK
--------------------------------------
FIFA 13's ProtoSSL stack carries its certificate authorities compiled into the
executable, and it selects which one to check against by matching the *length of
the presented signature* to that CA's modulus size. Get the length wrong and the
certificate is refused before it is ever compared to anything.

The client's embedded table (retail build CL1298564, VA 0x02291BF0-0x02292060):

    CA                                Modulus     Exp   OU
    OTG3 Certificate Authority        1024-bit    3     Online Technology Group
    GOS 2011 Certificate Authority    2048-bit    17    Global Online Studio

`gosredirector.ea.com` carries OU=Global Online Studio, so it belongs to GOS 2011
and must be signed with a 2048-bit key, giving a 256-byte signature. Signing it
with a 2048-bit key under the OTG3 entry -- a 128-byte modulus -- is the exact
mismatch that made every early attempt fail.

Two further requirements, both inherited from the era:

  * the signature must be MD5, and
  * only the OUTER signatureAlgorithm OID is rewritten from md5WithRSAEncryption
    to rsaEncryption. The copy inside tbsCertificate is left alone. This is the
    legacy ProtoSSL quirk the SDKs call Bug_OldProtoSSL; a certificate with both
    copies rewritten, or neither, is rejected.

The client does not actually verify the CA signature, which is why a locally
generated authority works at all. That is a bug in a retired product, not a
capability of this script -- it lets an owned copy of the game talk to a server
on its own machine, and nothing else.

REQUIREMENTS
------------
The `openssl` command on PATH. MD5 signing is refused outright by some
distributions' hardened builds; if `--md5` fails, use a stock OpenSSL.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# 1.2.840.113549.1.1.4 (md5WithRSAEncryption) and 1.2.840.113549.1.1.1
# (rsaEncryption), DER-encoded. They are the same length, so the patch is a
# straight byte replacement and no length fields have to be rewritten.
OID_MD5_WITH_RSA = bytes.fromhex("06092A864886F70D010104")
OID_RSA_ENCRYPTION = bytes.fromhex("06092A864886F70D010101")

# FIFA 13 compares the issuer identity against its embedded CA record. The live
# client rejected a structurally correct certificate carrying a neutral O= even
# though the SDK self-test accepted it, so preserve the exact historical DN.
# This certificate is generated only for a loopback preservation server.
DEFAULT_ORGANISATION = "Electronic Arts, Inc."
CA_COMMON_NAME = "GOS 2011 Certificate Authority"
SERVER_COMMON_NAME = "gosredirector.ea.com"
ORGANISATIONAL_UNIT = "Global Online Studio"   # selects the GOS 2011 CA entry
CA_SUPPORT_EMAIL = "GOSDirtysockSupport@ea.com"

KEY_BITS = 2048          # 256-byte signature, matching the GOS 2011 modulus
EXPECTED_SIGNATURE = 256


OPENSSL = "openssl"


def run(*args: str) -> None:
    result = subprocess.run((OPENSSL, *args), capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"openssl failed: {OPENSSL} {' '.join(args)}\n{result.stderr.strip()}")


def patch_outer_oid(der: bytes) -> bytes:
    """Rewrite only the outer signatureAlgorithm OID.

    A certificate carries the algorithm twice: once inside tbsCertificate and
    once beside the signature itself. Only the second, outer copy is rewritten,
    so this replaces the LAST occurrence and leaves the first untouched.
    """
    index = der.rfind(OID_MD5_WITH_RSA)
    if index < 0:
        sys.exit("md5WithRSAEncryption OID not found -- did openssl honour --md5?")
    if der.count(OID_MD5_WITH_RSA) < 2:
        sys.exit("expected the algorithm twice (inner and outer); found one")
    return der[:index] + OID_RSA_ENCRYPTION + der[index + len(OID_MD5_WITH_RSA):]


def signature_length(der: bytes) -> int:
    """Length in bytes of the certificate signature.

    This is the value the client compares against its embedded CA modulus size,
    so it is worth reading out of the DER rather than assuming it followed from
    the key size. The signature is the BIT STRING that follows the outer
    AlgorithmIdentifier: optional NULL parameters, then tag 0x03, a DER length,
    and one leading byte counting unused bits.
    """
    rest = der[der.rfind(OID_RSA_ENCRYPTION) + len(OID_RSA_ENCRYPTION):]
    if rest[:2] == b"\x05\x00":          # absent for some algorithms
        rest = rest[2:]
    if not rest or rest[0] != 0x03:
        sys.exit("no BIT STRING after the outer signatureAlgorithm")
    first = rest[1]
    if first & 0x80:                      # long form: low bits give the count
        count = first & 0x7F
        length = int.from_bytes(rest[2:2 + count], "big")
    else:
        length = first
    return length - 1                     # drop the unused-bits byte


def main() -> int:
    global OPENSSL
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", type=Path,
                        default=Path(__file__).resolve().parents[1] / "src" / "bridge" / "secrets")
    parser.add_argument("--days", type=int, default=7300)
    parser.add_argument("--force", action="store_true",
                        help="overwrite existing material")
    parser.add_argument("--organisation", default=DEFAULT_ORGANISATION,
                        help="certificate O= field; not known to be read by the "
                             "client, so it defaults to a neutral value")
    parser.add_argument("--openssl", type=Path,
                        help="explicit OpenSSL executable (useful when it is installed but not on PATH)")
    args = parser.parse_args()

    # Field order mirrors the working legacy recipe. The CA needs every field
    # from FIFA 13's embedded GOS 2011 record, including its support address;
    # the leaf keeps the original gosredirector identity.
    ca_subject = (
        f"/OU={ORGANISATIONAL_UNIT}/O={args.organisation}/L=Redwood City"
        f"/ST=California/C=US/emailAddress={CA_SUPPORT_EMAIL}/CN={CA_COMMON_NAME}"
    )
    server_subject = (
        f"/CN={SERVER_COMMON_NAME}/OU={ORGANISATIONAL_UNIT}"
        f"/O={args.organisation}/ST=California/C=US"
    )

    OPENSSL = str(args.openssl) if args.openssl else (shutil.which("openssl") or "")
    if not OPENSSL or not Path(OPENSSL).is_file():
        sys.exit("openssl was not found on PATH.")

    out: Path = args.out
    out.mkdir(parents=True, exist_ok=True)
    server_der = out / "gosredirector.protossl.der"
    server_key = out / "gosredirector.key"
    if (server_der.exists() or server_key.exists()) and not args.force:
        sys.exit(f"{out} already holds certificate material. Pass --force to replace it.")

    with tempfile.TemporaryDirectory() as tmpdir:
        tmp = Path(tmpdir)
        ca_key, ca_crt = tmp / "ca.key", tmp / "ca.crt"
        csr, signed = tmp / "server.csr", tmp / "server.der"

        # The authority. Its key size is what fixes the signature length, which
        # is the value the client actually inspects.
        run("genrsa", "-out", str(ca_key), str(KEY_BITS))
        run("req", "-new", "-x509", "-md5", "-key", str(ca_key),
            "-out", str(ca_crt), "-days", str(args.days), "-subj", ca_subject)

        run("genrsa", "-out", str(server_key), str(KEY_BITS))
        run("req", "-new", "-key", str(server_key), "-out", str(csr),
            "-subj", server_subject)
        run("x509", "-req", "-md5", "-in", str(csr),
            "-CA", str(ca_crt), "-CAkey", str(ca_key), "-set_serial", "1",
            "-days", str(args.days), "-outform", "DER", "-out", str(signed))

        der = patch_outer_oid(signed.read_bytes())
        server_der.write_bytes(der)

        # The bridge resolves the DER and the PEM key from the DIRECTORY of the
        # path it is handed, so the .pfx only has to exist and sit beside them.
        # It still has to be internally consistent, which means the SERVER
        # certificate and the server key -- pairing the server key with the CA
        # certificate makes openssl refuse with "No cert matches private key".
        server_pem = tmp / "server.pem"
        run("x509", "-inform", "DER", "-in", str(signed),
            "-outform", "PEM", "-out", str(server_pem))
        run("pkcs12", "-export", "-inkey", str(server_key),
            "-in", str(server_pem), "-certfile", str(ca_crt),
            "-out", str(out / "gosredirector.ea.com.pfx"), "-passout", "pass:")

    # Verify the one property that actually decides acceptance, rather than
    # trusting that the commands above did what they were asked.
    length = signature_length(der)
    print(f"wrote {server_der}")
    print(f"      {server_key}")
    print(f"      {out / 'gosredirector.ea.com.pfx'}")
    print(f"signature length: {length} bytes (expected {EXPECTED_SIGNATURE})")
    if length != EXPECTED_SIGNATURE:
        print("WARNING: the client matches this against the GOS 2011 modulus and "
              "will refuse the certificate if it differs.", file=sys.stderr)
        return 1
    print("outer signatureAlgorithm patched to rsaEncryption; inner copy left as md5WithRSA")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
