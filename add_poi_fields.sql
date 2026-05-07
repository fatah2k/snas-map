-- Run in Supabase SQL Editor to add contact/hours fields to snas_pois
ALTER TABLE snas_pois ADD COLUMN IF NOT EXISTS phone TEXT;
ALTER TABLE snas_pois ADD COLUMN IF NOT EXISTS website TEXT;
ALTER TABLE snas_pois ADD COLUMN IF NOT EXISTS opening_hours TEXT;
