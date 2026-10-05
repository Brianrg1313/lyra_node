import '../migrations.dart';

/// The owner's job on a master whose company was created before `Business.create` filed it: an
/// `active` employment from the company's creation, titled as `Business.ownerTitles`. Without it
/// their own employees list showed them as "no job filed". A random UUIDv4 id, since SQL can't
/// make the engine's v7; ids are only compared for equality and the list sorts by name.
const m014OwnerJob = Migration(14, "owner job", r"""
INSERT INTO employments (id, account, state, job_title, start_date, invited, invited_by, responded, created_hlc, updated_hlc)
SELECT
  lower(hex(randomblob(4)) || '-' || hex(randomblob(2)) || '-4' || substr(hex(randomblob(2)), 2) || '-' ||
    substr('89ab', 1 + (abs(random()) % 4), 1) || substr(hex(randomblob(2)), 2) || '-' || hex(randomblob(6))),
  m.value,
  'active',
  CASE lower(substr(c.language, 1, 2)) WHEN 'en' THEN 'Owner' WHEN 'pt' THEN 'Proprietário' ELSE 'Dueño' END,
  substr(c.created, 1, 10),
  c.created,
  m.value,
  c.created,
  c.created_hlc,
  c.created_hlc
FROM meta m JOIN company c ON c.deleted = 0
WHERE m.key = 'owner'
  AND EXISTS (SELECT 1 FROM accounts a WHERE a.id = m.value)
  AND NOT EXISTS (SELECT 1 FROM employments e WHERE e.account = m.value AND e.state IN ('invited', 'active'));
""");
