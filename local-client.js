function createLocalClient() {
    const localUser = { email: 'local@this-computer', user_metadata: { full_name: 'Local' } };

    async function api(method, path, body) {
        try {
            const response = await fetch('/api/' + path, {
                method,
                headers: { 'Content-Type': 'application/json' },
                body: body === undefined ? undefined : JSON.stringify(body)
            });
            const data = await response.json().catch(() => null);
            if (!response.ok) return { data: null, error: { message: (data && data.error) || response.statusText } };
            return { data, error: null };
        } catch (err) {
            return { data: null, error: { message: 'Local server is not running (run serve.ps1): ' + err.message } };
        }
    }

    function from(table) {
        const query = { action: 'select', filters: [], idFilter: null, order: null, body: null, single: false, returning: false };

        const builder = {
            select() { if (query.action !== 'select') query.returning = true; return builder; },
            insert(rows) { query.action = 'insert'; query.body = rows; return builder; },
            update(values) { query.action = 'update'; query.body = values; return builder; },
            delete() { query.action = 'delete'; return builder; },
            eq(column, value) {
                if (column === 'id') query.idFilter = value;
                query.filters.push(row => String(row[column]) === String(value));
                return builder;
            },
            ilike(column, value) {
                query.filters.push(row => String(row[column] || '').toLowerCase() === String(value).toLowerCase());
                return builder;
            },
            order(column, options) {
                query.order = { column, ascending: !options || options.ascending !== false };
                return builder;
            },
            maybeSingle() { query.single = true; return builder; },
            then(resolve, reject) { return run().then(resolve, reject); }
        };

        async function run() {
            if (table === 'authorized_developers') {
                const me = { email: localUser.email, full_name: 'Local', role: 'editor' };
                return { data: query.single ? me : [me], error: null };
            }
            if (table !== 'demands') return { data: null, error: { message: 'Unknown table ' + table } };

            if (query.action === 'select') {
                const result = await api('GET', 'demands');
                if (result.error) return result;
                let rows = (result.data || []).filter(row => query.filters.every(f => f(row)));
                if (query.order) {
                    const { column, ascending } = query.order;
                    rows.sort((a, b) => (a[column] > b[column] ? 1 : a[column] < b[column] ? -1 : 0) * (ascending ? 1 : -1));
                }
                return { data: query.single ? (rows[0] || null) : rows, error: null };
            }
            if (query.action === 'insert') {
                const result = await api('POST', 'demands', Array.isArray(query.body) ? query.body : [query.body]);
                return query.returning || result.error ? result : { data: null, error: null };
            }
            if (query.idFilter === null) return { data: null, error: { message: 'Local mode only supports changes by id' } };
            if (query.action === 'update') return api('PATCH', 'demands/' + query.idFilter, query.body);
            if (query.action === 'delete') return api('DELETE', 'demands/' + query.idFilter);
            return { data: null, error: { message: 'Unsupported action' } };
        }

        return builder;
    }

    return {
        from,
        auth: {
            getSession: async () => ({ data: { session: { user: localUser } }, error: null }),
            getUser: async () => ({ data: { user: localUser }, error: null }),
            signInWithPassword: async () => ({ data: { user: localUser }, error: null }),
            signOut: async () => ({ error: null }),
            updateUser: async () => ({ data: null, error: { message: 'Not available in local mode' } })
        }
    };
}
