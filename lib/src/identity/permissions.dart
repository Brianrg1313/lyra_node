/// Grant evaluation (`session.md` P-1), the same rules as the app's `PermissionsService`, but
/// enforced here: the master is the gate (plan §5.4).
abstract final class Permissions {
  /// Every permission.
  static const all = "*";

  /// Whether [grants] allow [needed]: `*` allows everything, `<area>.*` every action of that
  /// area and of its children, anything else only itself.
  static bool allows(Set<String> grants, String needed) {
    if (grants.contains(all) || grants.contains(needed)) return true;

    for (final grant in grants) {
      if (!grant.endsWith(".*")) continue;

      final area = grant.substring(0, grant.length - 2);
      if (needed == area || needed.startsWith("$area.")) return true;
    }

    return false;
  }
}
