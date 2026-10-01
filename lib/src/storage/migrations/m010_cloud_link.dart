import '../migrations.dart';

/// The cloud company this master's company is one with (`business.md` business.link, plan §9.6):
/// the id the cloud knows it by, so a device signed in online reaches the cloud-only areas of the
/// same company. Null until linked; written once (B-31).
const m010CloudLink = Migration(10, "cloud_link", r"""
ALTER TABLE company ADD COLUMN cloud_id TEXT;
""");
