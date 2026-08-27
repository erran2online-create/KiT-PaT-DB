-- ---------------------------------------------------------------------------
-- P35: Bollywood tambola film pack, festival theme catalogue, Kitty Special
-- reveal-mode flag.
--
-- Additive only. Does NOT touch process_due_tambola_auto_draws or any other
-- draw/claim/verify logic -- draw order stays server-controlled and unknown
-- to clients throughout.
--
-- 1. game_theme_packs (tambola, bollywood) -- merge a 358-title `films` key
--    into content for every locale row, via `||` so existing keys
--    (call_pack, default_prizes, default_interval_seconds, ...) are kept.
--
-- 2. public.festival_themes -- new admin-editable catalogue table. Readable
--    by authenticated, writable only by service_role (admin edits go through
--    an edge function later, per the task). Seeded with 20 festival rows.
--
-- 3. public.get_festival_options(p_month integer) -- returns active
--    festival_themes rows whose months[] contains p_month, ordered by
--    sort_order, so a host can pick when several festivals overlap a month.
--    Callable by authenticated. No festival_month_map table -- derived from
--    months[] at query time, per the task.
--
-- 4. game_theme_packs (tambola, kitty_special) -- merge reveal_mode /
--    fallback keys into content for every locale row. Presentation only.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. Bollywood films
-- ---------------------------------------------------------------------------
UPDATE public.game_theme_packs
SET content = content || jsonb_build_object('films', to_jsonb(ARRAY[
  'Mother India','Mughal-e-Azam','Pyaasa','Kaagaz Ke Phool','Sholay','Deewaar','Zanjeer','Anand','Guide','Aradhana',
  'Amar Akbar Anthony','Don','Bobby','Aandhi','Mera Naam Joker','Pakeezah','Umrao Jaan','Trishul','Kabhie Kabhie','Silsila',
  'Naseeb','Muqaddar Ka Sikandar','Chupke Chupke','Gol Maal','Bawarchi','Namak Haraam','Abhimaan','Sahib Bibi Aur Ghulam','Kati Patang','Amar Prem',
  'Do Bigha Zamin','Awaara','Shree 420','Madhumati','Jewel Thief','Teesri Manzil','Johny Mera Naam','Haathi Mere Saathi','Caravan','Seeta Aur Geeta',
  'Bombay to Goa','Sanjog','Andaz','Kismet','Barsaat','Sangam','Waqt','Jab Jab Phool Khile','Ram Lakhan','Tezaab',
  'Chandni','Mr India','Qayamat Se Qayamat Tak','Maine Pyar Kiya','Karma','Mard','Coolie','Sharaabi','Hero','Betaab',
  'Masoom','Arth','Ardh Satya','Mandi','Nikaah','Prem Rog','Vidhaata','Hum Aapke Hain Koun','Disco Dancer','Himmatwala',
  'Tohfa','Nagina','Mr Natwarlal','Namak Halaal','Satte Pe Satta','Andha Kanoon','Shakti','Kalyug','Saaransh','Mashaal',
  'Meri Jung','Karz','Love Story','Rocky','Ek Duuje Ke Liye','Saagar','Chaalbaaz','Parinda','Salaam Bombay','Jaane Bhi Do Yaaro',
  'Khoon Bhari Maang','Dilwale Dulhania Le Jayenge','Dil To Pagal Hai','Kuch Kuch Hota Hai','Raja Hindustani','Border','Dil','Aashiqui','Saajan','Baazigar',
  'Darr','Karan Arjun','Dilwale','Rangeela','Bombay','Roja','Hum Dil De Chuke Sanam','Taal','Sarfarosh','Ghulam',
  'Satya','Ishq','Pardes','Yes Boss','Dil Se','Judaai','Virasat','Ziddi','Gupt','Koyla',
  'Mohra','Khal Nayak','Anjaam','Damini','Deewana','Beta','Khiladi','Main Khiladi Tu Anari','Andaz Apna Apna','Raja',
  'Coolie No 1','Judwaa','Hero No 1','Biwi No 1','Haseena Maan Jaayegi','Chachi 420','Dushman','Kareeb','Kaho Naa Pyaar Hai','Lagaan',
  'Dil Chahta Hai','Kabhi Khushi Kabhie Gham','Devdas','Gadar Ek Prem Katha','Munna Bhai MBBS','Koi Mil Gaya','Kal Ho Naa Ho','Veer-Zaara','Swades','Black',
  'Rang De Basanti','Lage Raho Munna Bhai','Dhoom','Dhoom 2','Krrish','Don The Chase Begins','Om Shanti Om','Jab We Met','Chak De India','Taare Zameen Par',
  'Guru','Fanaa','Kabhi Alvida Naa Kehna','Bunty Aur Babli','Bluffmaster','Company','Maqbool','Omkara','Dev D','3 Idiots',
  'Ghajini','Singh Is Kinng','Race','Fashion','Rock On','A Wednesday','Wake Up Sid','Love Aaj Kal','Ajab Prem Ki Ghazab Kahani','Paa',
  'New York','Kaminey','Gangster','Woh Lamhe','Life in a Metro','Jannat','Murder','Aetbaar','Hum Tum','Mujhse Dosti Karoge',
  'Main Hoon Na','Bardaasht','Dabangg','Zindagi Na Milegi Dobara','Rockstar','The Dirty Picture','Bodyguard','Ready','Delhi Belly','Kahaani',
  'Barfi','Gangs of Wasseypur','Vicky Donor','Cocktail','Ek Tha Tiger','Jab Tak Hai Jaan','Talaash','Bhaag Milkha Bhaag','Chennai Express','Yeh Jawaani Hai Deewani',
  'Goliyon Ki Raasleela Ram-Leela','Dhoom 3','Kai Po Che','Special 26','Grand Masti','Queen','PK','Highway','Haider','2 States',
  'Humpty Sharma Ki Dulhania','Ek Villain','Mary Kom','Bang Bang','Happy New Year','Piku','Bajrangi Bhaijaan','Bajirao Mastani','Tanu Weds Manu Returns','Dil Dhadakne Do',
  'Tamasha','Talvar','Drishyam','Dangal','Sultan','Airlift','Neerja','Pink','Kapoor and Sons','Udta Punjab',
  'M S Dhoni','Fan','Ae Dil Hai Mushkil','Dear Zindagi','Raees','Jolly LLB 2','Badrinath Ki Dulhania','Hindi Medium','Toilet Ek Prem Katha','Bareilly Ki Barfi',
  'Newton','Secret Superstar','Golmaal Again','Tiger Zinda Hai','Padmaavat','Raazi','Sanju','Andhadhun','Stree','Badhaai Ho',
  'Sui Dhaaga','October','Hichki','Gully Boy','Kabir Singh','Uri The Surgical Strike','Article 15','Super 30','Mission Mangal','Chhichhore',
  'War','Bala','Dream Girl','Housefull 4','Good Newwz','Kesari','Tanhaji','Thappad','Shakuntala Devi','Gunjan Saxena',
  'Dil Bechara','Ludo','Laxmii','Roohi','Mumbai Saga','Shershaah','Bell Bottom','Bhoot Police','Sooryavanshi','83',
  'Gangubai Kathiawadi','The Kashmir Files','Runway 34','Jersey','Bhool Bhulaiyaa 2','Jugjugg Jeeyo','Shamshera','Laal Singh Chaddha','Raksha Bandhan','Brahmastra',
  'Vikram Vedha','Ram Setu','Drishyam 2','An Action Hero','Pathaan','Selfiee','Bholaa','Kisi Ka Bhai Kisi Ki Jaan','Zara Hatke Zara Bachke','Adipurush',
  'Satyaprem Ki Katha','Rocky Aur Rani Kii Prem Kahaani','Gadar 2','Jawan','Jaane Jaan','Fukrey 3','Tiger 3','Sam Bahadur','Animal','Dunki',
  'Fighter','Article 370','Shaitaan','Crew','Maidaan','Bade Miyan Chote Miyan','Srikanth','Munjya','Chandu Champion','Stree 2',
  'Khel Khel Mein','The Buckingham Murders','Jigra','Singham Again','Bhool Bhulaiyaa 3','Vicky Vidya Ka Woh Wala Video','Aashiqui 2','Aisha','Ek Main Aur Ekk Tu','Shaandaar',
  'Befikre','Half Girlfriend','OK Jaanu','Raabta','Jab Harry Met Sejal','Fitoor','Tum Bin','Zeher','Awarapan','Jannat 2',
  'Aashiq Banaya Aapne','Aap Ki Kasam','Lamhe','Henna','Saudagar','Ram Teri Ganga Maili','Prem Granth','Aa Ab Laut Chalen'
]::text[]))
WHERE game_key = 'tambola' AND theme_key = 'bollywood';

