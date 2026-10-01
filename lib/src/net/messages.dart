import 'package:lyra_protocol/lyra_protocol.dart';

import '../failure.dart';

/// Turns a refusal into the `{code, message, action, data}` a client shows
/// (`protocol-v1.md` §2).
///
/// Messages are English until the company's language exists (the business domain, plan phase
/// 4); the app's i18n is English-only today too. A client branches on `code`, never on the text.
abstract final class Messages {
  static const Map<String, String> _text = {
    ErrorCodes.badRequest: "The request is not valid.",
    ErrorCodes.unknownOp: "This server doesn't know that operation. Update Lyra on the server.",
    ErrorCodes.invalidField: "A field is not valid.",
    ErrorCodes.required: "A required field is missing.",
    ErrorCodes.notFound: "It doesn't exist or you can't see it.",
    ErrorCodes.forbidden: "You don't have permission to do that.",
    ErrorCodes.sessionExpired: "Your session expired. Sign in again.",
    ErrorCodes.sessionRevoked: "Your session was ended. Sign in again.",
    ErrorCodes.deviceRevoked: "This device was removed from the server. Pair it again.",
    ErrorCodes.locked: "The server is locked. Ask someone to unlock it on the server computer.",
    ErrorCodes.rateLimited: "Too many requests. Wait a moment.",
    ErrorCodes.versionMismatch: "This app and the server don't speak the same version. Update Lyra.",
    ErrorCodes.updateRequired: "This app is too old for the server. Update Lyra.",
    ErrorCodes.commandReused: "The request was sent twice with different data.",
    ErrorCodes.resyncRequired: "Reloading: too much changed while you were away.",
    ErrorCodes.needsInternet: "This needs an internet connection.",
    ErrorCodes.frameTooLarge: "The request is too large.",
    ErrorCodes.internal: "Something went wrong on the server.",
    "invalid_credentials": "Wrong username or password.",
    "account_locked": "Too many failed attempts. Try again later.",
    "account_disabled": "This account is disabled.",
    "weak_password": "The password must have at least 10 characters.",
    "wrong_passphrase": "Wrong passphrase.",
    "not_master": "Only the server computer can do that.",
    "self": "The server's own device can't be removed.",
    "invalid_file": "The file is not a type or size that can be used here.",
    "invalid_point": "The location needs both a valid latitude and a valid longitude.",
    "invalid_timezone": "That time zone doesn't exist.",
    "invalid_value": "That value doesn't fit this column.",
    "read_only_field": "Lyra fills in this column: it can't be written by hand.",
    "duplicate_field_type": "A table can have only one column of this type.",
    "duplicate_sku": "Another product of this table already has that SKU.",
    "unknown_template": "That template doesn't exist.",
    "invalid_primary": "The main table can't be unmarked: mark another table as main instead.",
    "too_many_images": "A product can have up to 8 photos.",
    "untracked": "This table doesn't count stock: add a stock column first.",
    "invalid_reason": "That reason doesn't go with this movement.",
    "insufficient_stock": "There isn't enough stock for that.",
    "no_primary_table": "There is no main table yet.",
    "unsupported_file": "That file can't be read: import an .xlsx or a .csv.",
    "too_large": "The file is too big: up to 50,000 rows and 250 columns.",
    "empty_file": "The file has no header row to build the table from.",
    "has_open_tickets": "An open ticket holds products of this table: charge it or cancel it first.",
    "no_price": "This product has no price: write one in the table first.",
    "too_many_units": "A line can have up to 9,999 units.",
    "invoice_closed": "This ticket was already charged.",
    "invoice_cancelled": "This ticket was cancelled.",
    "empty_invoice": "The ticket has nothing on it to charge.",
    "unknown_method": "That payment method isn't accepted here.",
    "sale_not_found": "There is no sale with that reference.",
    "not_a_ticket": "Only a charged sale has a handover.",
    "invalid_state": "That handover step doesn't exist for that way of handing over.",
    "nothing_to_change": "Say how the sale is handed over, or how far that got.",
  };

  /// Codes whose client must go somewhere (`ErrorActions`).
  static const Map<String, String> _actions = {
    ErrorCodes.sessionExpired: ErrorActions.login,
    ErrorCodes.sessionRevoked: ErrorActions.login,
    ErrorCodes.deviceRevoked: ErrorActions.login,
    ErrorCodes.versionMismatch: ErrorActions.update,
    ErrorCodes.updateRequired: ErrorActions.update,
  };

  static RpcError of(String code, [Map<String, Object?> data = const {}]) => RpcError(
    code,
    _text[code] ?? _text[ErrorCodes.internal]!,
    action: _actions[code],
    data: data.isEmpty ? null : data,
  );

  static RpcError ofFailure(EngineFailure failure) => of(failure.code, failure.data);
}
