import 'package:lyra_protocol/lyra_protocol.dart';

/// One field a company fills in for a rail (`money.md` M-41).
typedef RailField = ({
  String field,
  String type,
  String label,
  String? hint,
  String? options,
  String? format,
  bool required,
});

/// The rails a company may take money through, what each asks to be filled in, and the lists its
/// closed fields pick from (`money.md` money.method, M-40, M-41).
///
/// A snapshot of the cloud's catalogue as of 2026-09: the rails and where each one exists
/// (`lyra_admin`.`payment_methods`, `payment_method_countries`), the option lists
/// (`payment_options`) and the requirement sheets. Offline it can't be read from the cloud, so it
/// ships with the engine; a bank or a rail that changes there changes here with an engine update.
///
/// Labels and hints are in English, as the cloud writes them: they are drawn inside a form whose
/// own labels are the app's strings. Rail names that aren't brands follow the company's language.
abstract final class Rails {
  /// Code → `(name, settlement kind, countries (null: everywhere), currency it moves, position)`.
  /// A `null` name is the settlement kind's own (`Settlements`), so it follows the language.
  static const Map<String, (String?, String, Set<String>?, String?, int)> kinds = {
    "cash": (null, "cash", null, null, 10),
    "card": (null, "card", null, null, 20),
    "visa": ("Visa", "card", null, null, 30),
    "mastercard": ("Mastercard", "card", null, null, 40),
    "amex": ("American Express", "card", null, null, 50),
    "transfer": (null, "transfer", null, null, 60),
    "paypal": ("PayPal", "wallet", null, null, 70),
    "crypto": (null, "crypto", null, null, 80),
    "binance": ("Binance Pay", "crypto", null, null, 90),
    "check": (null, "check", null, null, 100),
    "account": (null, "account", null, null, 110),
    "pago_movil": ("Pago móvil", "mobile", {"VE"}, "VES", 200),
    "zelle": ("Zelle", "transfer", {"US", "VE"}, "USD", 210),
    "mercado_pago": ("Mercado Pago", "wallet", {"AR", "CL", "CO", "MX"}, null, 220),
    "nequi": ("Nequi", "wallet", {"CO"}, "COP", 230),
    "daviplata": ("Daviplata", "wallet", {"CO"}, "COP", 240),
    "pse": ("PSE", "transfer", {"CO"}, "COP", 250),
    "spei": ("SPEI", "transfer", {"MX"}, "MXN", 260),
    "oxxo": ("OXXO Pay", "cash", {"MX"}, "MXN", 270),
    "webpay": ("Webpay", "card", {"CL"}, "CLP", 280),
    "yappy": ("Yappy", "wallet", {"PA"}, "USD", 290),
    "transfer365": ("Transfer365", "transfer", {"SV"}, "USD", 300),
    "venmo": ("Venmo", "wallet", {"US"}, "USD", 310),
    "cash_app": ("Cash App", "wallet", {"US"}, "USD", 320),
    "ach": ("ACH", "transfer", {"US"}, "USD", 330),
    "interac": ("Interac e-Transfer", "transfer", {"CA"}, "CAD", 340),
  };

  /// Catalogue → country (`*`: everywhere) → `(code, name)` in the order they are offered. A
  /// country with no list for a catalogue gets the field as free text ([sheet]).
  static const Map<String, Map<String, List<(String, String)>>> lists = {
    "banks": {
      "VE": [
        ("0102", "Banco de Venezuela"), ("0104", "Venezolano de Crédito"), ("0105", "Mercantil"),
        ("0108", "BBVA Provincial"), ("0114", "Bancaribe"), ("0115", "Exterior"), ("0128", "Banco Caroní"),
        ("0134", "Banesco"), ("0137", "Sofitasa"), ("0138", "Banco Plaza"), ("0146", "Bangente"),
        ("0151", "BFC Banco Fondo Común"), ("0156", "100% Banco"), ("0157", "DelSur"), ("0163", "Banco del Tesoro"),
        ("0166", "Banco Agrícola de Venezuela"), ("0168", "Bancrecer"), ("0169", "Mi Banco"),
        ("0171", "Banco Activo"), ("0172", "Bancamiga"), ("0174", "Banplus"), ("0175", "Banco Bicentenario"),
        ("0177", "Banfanb"), ("0191", "Banco Nacional de Crédito"),
        ("0601", "Instituto Municipal de Crédito Popular"),
      ],
    },
    "documents": {
      "VE": [("V", "Cédula"), ("E", "Cédula extranjera"), ("J", "RIF"), ("G", "RIF gubernamental"), ("P", "Pasaporte")],
      "CO": [("CC", "Cédula de ciudadanía"), ("CE", "Cédula de extranjería"), ("NIT", "NIT (empresa)"), ("PA", "Pasaporte")],
      "AR": [("DNI", "DNI"), ("CUIT", "CUIT (empresa)"), ("CUIL", "CUIL")],
      "MX": [("RFC", "RFC"), ("CURP", "CURP")],
      "CL": [("RUT", "RUT")],
    },
    "networks": {
      "*": [
        ("TRC20", "Tron (TRC20)"), ("ERC20", "Ethereum (ERC20)"), ("BEP20", "BNB Smart Chain (BEP20)"),
        ("POL", "Polygon"), ("ARB", "Arbitrum"), ("SOL", "Solana"), ("TON", "TON"), ("BTC", "Bitcoin"),
        ("LTC", "Litecoin"),
      ],
    },
  };

