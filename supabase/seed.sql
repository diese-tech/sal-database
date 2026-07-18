-- Deterministic development/reference fixtures only. Never copy production
-- identities, submissions, evidence, audit rows, or operational state here.

INSERT INTO public.divisions (id, name, description, tier, accent_color) VALUES
  ('terra', 'Terra Division', 'Top-tier competitive play. The pinnacle where champions are forged.', 1, 'emerald'),
  ('solar', 'Solar Division', 'High-level competition where elite players contest for supremacy.', 2, 'orange'),
  ('lunar', 'Lunar Division', 'The proving grounds. Rise through the roots and earn your place.', 3, 'cyan')
ON CONFLICT (id) DO UPDATE SET
  name = EXCLUDED.name,
  description = EXCLUDED.description,
  tier = EXCLUDED.tier,
  accent_color = EXCLUDED.accent_color;

-- SMITE reference data is generated in ./seeds/smite2-gods.sql.
