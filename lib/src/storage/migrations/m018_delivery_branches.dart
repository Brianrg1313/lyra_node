import '../migrations.dart';

/// Delivery areas per branch (`deliveries.md` D-15): `branch` is the branch that delivers to an
/// area, null an area every branch serves, and the company's `delivery_scope` says which set is in
/// force (`global` by default, how every company worked before). The branches themselves are the
/// cloud's, so `branch` is the cloud's id, kept as sent.
const m018DeliveryBranches = Migration(18, "delivery_branches", r"""
ALTER TABLE company ADD COLUMN delivery_scope TEXT NOT NULL DEFAULT 'global' CHECK (delivery_scope IN ('global', 'branch'));
ALTER TABLE delivery_areas ADD COLUMN branch TEXT;
""");
