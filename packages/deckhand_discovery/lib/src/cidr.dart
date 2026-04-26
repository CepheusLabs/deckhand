/// Pure-Dart IPv4 CIDR expansion.
///
/// Returns the list of **host** addresses for a given CIDR block,
/// matching RFC 3021-ish conventions:
///   - `/31` and `/32` are point-to-point / single host, so every
///     address in the block is a host address (no network/broadcast
///     to exclude).
///   - All other prefixes exclude the network (`.0`) and broadcast
///     (`.255`-style) addresses so a `/24` yields 254 hosts.
///
/// The returned [Iterable] is lazy. Callers that need a stable list
/// should `.toList()` it.
///
/// Throws [FormatException] on malformed input: wrong octet count,
/// octet out of 0..255, missing prefix, prefix out of 0..32, or
/// anything that isn't `<ipv4>/<prefix>`.
Iterable<String> expandCidr(String cidr) sync* {
  final slash = cidr.indexOf('/');
  if (slash < 0) {
    throw FormatException('CIDR missing "/<prefix>"', cidr);
  }
  final ipPart = cidr.substring(0, slash);
  final prefixPart = cidr.substring(slash + 1);

  final prefix = int.tryParse(prefixPart);
  if (prefix == null || prefix < 0 || prefix > 32) {
    throw FormatException('CIDR prefix must be 0..32', cidr);
  }

  final octetStrings = ipPart.split('.');
  if (octetStrings.length != 4) {
    throw FormatException('IPv4 address must have 4 octets', cidr);
  }
  final octets = <int>[];
  for (final s in octetStrings) {
    if (s.isEmpty) {
      throw FormatException('IPv4 octet must not be empty', cidr);
    }
    final v = int.tryParse(s);
    if (v == null || v < 0 || v > 255) {
      throw FormatException('IPv4 octet out of range 0..255', cidr);
    }
    octets.add(v);
  }

  final base = (octets[0] << 24) |
      (octets[1] << 16) |
      (octets[2] << 8) |
      octets[3];
  final hostBits = 32 - prefix;
  // 1 << 32 is UB-adjacent on a 32-bit int; use 1 << hostBits and
  // fall back to the full 32-bit span when prefix == 0.
  final total = hostBits == 32 ? 0x100000000 : (1 << hostBits);
  final mask = hostBits == 32 ? 0 : ((~0 << hostBits) & 0xFFFFFFFF);
  final network = base & mask;

  // /31 and /32 have no network/broadcast to skip.
  final skipEdges = prefix < 31;
  final start = skipEdges ? 1 : 0;
  final end = skipEdges ? total - 1 : total;
  for (var i = start; i < end; i++) {
    final addr = network | i;
    yield '${(addr >> 24) & 0xFF}.'
        '${(addr >> 16) & 0xFF}.'
        '${(addr >> 8) & 0xFF}.'
        '${addr & 0xFF}';
  }
}