-- ---------------------------------------------------------------------------
-- 2. festival_themes catalogue
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.festival_themes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key text UNIQUE NOT NULL,
  name text NOT NULL,
  months integer[] NOT NULL,
  art_cues text,
  emoji text,
  is_active boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.festival_themes IS
  'Festival catalogue for Kitty Special tambola presentation (reveal_mode = festival_tiles). Admin-editable later via an edge function; RLS here only grants read to authenticated.';

INSERT INTO public.festival_themes (key, name, months, art_cues, emoji, sort_order) VALUES
  ('makar_sankranti', 'Makar Sankranti / Pongal', ARRAY[1], 'kites, til-gud, sun', '🪁', 0),
  ('republic_day', 'Republic Day', ARRAY[1], 'tricolour, parade', '🇮🇳', 1),
  ('holi', 'Holi', ARRAY[3], 'colour splashes, pichkari, gujiya', '🎨', 2),
  ('eid', 'Eid', ARRAY[3,4], 'crescent moon, sewaiyaan, lantern', '🌙', 3),
  ('baisakhi', 'Baisakhi', ARRAY[4], 'wheat, dhol, bhangra', '🌾', 4),
  ('raksha_bandhan', 'Raksha Bandhan', ARRAY[8], 'rakhi, thali, sweets', '🎀', 5),
  ('independence_day', 'Independence Day', ARRAY[8], 'tricolour, kite', '🇮🇳', 6),
  ('janmashtami', 'Janmashtami', ARRAY[8], 'matki, flute, peacock feather', '🦚', 7),
  ('ganesh_chaturthi', 'Ganesh Chaturthi', ARRAY[8,9], 'modak, Ganpati, dhol', '🐘', 8),
  ('navratri', 'Navratri / Dussehra', ARRAY[9,10], 'garba, dandiya, nine colours', '💃', 9),
  ('karwa_chauth', 'Karwa Chauth', ARRAY[10], 'chhalni, moon, mehendi', '🌕', 10),
  ('diwali', 'Diwali', ARRAY[10,11], 'diyas, rangoli, crackers, sweets', '🪔', 11),
  ('christmas', 'Christmas', ARRAY[12], 'tree, star, bells', '🎄', 12),
  ('new_year', 'New Year', ARRAY[12,1], 'fireworks, confetti, clock', '🎆', 13),
  ('durga_puja', 'Durga Puja', ARRAY[9,10], 'pandal, dhak, red-white saree, alpona', '🔴', 14),
  ('onam', 'Onam', ARRAY[8,9], 'pookalam flowers, sadya, vallam kali boat', '🌺', 15),
  ('bihu', 'Bihu', ARRAY[1,4], 'gamosa, dhol, bihu dance, paddy', '🌾', 16),
  ('chhath', 'Chhath Puja', ARRAY[10,11], 'sun, river, thekua, soop', '🌅', 17),
  ('lohri', 'Lohri', ARRAY[1], 'bonfire, popcorn, dhol, rewri', '🔥', 18),
  ('gudi_padwa', 'Gudi Padwa / Ugadi', ARRAY[3,4], 'gudi flag, neem, marigold', '🎏', 19)
