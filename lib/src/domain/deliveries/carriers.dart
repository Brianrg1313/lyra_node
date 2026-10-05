/// The carriers a delivery option may name (`deliveries.md` D-2): the cloud's catalogue
/// (`lyra_admin`.`delivery_providers` and `delivery_provider_countries`) as of 2026-09, copied with
/// each release like the payment rails. A `country` carrier is offered only where it works; a
/// `global` one everywhere. Glovo works in none of the countries Lyra is offered in today, as in
/// the cloud.
///
/// Icons are the cloud's files, which a master doesn't have: always null here.
abstract final class Carriers {
  /// `(code, name, kind, global, countries)`, in the cloud's order.
  static const List<(String, String, String, bool, Set<String>)> all = [
    ("pedidos_ya", "PedidosYa", "platform", false, {"AR", "CL", "PA", "SV", "VE"}),
    ("rappi", "Rappi", "platform", false, {"AR", "CL", "CO", "MX"}),
    ("uber_eats", "Uber Eats", "platform", false, {"CA", "CL", "MX", "US"}),
    ("didi_food", "DiDi Food", "platform", false, {"CO", "MX"}),
    ("doordash", "DoorDash", "platform", false, {"CA", "US"}),
    ("yummy", "Yummy", "platform", false, {"VE"}),
    ("hugo", "Hugo", "platform", false, {"SV"}),
    ("glovo", "Glovo", "platform", false, {}),
    ("zoom", "Zoom", "courier", false, {"VE"}),
    ("mrw", "MRW", "courier", false, {"VE"}),
    ("tealca", "Tealca", "courier", false, {"VE"}),
    ("domesa", "Domesa", "courier", false, {"VE"}),
    ("liberty_express", "Liberty Express", "courier", false, {"VE"}),
    ("servientrega", "Servientrega", "courier", false, {"CO"}),
    ("interrapidisimo", "Interrapidísimo", "courier", false, {"CO"}),
    ("coordinadora", "Coordinadora", "courier", false, {"CO"}),
    ("estafeta", "Estafeta", "courier", false, {"MX"}),
    ("paquetexpress", "Paquetexpress", "courier", false, {"MX"}),
    ("andreani", "Andreani", "courier", false, {"AR"}),
    ("oca", "OCA", "courier", false, {"AR"}),
    ("correo_argentino", "Correo Argentino", "courier", false, {"AR"}),
    ("chilexpress", "Chilexpress", "courier", false, {"CL"}),
    ("starken", "Starken", "courier", false, {"CL"}),
    ("usps", "USPS", "courier", false, {"US"}),
    ("canada_post", "Canada Post", "courier", false, {"CA"}),
    ("purolator", "Purolator", "courier", false, {"CA"}),
    ("dhl", "DHL", "courier", true, {}),
    ("fedex", "FedEx", "courier", true, {}),
    ("ups", "UPS", "courier", true, {}),
  ];

  /// The carriers a company in [country] may pick, as `delivery.providers` lists them.
  static List<Map<String, Object?>> offered(String country) => [
    for (final carrier in all)
      if (carrier.$4 || carrier.$5.contains(country)) _row(carrier),
  ];

  /// [code] when a company in [country] may pick it: `(code, kind)`.
  static (String, String)? pick(String code, String country) {
    for (final carrier in all) {
      if (carrier.$1 == code && (carrier.$4 || carrier.$5.contains(country))) return (carrier.$1, carrier.$3);
    }

    return null;
  }

  /// What [code] is called, wherever it works: an option keeps reading the carrier it named after
  /// the company moved. Null for a code this catalogue doesn't have.
  static String? name(String? code) {
    for (final carrier in all) {
      if (carrier.$1 == code) return carrier.$2;
    }

    return null;
  }

  static Map<String, Object?> _row((String, String, String, bool, Set<String>) carrier) => {
    "code": carrier.$1,
    "name": carrier.$2,
    "kind": carrier.$3,
    "scope": carrier.$4 ? "global" : "country",
    "icon": null,
  };
}