  /// The columns a sheet may name.
  static const fields = ["holder", "document", "institution", "account"];

  /// Between a document's type and its number, stored together (`V-12345678`).
  static const documentSeparator = "-";

  static RailField _f(
    String field,
    String type,
    String label, {
    String? hint,
    String? options,
    String? format,
    bool required = false,
  }) =>
    (field: field, type: type, label: label, hint: hint, options: options, format: format, required: required);

  /// What each rail asks for, in the order the form draws it. A rail with none here gets
  /// [_generic].
  static final Map<String, List<RailField>> _sheets = {
    for (final code in ["cash", "oxxo", "account", "card", "visa", "mastercard", "amex", "webpay"]) code: const [],
    "transfer": [
      _f("institution", "select", "Bank", hint: "Bank the account is at", options: "banks", required: true),
      _f("holder", "text", "Account holder", hint: "Name it is under", required: true),
      _f("document", "document", "Holder's ID", hint: "12345678", options: "documents", required: true),
      _f("account", "text", "Account number", hint: "0134 0000 00 0000000000", required: true),
    ],
    "pago_movil": [
      _f("institution", "select", "Bank", hint: "Bank that receives the payment", options: "banks", required: true),
      _f("document", "document", "Cédula or RIF", hint: "12345678", options: "documents", required: true),
      _f("account", "phone", "Phone number", hint: "0412 123 45 67", format: "0000 000 00 00", required: true),
    ],
    "pse": [
      _f("institution", "select", "Bank", hint: "Bank the account is at", options: "banks", required: true),
      _f("holder", "text", "Account holder", hint: "Name it is under", required: true),
      _f("document", "document", "Holder's ID", hint: "1234567890", options: "documents", required: true),
      _f("account", "text", "Account number", hint: "Number of the account", required: true),
    ],
    "spei": [
      _f("institution", "select", "Bank", hint: "Bank the account is at", options: "banks"),
      _f("holder", "text", "Account holder", hint: "Name it is under", required: true),
      _f("account", "text", "CLABE", hint: "0000 0000 0000 0000 00", format: "0000 0000 0000 0000 00", required: true),
    ],
    "transfer365": [
      _f("institution", "select", "Bank", hint: "Bank the account is at", options: "banks", required: true),
      _f("holder", "text", "Account holder", hint: "Name it is under", required: true),
      _f("account", "text", "Account number", hint: "Number of the account", required: true),
    ],
    "ach": [
      _f("institution", "text", "Bank", hint: "Name of the bank", required: true),
      _f("holder", "text", "Account holder", hint: "Name it is under", required: true),
      _f("document", "text", "Routing number (ABA)", hint: "000000000", format: "000000000", required: true),
      _f("account", "text", "Account number", hint: "Number of the account", required: true),
    ],
    "check": [
      _f("holder", "text", "Payable to", hint: "Who cashes the check", required: true),
      _f("institution", "text", "Bank", hint: "Bank it is cashed at"),
    ],
    "zelle": [
      _f("holder", "text", "Account holder", hint: "Name it is under", required: true),
      _f("account", "text", "Email or phone", hint: "payments@store.com", required: true),
    ],
    "paypal": [
      _f("account", "email", "PayPal email", hint: "payments@store.com", required: true),
      _f("holder", "text", "Account holder", hint: "Name of the account"),
    ],
    "interac": [
      _f("account", "email", "Email", hint: "payments@store.com", required: true),
      _f("holder", "text", "Account holder", hint: "Name it is under"),
    ],
    "mercado_pago": [
      _f("account", "text", "Alias or CVU", hint: "my.store.mp", required: true),
      _f("holder", "text", "Account holder", hint: "Name of the account"),
    ],
    for (final code in ["nequi", "daviplata"])
      code: [
        _f("account", "phone", "Phone number", hint: "300 123 4567", format: "000 000 0000", required: true),
        _f("holder", "text", "Account holder", hint: "Name it is under"),
        _f("document", "document", "Holder's ID", hint: "1234567890", options: "documents"),
      ],
    "yappy": [
      _f("account", "phone", "Phone number", hint: "6000 0000", format: "0000 0000", required: true),
      _f("holder", "text", "Account holder", hint: "Name it is under"),
    ],
    "venmo": [
      _f("account", "text", "Venmo username", hint: "@my-store", required: true),
      _f("holder", "text", "Account holder", hint: "Name of the account"),
    ],
    "cash_app": [
      _f("account", "text", "Cashtag", hint: r"$mystore", required: true),
      _f("holder", "text", "Account holder", hint: "Name of the account"),
    ],
    "crypto": [
      _f("institution", "select", "Network", hint: "Chain it arrives on", options: "networks", required: true),
      _f("account", "text", "Wallet address", hint: "The full address", required: true),
      _f("holder", "text", "Account holder", hint: "Name of the wallet"),
    ],
    "binance": [
      _f("account", "text", "Pay ID or email", hint: "123456789", required: true),
      _f("holder", "text", "Account holder", hint: "Name of the account"),
    ],
  };

