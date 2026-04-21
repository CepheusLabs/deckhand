/// Collapse profile-authored prose into something that flows naturally
/// inside Material widgets.
///
/// Profile YAML typically authors descriptions, explainers, notes, and
/// helper text using the literal block scalar `|`, which preserves the
/// hard line breaks the author added for source-code readability
/// (usually at 80 chars). Those bake into the string and render as
/// visible wraps on wider screens, making the text look broken.
///
/// [flattenProfileText] treats single newlines as spaces (reflowing the
/// paragraph) and preserves paragraph breaks (two or more newlines stay
/// as a single blank line). CR characters are normalized out first.
///
/// Null / empty input returns the empty string.
String flattenProfileText(String? text) {
  if (text == null || text.isEmpty) return '';
  const paraBreakMarker = '\u0000';
  return text
      .replaceAll('\r\n', '\n')
      .replaceAll(RegExp(r'\n{2,}'), paraBreakMarker)
      .replaceAll('\n', ' ')
      .replaceAll(paraBreakMarker, '\n\n')
      .trim();
}
