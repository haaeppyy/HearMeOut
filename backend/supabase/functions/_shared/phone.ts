/// The canonical form of a phone number, shared by every function that
/// accepts or compares one.
///
/// The client normalises before it sends, but the server normalises again on
/// the way in: the server is the authority on what a number looks like, and
/// a client that disagrees must not be able to create two accounts for the
/// same number or fail to find an existing one.
///
/// This mirrors `PhoneNumber.normalize` in the iOS app exactly. If one side
/// changes, the other has to change with it — a number that normalises
/// differently on the two sides simply will not match.
const DEFAULT_COUNTRY_CODE = "+91";

export function normalizeE164(value: unknown): string | null {
  if (typeof value !== "string") return null;

  const trimmed = value.trim();
  const digits = trimmed.replace(/\D/g, "");

  if (trimmed.startsWith("+")) {
    // E.164 allows 8 to 15 digits and no leading zero after the country code.
    if (digits.length < 8 || digits.length > 15) return null;
    if (digits.startsWith("0")) return null;
    return "+" + digits;
  }

  // A bare 10-digit number is assumed to be local.
  if (digits.length === 10) return DEFAULT_COUNTRY_CODE + digits;

  return null;
}