  /// What a rail nobody wrote a sheet for asks: four optional lines.
  static final List<RailField> _generic = [
    _f("institution", "text", "Institution", hint: "Bank, wallet or network"),
    _f("holder", "text", "Account holder", hint: "Name it is under"),
    _f("document", "text", "Document", hint: "An id or tax number"),
    _f("account", "text", "Account", hint: "Number, phone or email"),
  ];

  /// Whether [code] is offered in [country]: global rails everywhere, the rest where they exist.
  /// The store's own tab (`credit` kinds) only while credit is decided ([credit]).
  static bool offered(String code, String country, {required bool credit}) {
    final kind = kinds[code];
    if (kind == null) return false;

    final settles = Settlements.kinds[kind.$2];
    if (settles == null || (settles.$3 && !credit)) return false;

    return kind.$3 == null || kind.$3!.contains(country.toUpperCase());
  }

  /// The rails offered in [country], by position, as `money.methods.rails` answers them.
  static List<Map<String, Object?>> available(String country, String language, {required bool credit}) => [
    for (final code in kinds.keys)
      if (offered(code, country, credit: credit)) row(code, language),
  ]..sort((a, b) => (a["position"] as int).compareTo(b["position"] as int));

  /// One rail as answered. `icon` is the cloud's asset id, which a master doesn't have: null.
  static Map<String, Object?> row(String code, String language) {
    final (name, method, countries, currency, position) = kinds[code]!;
    final (reference, change, _, _) = Settlements.kinds[method]!;

    return {
      "code": code,
      "name": name ?? Settlements.name(method, language),
      "method": method,
      "methodName": Settlements.name(method, language),
      "scope": countries == null ? "global" : "country",
      "currency": currency,
      "icon": null,
      "reference": reference,
      "change": change,
      "position": position,
    };
  }

  /// The lists offered in [country], by catalogue: `{banks: [{code, name}], …}`.
  static Map<String, List<Map<String, String>>> options(String country) => {
    for (final MapEntry(key: catalog, value: byCountry) in lists.entries)
      if ((byCountry[country.toUpperCase()] ?? byCountry["*"]) case final rows?)
        catalog: [for (final (code, name) in rows) {"code": code, "name": name}],
  };

  /// [code]'s sheet against the lists [options] has: a `select` with no list becomes `text`, a
  /// `document` with no types a plain id, so a bank transfer in a country with no list is still
  /// one (the company types the bank).
  static List<RailField> sheet(String code, Map<String, List<Map<String, String>>> options) => [
    for (final field in _sheets[code] ?? _generic)
      if (field.options == null || (options[field.options] ?? const []).isNotEmpty)
        field
      else
        (
          field: field.field,
          type: field.type == "select" ? "text" : field.type,
          label: field.label,
          hint: field.hint,
          options: null,
          format: field.format,
          required: field.required,
        ),
  ];

  static Map<String, Object?> fieldJson(RailField field) => {
    "field": field.field,
    "type": field.type,
    "label": field.label,
    "hint": field.hint,
    "options": field.options,
    "format": field.format,
    "required": field.required,
  };

  /// Lays the digits of [value] into [mask] (`0000 000 00 00` → `0412 123 45 67`). A value
  /// with anything but digits and a number's punctuation, or one starting with `+`, is left as
  /// it is; digits past the mask are kept.
  static String format(String? mask, String value) {
    final text = value.trim();
    if (mask == null || mask.isEmpty || text.isEmpty || text.startsWith("+")) return text;
    if (!RegExp(r"^[0-9 ()+.\-]+$").hasMatch(text)) return text;

    final digits = text.replaceAll(RegExp(r"\D"), "");
    if (digits.isEmpty) return text;

    final out = StringBuffer();
    var at = 0;
    for (final character in mask.split("")) {
      if (at >= digits.length) break;
      if (character == "0") {
        out.write(digits[at++]);
      } else {
        out.write(character);
      }
    }

    return "$out${digits.substring(at)}";
  }

  /// A stored document split into its type and number; the type is null with no separator.
  static (String?, String) document(String value) {
    final text = value.trim();
    final at = text.indexOf(documentSeparator);
    if (at <= 0) return (null, text);

    return (text.substring(0, at).trim().toUpperCase(), text.substring(at + 1).trim());
  }
}
