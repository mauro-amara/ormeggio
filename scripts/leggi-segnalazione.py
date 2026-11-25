#!/usr/bin/env python3
"""Apre una segnalazione cifrata di Ormeggio (il corpo di una issue che inizia con "ormeggio-v1:").

Uso: ORMEGGIO_CHIAVE=<chiave privata in base64> python3 leggi-segnalazione.py < corpo.txt
Serve il pacchetto "cryptography" (pip install cryptography).

Formato, come lo scrive ReportSender.swift: chiave pubblica effimera X25519 (32 byte),
nonce (12), testo cifrato con ChaCha20-Poly1305 e tag (16). Chiave simmetrica: HKDF-SHA256
con sale = chiave effimera e info = "ormeggio-segnalazione". Primo byte del testo in chiaro:
1 se il resto è compresso (deflate senza intestazione), 0 se non lo è.
"""
import base64
import os
import re
import sys
import zlib

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

PREFIX = "ormeggio-v1:"


def open_report(body: str, private_key_b64: str) -> str:
    # Prendo solo il blocco cifrato: quello che c'è intorno (per esempio una firma aggiunta da GitHub) non conta.
    found = re.search(re.escape(PREFIX) + r"([A-Za-z0-9+/=]+)", body)
    if not found:
        raise ValueError("non è una segnalazione di Ormeggio")
    data = base64.b64decode(found.group(1))
    ephemeral, nonce, sealed = data[:32], data[32:44], data[44:]
    private = X25519PrivateKey.from_private_bytes(base64.b64decode(private_key_b64))
    shared = private.exchange(X25519PublicKey.from_public_bytes(ephemeral))
    key = HKDF(algorithm=hashes.SHA256(), length=32, salt=ephemeral, info=b"ormeggio-segnalazione").derive(shared)
    inner = ChaCha20Poly1305(key).decrypt(nonce, sealed, None)
    text = zlib.decompress(inner[1:], -15) if inner[0] == 1 else inner[1:]
    return text.decode("utf-8")


if __name__ == "__main__":
    print(open_report(sys.stdin.read(), os.environ["ORMEGGIO_CHIAVE"]))
