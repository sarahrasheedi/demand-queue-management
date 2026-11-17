const DATA_MODE = 'local';

const DEVELOPERS = ['Moaid', 'Tahani', 'Fatima Atef', 'Mushabbab'];

function matchDeveloper(name) {
    const words = String(name || '').toLowerCase().split(/\s+/).filter(Boolean);
    return DEVELOPERS.find(dev => dev.toLowerCase().split(/\s+/).every(part => words.includes(part))) || null;
}

const SUPABASE_URL = 'https://YOUR-PROJECT-ID.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_PASTE_HERE';

const supabaseClient = DATA_MODE === 'local'
    ? createLocalClient()
    : supabase.createClient(
        SUPABASE_URL.trim().replace(/\/rest\/v1\/?$/, '').replace(/\/+$/, ''),
        SUPABASE_ANON_KEY.trim()
    );
