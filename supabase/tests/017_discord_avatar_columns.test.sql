BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path TO extensions, public, pg_catalog;

SELECT plan(8);

SELECT has_column('public', 'players', 'avatar_url', 'players exposes the Discord avatar URL');
SELECT col_type_is('public', 'players', 'avatar_url', 'text', 'player avatar URLs use text');
SELECT has_column(
  'public', 'registrations', 'avatar_url', 'registrations preserve the signup avatar URL'
);
SELECT col_type_is('public', 'registrations', 'avatar_url', 'text', 'registration avatar URLs use text');

INSERT INTO public.players (
  id,
  discord_username,
  avatar_gradient,
  avatar_initials,
  ign,
  primary_role,
  status
) VALUES (
  'avatar-contract-player',
  'avatar-contract',
  'from-cyan-500 to-blue-500',
  'AC',
  'Avatar Contract',
  'Support',
  'free-agent'
);

SELECT lives_ok(
  $$UPDATE public.players
    SET avatar_url = 'https://cdn.discordapp.com/avatars/1/avatar.png'
    WHERE id = 'avatar-contract-player'$$,
  'players accept Discord CDN avatar URLs'
);
SELECT throws_ok(
  $$UPDATE public.players
    SET avatar_url = 'https://example.com/avatar.png'
    WHERE id = 'avatar-contract-player'$$,
  '23514',
  'new row for relation "players" violates check constraint "players_avatar_url_discord_cdn_check"',
  'players reject non-Discord avatar hosts'
);

INSERT INTO public.registrations (
  id,
  discord_id,
  discord_username,
  avatar_url
) VALUES (
  'avatar-contract-registration',
  'avatar-contract-discord',
  'avatar-contract',
  'https://media.discordapp.net/avatars/1/avatar.webp'
);

SELECT is(
  (SELECT avatar_url FROM public.registrations WHERE id = 'avatar-contract-registration'),
  'https://media.discordapp.net/avatars/1/avatar.webp',
  'registrations retain valid Discord CDN avatar URLs'
);
SELECT throws_ok(
  $$UPDATE public.registrations
    SET avatar_url = 'javascript:alert(1)'
    WHERE id = 'avatar-contract-registration'$$,
  '23514',
  'new row for relation "registrations" violates check constraint "registrations_avatar_url_discord_cdn_check"',
  'registrations reject unsafe avatar URLs'
);

SELECT * FROM finish();
ROLLBACK;
