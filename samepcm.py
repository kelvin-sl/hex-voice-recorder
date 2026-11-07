"""Exit 0 if two WAV files hold byte-identical PCM in their data chunks (headers may differ)."""
import struct
import sys


def pcm(path):
    d = open(path, "rb").read()
    i = 12
    while i + 8 <= len(d):
        cid, n = d[i:i + 4], struct.unpack("<I", d[i + 4:i + 8])[0]
        if cid == b"data":
            return d[i + 8:i + 8 + n]
        i += 8 + n + (n & 1)
    return None


a, b = pcm(sys.argv[1]), pcm(sys.argv[2])
sys.exit(0 if a is not None and a == b else 1)