ON CONFLICT (key) DO UPDATE SET
  name = EXCLUDED.name,
  months = EXCLUDED.months,
  art_cues = EXCLUDED.art_cues,
  emoji = EXCLUDED.emoji,
  sort_order = EXCLUDED.sort_order;

ALTER TABLE public.festival_themes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "authenticated read festival themes" ON public.festival_themes;
CREATE POLICY "authenticated read festival themes"
  ON public.festival_themes FOR SELECT TO authenticated
  USING (true);

-- No INSERT/UPDATE/DELETE policy for authenticated: only service_role (or a
-- future admin edge function running as service_role) can write.
GRANT SELECT ON public.festival_themes TO authenticated;
GRANT ALL ON public.festival_themes TO service_role;

-- ---------------------------------------------------------------------------
-- 3. get_festival_options(p_month) -- active festivals covering a month,
--    ordered by sort_order, for the host to pick between when several
--    overlap.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_festival_options(p_month integer)
RETURNS SETOF public.festival_themes
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT *
  FROM public.festival_themes
  WHERE is_active = true
    AND months @> ARRAY[p_month]
  ORDER BY sort_order;
$$;

COMMENT ON FUNCTION public.get_festival_options(integer) IS
  'Active festival_themes rows whose months[] contains p_month (1-12), ordered by sort_order. Lets the host pick a theme when several festivals overlap a month.';

REVOKE ALL ON FUNCTION public.get_festival_options(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_festival_options(integer) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Kitty Special reveal mode (presentation only -- draw order untouched)
-- ---------------------------------------------------------------------------
UPDATE public.game_theme_packs
SET content = content || jsonb_build_object(
  'reveal_mode', 'festival_tiles',
  'fallback', 'group_memory_photos'
)
WHERE game_key = 'tambola' AND theme_key = 'kitty_special';
