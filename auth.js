async function getCurrentUserRole() {
    const { data: { session } } = await supabaseClient.auth.getSession();
    if (!session) return null;

    const { data, error } = await supabaseClient
        .from('authorized_developers')
        .select('role')
        .ilike('email', session.user.email)
        .maybeSingle();

    if (error) console.error('Error loading role:', error);
    return data ? data.role : null;
}

async function requireRole(nextPage) {
    const role = await getCurrentUserRole();
    if (!role) {
        await supabaseClient.auth.signOut();
        localStorage.clear();
        window.location.href = 'login.html' + (nextPage ? '?next=' + nextPage : '');
        return null;
    }
    return role;
}

async function logout() {
    await supabaseClient.auth.signOut();
    localStorage.clear();
    window.location.href = 'login.html';
}
