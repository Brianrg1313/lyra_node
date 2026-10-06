import '../migrations.dart';

/// The entities a linked master has uploaded its own records of (`sync_link.uploaded`, a JSON list
/// of edge names). An entity added in a later version isn't in it, so a master linked before uploads
/// that entity's records once, by itself, instead of only what is written after the update (plan §9.8).
///
/// A link that exists already was uploaded with every entity of the version before `employee`; one
/// still downloading or uploading is overwritten when its upload ends.
const m017SyncUploaded = Migration(17, "sync uploaded", r"""
ALTER TABLE sync_link ADD COLUMN uploaded TEXT;

UPDATE sync_link SET uploaded = '["company","site","product_table","product_field","product","currency","stock_movement","payment","delivery_option","delivery_area","account","member"]';
""");
